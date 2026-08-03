# TrajProxy E2E 测试用例总览

> 本文档为 E2E 测试文档的索引入口。共 **62 个场景**，分布于 5 个测试层。
> 详细测试步骤与验收标准已按系列拆分到下列子文档中。

---

## 文档结构

| 序号 | 子文档 | 内容 | 场景数 | 编号范围 |
|---|---|---|---|---|
| — | [e2e-framework.md](e2e-framework.md) | 测试框架概述：层架构、命名规范、断言工具、缓存递增规则、全局配置、服务地址 | — | — |
| 1 | [e2e-nginx.md](e2e-nginx.md) | Nginx 入口层 | 2 | N101-N102 |
| 2 | [e2e-proxy-p1xx-p2xx.md](e2e-proxy-p1xx-p2xx.md) | Proxy 直连层：API 与模型管理 | 22 | P101-P111, P201-P211 |
| 3 | [e2e-proxy-p3xx.md](e2e-proxy-p3xx.md) | Proxy 直连层：轨迹与数据一致性 | 9 | P301-P309 |
| 4 | [e2e-proxy-p4xx.md](e2e-proxy-p4xx.md) | Proxy 直连层：缓存命中验证 | 11 | P401-P411 |
| 5 | [e2e-archive.md](e2e-archive.md) | 归档调度层 | 4 | A100-A103 |
| 6 | [e2e-comparison.md](e2e-comparison.md) | 对比测试层：vLLM vs Proxy 响应对比 | 14 | C101-C107, C201-C207 |
| 7 | [e2e-performance.md](e2e-performance.md) | 性能测试层：稳定性、并发、流式并发 | 3 | T101-T103 |
| **合计** | | | **65** | |

---

## 1. 测试层架构

| 层 | 端口 | 场景数 | 说明 |
|---|---|---|---|
| **Nginx 入口层** | 12345 | 2 | 经 Nginx 入口的基本 chat/轨迹冒烟测试 |
| **Proxy 直连层** | 12300 | 39 | 模型 CRUD、参数透传、轨迹捕获、缓存命中、解析器等 |
| **归档调度层** | — | 4 | 归档配置、手动/定时归档、归档恢复 |
| **对比测试层** | 12300/12345 | 14 | vLLM 直连 vs Proxy 响应对比（OpenAI + Claude 格式；12300 模型注册，12345 请求入口） |
| **性能测试层** | 12345 | 3 | 稳定性、并发、流式并发 |

---

## 2. 场景命名规范

| 前缀 | 含义 |
|---|---|
| `N1xx` | Nginx 入口层测试 |
| `P1xx` | 模型管理测试 |
| `P2xx` | 请求处理测试 |
| `P3xx` | 轨迹与数据一致性测试 |
| `P4xx` | 缓存命中验证测试 |
| `A1xx` | 归档测试 |
| `C1xx` | OpenAI 格式对比测试 |
| `C2xx` | Claude 格式对比测试 |
| `T1xx` | 性能测试 |

完整编号体系、迁移对照表、矩阵覆盖分析详见 [test-case-catalog.md](test-case-catalog.md)。

---

## 3. 调用链路

```
Nginx(:12345) → LiteLLM → trajproxy(:12300) → vLLM(:8080)     # Nginx/Performance 层
trajproxy(:12300) → vLLM(:8080)                                 # Proxy 直连层
trajproxy(:12300) → Nginx(:12345) ↔ vLLM(:8080)                # 对比层（Proxy vs vLLM）
```

---

## 4. 快速索引

### N1xx — Nginx 入口层（2 个）

- [N101 — 基础 Chat 轨迹存储（非流式冒烟）](e2e-nginx.md)
- [N102 — 流式 Chat 轨迹存储（流式冒烟）](e2e-nginx.md)

### P1xx/P2xx — API 与模型管理（19 个）

- [P101 — 模型 CRUD](e2e-proxy-p1xx-p2xx.md)
- [P102 — PANGU 格式](e2e-proxy-p1xx-p2xx.md)
- [P103 — 重复注册（幂等性）](e2e-proxy-p1xx-p2xx.md)
- [P104 — 预设模型保护](e2e-proxy-p1xx-p2xx.md)
- [P105 — 未注册模型](e2e-proxy-p1xx-p2xx.md)
- [P106 — 无效模型参数](e2e-proxy-p1xx-p2xx.md)
- [P107 — 并发限流](e2e-proxy-p1xx-p2xx.md)
- [P108 — Processor 懒加载](e2e-proxy-p1xx-p2xx.md)
- [P109 — Processor LRU 缓存命中](e2e-proxy-p1xx-p2xx.md)
- [P110 — 预设模型懒加载](e2e-proxy-p1xx-p2xx.md)
- [P111 — LRU 逐出与重新加载](e2e-proxy-p1xx-p2xx.md)
- [P201 — 参数透传（Direct 模式）](e2e-proxy-p1xx-p2xx.md)
- [P202 — 参数过滤（TITO 模式）](e2e-proxy-p1xx-p2xx.md)
- [P203 — Logprobs 强制覆盖与返回过滤](e2e-proxy-p1xx-p2xx.md)
- [P204 — chat_template_kwargs 透传与消费](e2e-proxy-p1xx-p2xx.md)
- [P205 — 自定义 Tool Parser](e2e-proxy-p1xx-p2xx.md)
- [P206 — 自定义 Reasoning Parser](e2e-proxy-p1xx-p2xx.md)
- [P207 — TITO Token 模式冒烟（非流式）](e2e-proxy-p1xx-p2xx.md)
- [P208 — TITO Token 模式冒烟（流式）](e2e-proxy-p1xx-p2xx.md)

