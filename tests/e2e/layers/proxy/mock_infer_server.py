#!/usr/bin/env python3
"""Mock推理服务 - 用于e2e参数透传测试

记录收到的所有请求，返回合法的OpenAI格式响应。
支持查询收到的请求记录，用于验证参数透传和header透传。

用法:
    python3 mock_infer_server.py [port]
    默认端口: 19990

API:
    POST /v1/chat/completions - Chat Completion 接口
    POST /v1/completions      - Completion 接口
    GET  /mock/requests       - 获取所有收到的请求记录
    DELETE /mock/requests     - 清空请求记录
    GET  /mock/health         - 健康检查
"""

import json
import time
import sys
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from typing import Dict, Any, List

# 请求记录存储
_request_records: List[Dict[str, Any]] = []
_records_lock = threading.Lock()


class MockInferHandler(BaseHTTPRequestHandler):
    """Mock推理服务请求处理器"""

    def _record_request(self) -> Dict[str, Any]:
        """记录当前请求并返回body"""
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length) if content_length > 0 else b''

        try:
            body_json = json.loads(body) if body else {}
        except json.JSONDecodeError:
            body_json = {"_raw": body.decode('utf-8', errors='replace')}

        # 收集所有header（保留原始大小写）
        headers = {}
        for key, value in self.headers.items():
            headers[key] = value

        record = {
            "method": self.command,
            "path": self.path,
            "headers": headers,
            "body": body_json,
            "timestamp": time.time()
        }

        with _records_lock:
            _request_records.append(record)

        return body_json

    def _send_json_response(self, data: dict, status: int = 200):
        """发送JSON响应"""
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(json.dumps(data, ensure_ascii=False).encode('utf-8'))
        self.wfile.flush()
        self.close_connection = True  # 显式关闭连接

    def _send_sse_response(self, chunks: list):
        """发送SSE流式响应"""
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Connection', 'close')
        self.send_header('X-Accel-Buffering', 'no')
        self.end_headers()
        self.close_connection = True

        for chunk in chunks:
            line = f"data: {json.dumps(chunk, ensure_ascii=False)}\n\n"
            self.wfile.write(line.encode('utf-8'))
            self.wfile.flush()

        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def do_POST(self):
        """处理POST请求"""
        body = self._record_request()

        if self.path == '/v1/chat/completions':
            stream = body.get('stream', False)
            if stream:
                self._handle_chat_completion_stream(body)
            else:
                self._handle_chat_completion(body)
        elif self.path == '/v1/completions':
            stream = body.get('stream', False)
            if stream:
                self._handle_completion_stream(body)
            else:
                self._handle_completion(body)
        else:
            self._send_json_response({"error": "not found"}, 404)

    def do_GET(self):
        """处理GET请求"""
        if self.path == '/mock/requests':
            with _records_lock:
                self._send_json_response({"requests": _request_records})
        elif self.path == '/mock/health':
            self._send_json_response({"status": "ok"})
        else:
            self._send_json_response({"error": "not found"}, 404)

    def do_DELETE(self):
        """处理DELETE请求"""
        if self.path == '/mock/requests':
            with _records_lock:
                _request_records.clear()
            self._send_json_response({"status": "cleared"})
        else:
            self._send_json_response({"error": "not found"}, 404)

    def _handle_chat_completion(self, body: dict):
        """处理非流式chat completion请求"""
        model = body.get('model', 'mock-model')

        # 构建choice
        choice = {
            "index": 0,
            "message": {"role": "assistant", "content": "Hello!"},
            "finish_reason": "stop"
        }

        # 如果请求了logprobs，添加模拟数据
        if body.get('logprobs'):
            choice["logprobs"] = {
                "content": [{
                    "token": "Hello",
                    "logprob": -0.1,
                    "bytes": [72, 101, 108, 108, 111]
                }, {
                    "token": "!",
                    "logprob": -0.2,
                    "bytes": [33]
                }]
            }

        # 如果请求了token_ids，添加模拟数据
        if body.get('return_token_ids'):
            choice["token_ids"] = [9901, 0]  # Hello! 的模拟token ids

        self._send_json_response({
            "id": "chatcmpl-mock",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": model,
            "choices": [choice],
            "usage": {"prompt_tokens": 5, "completion_tokens": 2, "total_tokens": 7}
        })

    def _handle_chat_completion_stream(self, body: dict):
        """处理流式chat completion请求"""
        model = body.get('model', 'mock-model')
        created = int(time.time())

        # 构建最后一个chunk，包含finish_reason和可能的logprobs/token_ids
        final_choice = {"index": 0, "delta": {}, "finish_reason": "stop"}

        # 如果请求了logprobs，在最后一个chunk添加
        if body.get('logprobs'):
            final_choice["logprobs"] = {
                "content": [{
                    "token": "Hello",
                    "logprob": -0.1,
                    "bytes": [72, 101, 108, 108, 111]
                }, {
                    "token": "!",
                    "logprob": -0.2,
                    "bytes": [33]
                }]
            }

        # 如果请求了token_ids，在最后一个chunk添加
        if body.get('return_token_ids'):
            final_choice["token_ids"] = [9901, 0]  # Hello! 的模拟token ids

        chunks = [
            {
                "id": "chatcmpl-mock",
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [{"index": 0, "delta": {"role": "assistant", "content": "Hello"}, "finish_reason": None}]
            },
            {
                "id": "chatcmpl-mock",
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [{"index": 0, "delta": {"content": "!"}, "finish_reason": None}]
            },
            {
                "id": "chatcmpl-mock",
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [final_choice],
                "usage": {"prompt_tokens": 5, "completion_tokens": 2, "total_tokens": 7}
            }
        ]
        self._send_sse_response(chunks)

    def _handle_completion(self, body: dict):
        """处理非流式completion请求（TITO模式）"""
        model = body.get('model', 'mock-model')

        # E2E P211 空 think 场景：模型输出 <think></think> 前缀（think 内容为空）。
        # TITO 模式 proxy 请求固定带 return_token_ids=True；此分支返回纯文本且
        # 不带 token_ids 字段，proxy 的 _decode_response 会回退到文本路径，
        # 使非流式 openai_builder 走 extract_reasoning 提取（触发空 think 泄漏回归）。
        if "empty-think" in model:
            choice = {
                "index": 0,
                "text": "<think></think>你好",
                "finish_reason": "stop"
            }
            self._send_json_response({
                "id": "cmpl-mock",
                "object": "text_completion",
                "created": int(time.time()),
                "model": model,
                "choices": [choice],
                "usage": {"prompt_tokens": 5, "completion_tokens": 2, "total_tokens": 7}
            })
            return

        # 构建choice
        choice = {
            "index": 0,
            "text": "Hello!",
            "finish_reason": "stop"
        }

        # 如果请求了logprobs，添加模拟数据
        if body.get('logprobs'):
            choice["logprobs"] = {
                "tokens": ["Hello", "!"],
                "token_logprobs": [-0.1, -0.2],
                "text_offset": [0, 5]
            }

        # 如果请求了token_ids，添加模拟数据
        if body.get('return_token_ids'):
            choice["token_ids"] = [9901, 0]

        self._send_json_response({
            "id": "cmpl-mock",
            "object": "text_completion",
            "created": int(time.time()),
            "model": model,
            "choices": [choice],
            "usage": {"prompt_tokens": 5, "completion_tokens": 2, "total_tokens": 7}
        })

    def _handle_completion_stream(self, body: dict):
        """处理流式completion请求（TITO模式）"""
        model = body.get('model', 'mock-model')
        created = int(time.time())

        # 构建最后一个chunk
        final_choice = {"index": 0, "text": "", "finish_reason": "stop"}

        # 如果请求了logprobs，在最后一个chunk添加
        if body.get('logprobs'):
            final_choice["logprobs"] = {
                "tokens": ["Hello", "!"],
                "token_logprobs": [-0.1, -0.2],
                "text_offset": [0, 5]
            }

        # 如果请求了token_ids，在最后一个chunk添加
        if body.get('return_token_ids'):
            final_choice["token_ids"] = [9901, 0]

        chunks = [
            {
                "id": "cmpl-mock",
                "object": "text_completion",
                "created": created,
                "model": model,
                "choices": [{"index": 0, "text": "Hello", "finish_reason": None}]
            },
            {
                "id": "cmpl-mock",
                "object": "text_completion",
                "created": created,
                "model": model,
                "choices": [{"index": 0, "text": "!", "finish_reason": None}]
            },
            {
                "id": "cmpl-mock",
                "object": "text_completion",
                "created": created,
                "model": model,
                "choices": [final_choice],
                "usage": {"prompt_tokens": 5, "completion_tokens": 2, "total_tokens": 7}
            }
        ]
        self._send_sse_response(chunks)

    def log_message(self, format, *args):
        """静默日志（避免测试输出噪音）"""
        pass


def run_server(port: int = 19990):
    """启动Mock服务（多线程模式，避免阻塞）"""
    class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
        daemon_threads = True  # 主线程退出时自动结束子线程

    server = ThreadedHTTPServer(('0.0.0.0', port), MockInferHandler)
    print(f"Mock Infer Server started on port {port}", flush=True)
    server.serve_forever()


if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 19990
    run_server(port)
