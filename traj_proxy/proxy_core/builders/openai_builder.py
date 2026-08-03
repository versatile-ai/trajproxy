"""
OpenAIResponseBuilder - OpenAI 格式响应构建器

负责构建 OpenAI 格式的完整响应，支持工具调用和推理内容解析。
"""

import json
import uuid
from typing import Any, Dict, Optional, List, TYPE_CHECKING
import traceback

from traj_proxy.proxy_core.builders.base import BaseResponseBuilder
from traj_proxy.utils.logger import get_logger

if TYPE_CHECKING:
    from traj_proxy.proxy_core.context import ProcessContext
    from traj_proxy.proxy_core.parsers.parser_manager import Parser

logger = get_logger(__name__)


class OpenAIResponseBuilder(BaseResponseBuilder):
    """OpenAI 格式响应构建器

    支持：
    1. 从响应文本解析 tool_calls
    2. 从响应文本解析 reasoning
    3. 构建标准 OpenAI 响应格式
    """

    def __init__(self, model: str, parser: "Parser"):
        """初始化 OpenAIResponseBuilder

        Args:
            model: 模型名称
            parser: Parser 实例（用于解析工具调用和推理内容）
        """
        self.model = model
        self.parser = parser

    def build(
        self,
        content: str,
        context: "ProcessContext"
    ) -> Dict[str, Any]:
        """构建 OpenAI 格式的完整响应

        Args:
            content: 响应内容
            context: 处理上下文

        Returns:
            OpenAI 格式的响应字典
        """
        tool_calls = None
        reasoning = None
        final_content = content
        finish_reason = "stop"

        # 1. 从 token_response 获取预置字段
        infer_response = getattr(context, "token_response", None)
        choice_logprobs = None
        choice_token_ids = None
        msg_refusal = None
        msg_audio = None
        msg_function_call = None
        if infer_response:
            choices = infer_response.get("choices", [])
            if choices:
                choice0 = choices[0]
                tool_calls = choice0.get("tool_calls")
                finish_reason = choice0.get("finish_reason", "stop")
                choice_logprobs = choice0.get("logprobs")
                choice_token_ids = choice0.get("token_ids")
                msg0 = choice0.get("message", {}) or {}
                msg_refusal = msg0.get("refusal")
                msg_audio = msg0.get("audio")
                msg_function_call = msg0.get("function_call")

        # 2. 先解析推理内容（对齐 vllm DelegatingParser.extract_response_outputs）
        # vllm 的处理顺序：先 reasoning → 后 tool_calls
        # reasoning parser 先从原始模型输出提取 ─┘ 包裹的推理文本，
        # 返回 reasoning-free 的 content，供 tool parser 在干净文本上解析。
        # 此顺序确保 tool XML 标记（┐┌ 等）不会泄漏到 reasoning_content。
        try:
            extracted_reasoning, extracted_content = active_parser.extract_reasoning(
                content, context.raw_request
            )
            # 对齐 vLLM v0.16.0 chat_completion/serving.py:1496-1504：
            # extract_reasoning 返回值无条件使用，不做 truthy 检查。
            # 空 think（reasoning=""）时若跳过赋值，final_content 会保留
            # 原始输出导致 </think> 泄漏进 content；
            # include_reasoning=False 时也仅置 reasoning 为 None，
            # content 仍取解析后的干净文本（vLLM 同款行为）。
            reasoning = extracted_reasoning
            final_content = extracted_content
            if not context.request_params.get("include_reasoning", True):
                reasoning = None
            if reasoning:
                logger.debug(f"解析到推理内容，长度: {len(reasoning)}")
        except Exception as e:
            logger.warning(f"[{context.unique_id}] 推理解析失败: {e}\n{traceback.format_exc()}")

        # 3. 从 reasoning-free 的 content 中解析 tool_calls
        # 对齐 vLLM _parse_tool_calls_from_content()（/vllm/entrypoints/openai/engine/serving.py:455-570）的三分支逻辑：
        # - 分支 A: named + supports_required_and_named=True → 标准 JSON 解析
        #   vLLM 有 guided decoding 保证 content 是 JSON，但 proxy 没有，
        #   因此先尝试 tool parser 解析，若成功（说明 content 是 XML 等非 JSON 格式）
        #   则降级到分支 C 逻辑；若 parser 未解析出 tool calls（content 本身就是 JSON），
        #   则走标准 JSON 解析。
        # - 分支 B: required + supports_required_and_named=True → JSON 列表解析
        # - 分支 C: auto / named(False) / required(False) → tool parser 的 extract_tool_calls()
        # finish_reason 规则对齐 vLLM serving.py:1319-1346:
        #   named → "stop", required/auto → "tool_calls"
        raw_request = context.raw_request or {}
        tool_choice = raw_request.get("tool_choice", "auto")
        is_named_choice = isinstance(tool_choice, dict) and tool_choice.get("type") == "function"
        supports_required_and_named = getattr(
            self.parser._tool_parser, 'supports_required_and_named', True
        )

        if not tool_calls:
            # --- 分支 A: named + supports_required_and_named=True ---
            # 对齐 vLLM _parse_tool_calls_from_content 分支 A:
            # 直接取 content 作为 arguments（标准 JSON 解析）。
            # vLLM 有 guided decoding 保证 content 是 JSON，但 proxy 没有，
            # 因此先尝试 tool parser 解析作为 fallback。
            if is_named_choice and supports_required_and_named:
                func_spec = tool_choice.get("function", {})
                func_name = func_spec.get("name")
                if func_name and final_content:
                    parser_result = None
                    try:
                        parser_result = self.parser.extract_tool_calls(
                            final_content, context.raw_request
                        )
                    except Exception as e:
                        logger.warning(f"[{context.unique_id}] named 分支 parser fallback 失败: {e}")

                    if parser_result and parser_result.tools_called and parser_result.tool_calls:
                        # parser 成功解析（content 是 XML 等非 JSON 格式）→ 降级到分支 C 逻辑
                        matched_tc = next(
                            (tc for tc in parser_result.tool_calls
                             if tc.function.name == func_name), None
                        )
                        if matched_tc:
                            tool_calls = [{
                                "id": matched_tc.id or f"call_{uuid.uuid4().hex[:24]}",
                                "type": "function",
                                "function": {
                                    "name": matched_tc.function.name,
                                    "arguments": matched_tc.function.arguments
                                }
                            }]
                            final_content = parser_result.content
                            # 对齐 vLLM: named tool_choice 的 finish_reason 保留 "stop"
                            logger.debug(f"[{context.unique_id}] named tool_choice parser fallback: {func_name}")
                        else:
                            # parser 解析出 tool calls 但无匹配函数名 → 标准 JSON 解析
                            tool_calls = [{
                                "id": f"call_{uuid.uuid4().hex[:24]}",
                                "type": "function",
                                "function": {
                                    "name": func_name,
                                    "arguments": final_content
                                }
                            }]
                            final_content = None
                            logger.debug(f"[{context.unique_id}] named tool_choice: parser 无匹配, 走标准 JSON 解析")
                    else:
                        # parser 未解析出 tool calls → content 本身是 JSON（如 Hermes）
                        # 对齐 vLLM 分支 A: 直接取 content 作为 arguments
                        tool_calls = [{
                            "id": f"call_{uuid.uuid4().hex[:24]}",
                            "type": "function",
                            "function": {
                                "name": func_name,
                                "arguments": final_content
                            }
                        }]
                        final_content = None
                        logger.debug(f"[{context.unique_id}] named tool_choice: 走标准 JSON 解析")

            # --- 分支 B: required + supports_required_and_named=True ---
            # 对齐 vLLM: 解析 content 为 JSON 函数列表。
            elif tool_choice == "required" and supports_required_and_named:
                try:
                    parsed = json.loads(final_content or "[]")
                    if isinstance(parsed, list):
                        tool_calls = [{
                            "id": f"call_{uuid.uuid4().hex[:24]}",
                            "type": "function",
                            "function": {
                                "name": item.get("name", ""),
                                "arguments": json.dumps(item.get("parameters", {}), ensure_ascii=False)
                            }
                        } for item in parsed]
                        final_content = None
                        finish_reason = "tool_calls"
                        logger.debug(f"[{context.unique_id}] required tool_choice: 解析 JSON 列表")
                except (json.JSONDecodeError, ValueError) as e:
                    logger.debug(f"[{context.unique_id}] required JSON 列表解析失败: {e}, 降级到 parser")

            # --- 分支 C: auto / named(False) / required(False) → tool parser ---
            # 对齐 vLLM 分支 C: 自动工具调用解析（也作为 named/required 的降级分支）
            if not tool_calls:
                try:
                    result = self.parser.extract_tool_calls(
                        final_content, context.raw_request
                    )
                    if result.tools_called and result.tool_calls:
                        tool_calls = [
                            {
                                "id": tc.id,
                                "type": tc.type,
                                "function": {
                                    "name": tc.function.name,
                                    "arguments": tc.function.arguments
                                }
                            }
                            for tc in result.tool_calls
                        ]
                        final_content = result.content
                        # finish_reason 规则对齐 vLLM serving.py:1319-1346:
                        # named → "stop"（保留 infer_response 原值，不覆盖）
                        # required/auto → "tool_calls"
                        if not is_named_choice:
                            finish_reason = "tool_calls"
                        logger.debug(f"[{context.unique_id}] 从文本解析到 {len(tool_calls)} 个工具调用")
                except Exception as e:
                    logger.warning(f"[{context.unique_id}] 工具调用解析失败: {e}\n{traceback.format_exc()}")

        # 构建消息体
        # 当有 tool_calls 时，content 至少保留 "" 而非 None
        # 确保 LiteLLM 转换 Claude 格式时生成 text block（对齐 vLLM 三段结构）
        if tool_calls:
            normalized_content = final_content if (final_content and final_content.strip()) else ""
        else:
            # 无 tool_calls 时，保持原有规范化逻辑
            normalized_content = final_content if (final_content and final_content.strip()) else None
        message = {
            "role": "assistant",
            "content": normalized_content,
            "annotations": None,
            "audio": msg_audio,
            "function_call": msg_function_call,
            "refusal": msg_refusal,
        }

        if reasoning:
            message["reasoning"] = reasoning
            message["reasoning_content"] = reasoning

        if tool_calls:
            message["tool_calls"] = tool_calls

        choice = {
            "index": 0,
            "message": message,
            "logprobs": choice_logprobs,
            "token_ids": choice_token_ids,
            "finish_reason": finish_reason,
        }

        raw_usage = (infer_response or {}).get("usage", {}) or {}
        return {
            "id": f"chatcmpl-{context.request_id}",
            "object": "chat.completion",
            "created": int(context.start_time.timestamp()) if context.start_time else 0,
            "model": self.model,
            "choices": [choice],
            "usage": {
                "prompt_tokens": context.prompt_tokens or 0,
                "completion_tokens": context.completion_tokens or 0,
                "total_tokens": context.total_tokens or 0,
                "prompt_tokens_details": raw_usage.get("prompt_tokens_details"),
                "completion_tokens_details": raw_usage.get("completion_tokens_details"),
            },
            "kv_transfer_params": None,
            "prompt_logprobs": None,
            "prompt_token_ids": None,
            "service_tier": None,
            "system_fingerprint": None,
        }

    def build_chunk(
        self,
        content: str,
        context: "ProcessContext",
        finish_reason: Optional[str] = None,
        tool_calls_delta: Optional[List[Dict[str, Any]]] = None,
        reasoning_delta: Optional[str] = None
    ) -> Dict[str, Any]:
        """构建 OpenAI 格式的流式响应块

        Args:
            content: 本次输出的内容片段
            context: 处理上下文
            finish_reason: 结束原因（仅最后一个 chunk 有值）
            tool_calls_delta: 工具调用的增量数据
            reasoning_delta: 推理内容的增量

        Returns:
            OpenAI 格式的 chunk 字典
        """
        import time

        chunk = {
            "id": f"chatcmpl-{context.request_id}",
            "object": "chat.completion.chunk",
            "created": int(context.start_time.timestamp()) if context.start_time else int(time.time()),
            "model": self.model,
            "choices": [{
                "index": 0,
                "delta": {},
                "finish_reason": finish_reason
            }]
        }

        delta = {}

        # 第一个 chunk 包含 role
        if context.stream_chunk_count == 0:
            delta["role"] = "assistant"

        # 添加内容
        if content:
            delta["content"] = content

        # 添加推理内容
        if reasoning_delta:
            delta["reasoning"] = reasoning_delta

        # 添加 tool_calls 增量
        if tool_calls_delta:
            delta["tool_calls"] = tool_calls_delta

        chunk["choices"][0]["delta"] = delta
        return chunk

    def build_chunk_with_tool_calls(
        self,
        context: "ProcessContext",
        tool_calls: List[Dict[str, Any]],
        finish_reason: Optional[str] = None
    ) -> Dict[str, Any]:
        """构建包含完整 tool_calls 的流式响应块

        Args:
            context: 处理上下文
            tool_calls: 工具调用列表
            finish_reason: 结束原因

        Returns:
            OpenAI 格式的 chunk 字典
        """
        import time

        chunk = {
            "id": f"chatcmpl-{context.request_id}",
            "object": "chat.completion.chunk",
            "created": int(context.start_time.timestamp()) if context.start_time else int(time.time()),
            "model": self.model,
            "choices": [{
                "index": 0,
                "delta": {},
                "finish_reason": finish_reason
            }]
        }

        # 第一个 chunk 包含 role
        if context.stream_chunk_count == 0:
            chunk["choices"][0]["delta"]["role"] = "assistant"

        # 添加 tool_calls
        if tool_calls:
            chunk["choices"][0]["delta"]["tool_calls"] = tool_calls

        return chunk