### P3xx — 轨迹与数据一致性（9 个）

- [P301 — 基础轨迹捕获](e2e-proxy-p3xx.md)
- [P302 — EOS Token 一致性](e2e-proxy-p3xx.md)
- [P303 — TITO 流式/非流式轨迹一致性](e2e-proxy-p3xx.md)
- [P304 — Direct 模式流式/非流式轨迹一致性](e2e-proxy-p3xx.md)
- [P305 — PANGU 集成 + 轨迹捕获](e2e-proxy-p3xx.md)
- [P306 — TITO Tool 轨迹存储](e2e-proxy-p3xx.md)
- [P307 — Trajectories API 测试](e2e-proxy-p3xx.md)
- [P308 — 轨迹查询 fields 参数](e2e-proxy-p3xx.md)
- [P309 — 轨迹字段交叉验证](e2e-proxy-p3xx.md)

### P4xx — 缓存命中验证（11 个）

- [P401 — TITO 非流式 3 轮缓存](e2e-proxy-p4xx.md)
- [P402 — TITO 非流式 Tool 2 轮缓存](e2e-proxy-p4xx.md)
- [P403 — TITO 非流式 T+R 3 轮缓存](e2e-proxy-p4xx.md)
- [P404 — TITO 流式 T+R 3 轮缓存](e2e-proxy-p4xx.md)
- [P405 — TITO 非流式 Reasoning 3 轮缓存](e2e-proxy-p4xx.md)
- [P406 — TITO 流式 3 轮缓存](e2e-proxy-p4xx.md)
- [P407 — 混合模式 3 轮 T+R 缓存](e2e-proxy-p4xx.md)
- [P408 — T+R 单轮冒烟](e2e-proxy-p4xx.md)
- [P409 — 无 Session 缓存跳过](e2e-proxy-p4xx.md)
- [P410 — kwargs 变更缓存失效](e2e-proxy-p4xx.md)
- [P411 — tools 变更缓存失效](e2e-proxy-p4xx.md)

### A1xx — 归档调度层（4 个）

- [A100 — 归档进程配置验证](e2e-archive.md)
- [A101 — 手动触发归档](e2e-archive.md)
- [A102 — 未过期数据不归档](e2e-archive.md)
- [A103 — 归档数据恢复](e2e-archive.md)

### C1xx — OpenAI 格式对比（7 个）

- [C101 — Direct T+R Parser 一致性](e2e-comparison.md)
- [C102 — TITO 纯文本一致性](e2e-comparison.md)
- [C103 — TITO Tool 一致性](e2e-comparison.md)
- [C104 — TITO Reasoning 一致性](e2e-comparison.md)
- [C105 — TITO Reasoning+Tool 一致性](e2e-comparison.md)
- [C106 — 多轮 T+R 非流式一致性](e2e-comparison.md)
- [C107 — 多轮 T+R 流式一致性](e2e-comparison.md)

### C2xx — Claude 格式对比（7 个）

- [C201 — Claude Direct T+R Parser 一致性](e2e-comparison.md)
- [C202 — Claude TITO 纯文本一致性](e2e-comparison.md)
- [C203 — Claude TITO Tool 一致性](e2e-comparison.md)
- [C204 — Claude TITO Reasoning 一致性](e2e-comparison.md)
- [C205 — Claude TITO Reasoning+Tool 一致性](e2e-comparison.md)
- [C206 — Claude 多轮 T+R 非流式一致性](e2e-comparison.md)
- [C207 — Claude 多轮 T+R 流式一致性](e2e-comparison.md)

### T1xx — 性能测试层（3 个）

- [T101 — 长稳测试](e2e-performance.md)
- [T102 — 并发测试](e2e-performance.md)
- [T103 — 流式并发压测](e2e-performance.md)

---

## 5. 相关文档

- [test-case-catalog.md](test-case-catalog.md)：完整编号体系、迁移对照表、矩阵覆盖分析
- [e2e-framework.md](e2e-framework.md)：测试框架、断言工具、缓存校验规则、全局配置

---

## 6. 目录结构

```
tests/e2e/
├── config.sh                     # 全局配置
├── run_tests.sh                  # 总入口脚本
├── utils.sh                      # 公用断言工具
└── layers/
    ├── nginx/                    # N1xx
    ├── proxy/                    # P1xx/P2xx/P3xx/P4xx
    ├── archive/                  # A1xx
    ├── comparison/               # C1xx/C2xx（含 compare.py）
    └── performance/              # T1xx
```
