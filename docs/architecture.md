# OpenMinis 架构参考

> 详细架构与实现细节。日常定位用 [AGENTS.md](../AGENTS.md),需要深入某个子系统时读本文件。
> 最后更新:2026-07-30。与代码冲突时以代码为准。

---

## 1. Agent 执行链(双端对称)

```
UI(ChatViewModel) → agent loop → currentProvider.stream…() → 沙箱执行协调器(串行FIFO)
   → 沙箱内核(iSH/PRoot) → Alpine guest → (命中offload)原生桥接 → 系统 framework
```

Agent loop 逐轮:调 provider 流式出文本/思考/工具调用 → 执行工具 → 结果回填历史 → 再调,直到无工具调用或达轮次上限。

| | iOS | Android |
|---|---|---|
| agent 主循环 | `AIChatViewModel`(+ 大量 `+扩展` 文件) | `ui/chat/ChatViewModel.kt` · `runAgentLoop`(L5779) |
| 工具注册 | `AIChatViewModel+ToolDefinitions.swift` · `makeAgentTools()` | `tools/AgentTools.kt` · `makeAgentTools()` |
| 工具集(一致) | shell_execute / file_read / file_write / file_edit / read_image / browser_use / memory_write / memory_get | 同左 |

---

## 2. ⭐ Provider 抽象层(最重要、最容易改错)

### 2.1 两层中立(provider 无关)消息格式

改动消息/存储/provider 前**必须**理解:消息用**两套中立结构**解耦对话与服务商。

| 层 | iOS | Android | 说明 |
|---|---|---|---|
| **持久化**(落 DB) | `ContentPart` / `RawMessage`(ChatStore.swift:179/286)+ SQLite | `ContentPart`(data/model/ContentPart.kt)+ **Room**(MessageEntity.parts_json, minis.db) | DB 里**不存 provider/model 特有字段**,纯中立 |
| **运行时**(喂 provider) | `AgentMessage` / `AgentContentPart`(AgentProvider.swift:101/56) | `LLMMessage`(喂 provider)+ `AgentMessage`/`AgentContentPart`(data/model/AgentTypes.kt, AgentContentPart.kt) | content part:text / toolUse / toolResult / imageData |

桥接:iOS `RawMessage.toAgentMessage()`(ChatStore.swift:4120)读盘还原;反向 `buildRawMessage()`。

### 2.2 切换 provider/model 的核心机制

**换模型 = 换一个 provider 实例,历史 `[AgentMessage]` 数组不动。** 历史消息**不预转换**——同一份中立消息直接喂给新 provider,由它的 `convertMessages*` **现场翻译**成自家 wire format。

- 协议:iOS `protocol AgentProvider`(:177)· 核心方法 `streamAgentMessageClamped`(:186);Android `interface LLMProvider`(provider/LLMProvider.kt · `streamMessageClamped`)。
- 工厂:iOS `makeAgentProvider`(AIChatViewModel+ProviderFactory.swift:20);Android `ProviderFactory.create`(provider/ProviderFactory.kt:18)。
- 统一流事件:iOS `enum AgentStreamEvent`(:127);Android `LLMStreamChunk`(实际消费)+ `AgentStreamEvent`(声明为 superset)。

**两个方向的转换在哪:**
- 统一 → wire(请求体):各家 `*AgentProvider.convertMessages*`(iOS)/ `*Provider.buildRequestBody`(Android)。
- wire 响应 → 统一事件:各家 `streamAgentMessageClamped`/`streamMessageClamped` 里 `yield`/emit 统一事件。

| Provider | iOS 转换入口 |
|---|---|
| Anthropic | `convertMessages`(AnthropicAgentProvider.swift:457) |
| OpenAI 家族 | `convertMessagesChatCompletions`(:1081) / `convertMessagesResponsesAPI`(:1549) |
| Gemini | `convertMessages`(GeminiAgentProvider.swift:103) |

工具定义也是"一份中立定义 → 三种 wire schema":Android `AgentToolDefinition.toAnthropicJson()/toGeminiJson()/toOpenAIJson()`(data/model/AgentToolDefinition.kt)。

### 2.3 thinking / reasoning 参数适配(按 provider 复杂度递减)

**复杂度不来自 provider 类型本身,而来自"一个 provider 后面挂了多少种异构后端"。** 三家对比:

| Provider | 复杂度 | 原因 | 关键位置 |
|---|---|---|---|
| **OpenAI 家族** | 最高 | 承载 N 家兼容端点(OpenRouter/xAI/Kimi/火山/Azure/Mistral/DeepSeek/Qwen/sub2api…)× N 种模型,每家 thinking 传法不同 | `injectThinkingParams`(OpenAIAgentProvider.swift:864 / Android OpenAIProvider.kt:1946) |
| **Anthropic** | 中 | 主要是**模型代际**:Claude 4.6+ 用 adaptive `effort`、老模型用 `budget_tokens`;外加 Anthropic-compat 代理回填 thinking | AnthropicAgentProvider.swift:75-97;`modelUsesAdaptiveThinking(model.id)` |
| **Gemini** | 低 | 后端基本只有 Google 自己;`thinkingConfig` + Gemini 3.x `thoughtSignature` | GeminiAgentProvider.swift |

**结论**:"按 model id / host 分支"这个模式**三家都有**(Anthropic 的 `modelUsesAdaptiveThinking(model.id)` 也是按模型名判断),只是 OpenAI 因兼容端点最多而分支最密。**不是 OpenAI 独有的复杂设计。**

**OpenAI 家族三维度判断**(改兼容 provider 时重点):
1. **provider 标志**(工厂按类型设):iOS `useOpenRouterCompat`/`isMistral`/`forceResponsesAPI`/`isAzure`;Android 无独立标志,靠 `basePath.contains(...)` 反推。
2. **baseURL host**:`usesUnifiedReasoningEffort`(iOS OpenAIProvider.swift:149 / Android:390)认 `volces`/`ark.`(火山方舟)、Azure → 强制统一 `reasoning_effort`。
3. **model id 前缀/子串**:`o1/o3/o4/gpt-5/gpt-4`→`reasoning_effort`;`qwen`→`enable_thinking`+`thinking_budget`;`deepseek-v4`→vendor `thinking`;`deepseek/glm/kimi/minimax`→不发参数(自反思);`mimo/agnes`→只接受 low/med/high。

**thinking 上限预 clamp**:`ThinkingLevelCatalog`(双端同名)一张按 model id 匹配的上限表 → 请求前 `min(level, catalogMax)`(iOS AgentProvider.swift:203)。**新增模型若后端拒绝高 thinking 档,在这里加规则。**

**Chat Completions vs Responses API**:`usesChatCompletionsAPI`(OpenAIProvider.swift:579):`forceResponsesAPI`→Responses;API Key→Chat;自定义 baseURL+OAuth→Chat;官方 Codex OAuth→Responses。

### 2.4 三类高差异内容的处理(改 provider 时重点回归)

- **tool_use/tool_result 配对**:Anthropic 要求每个 tool_use 后紧跟 tool_result,否则 400 → 有自愈 pass `injectMissingToolResults`(AnthropicAgentProvider.swift:535)/`stripOrphanToolResults`。OpenAI 也有两遍 sanitize 修配对顺序。
- **reasoning/thinking**:①明文(Kimi/DeepSeek/QwQ)存 `AgentMessage.reasoningContent`(持久化);②加密(OpenAI Responses)存 `reasoningEcho`(AgentProvider.swift:81,**仅内存不持久化**,跨模型切换自动丢弃,App 重启后跨轮加密推理链丢失——设计取舍);③Gemini 3.x `thoughtSignature` 附在 `ToolUse` 上持久化,缺签名的 tool call 会降级为文本。
- **图片**:统一 `AgentContentPart.imageData`。OpenAI 下因 `role:tool`/`function_call_output` 不能带图,工具结果图片被**改挂成合成 `role:user` 消息**;均用 `supportedModalities.contains(.imageInput)` gate。

### 2.5 `prompt_cache_key`(OpenAI Responses API)

**不是 sessionId。** `derivePromptCacheKey`(OpenAIAgentProvider.swift:779):取第一条 user 文本 SHA256 前 32 hex → `"minis-<hex32>"`(首条 user 文本每轮原样重发,故同会话稳定、跨会话不同);无 user 文本 fallback 随机 UUID。这层拿不到 conversation_id,且为兼容 sub2api 等不做服务端 fallback 的端点。只在 agent 循环里出现,offload/title 路径没有。

---

## 3. 沙箱与原生桥接

- **沙箱内核**:iOS `src/ios/iSH/`(ISHKernel.m / ISHShellExecutor.m / RootfsManager.swift)+ `Agent/ISH/ISHExecutionCoordinator.swift`(串行 FIFO,一次一条命令);Android `sandbox/`(PRootKernel.kt / RootfsManager.kt / ExecutionCoordinator.kt / PersistentShell.kt / PtyBridge.kt)+ JNI `src/android/app/src/main/cpp/`(pty_bridge.c / crash_handler.cpp / jieba_jni.cpp)。
- **offload 机制**:guest `execve` 注册命令路径 → 内核拦截 → 原生 handler → 系统 framework → JSON 回传。iOS = `NativeOffloads/*.m/.h`(22 个);Android = `sandbox/NativeOffload.kt`(abstract unix socket 服务)+ `sandbox/offload/*Handler.kt` + `offload/*Manager.kt`(三层)。
- **minis:// URL**:会话级资源定位,命名空间 `attachments`/`workspace`/`offloads`/`browser`。URL **不含 sessionId**,始终对当前活跃会话解析;切会话走 harvest→clear→mount→register。详见 [specs/minis-url-scheme.md](specs/minis-url-scheme.md)。
  - **注意**:`minis://` 既是 agent 内部资源 URL(进程内解析,不走系统路由),也是外部深链 scheme。改 scheme 名要区分这两类——资源 URL 改动会波及几十处 agent 逻辑,风险大。

---

## 4. 关键目录速查

### iOS(`src/ios/`)
- `Agent/Chat/` — agent loop 核心(`AIChatViewModel` + `+ToolDefinitions/+SSEStream/+ISHCommand/+FileTools/+MemoryTools/+Compaction/+Offloading/+ConcurrentTools/+Fallback/+Persistence/+ProviderFactory` 等扩展)
- `Providers/` — LLM provider(Anthropic/OpenAI/Gemini/xAI/Kimi/OpenRouter/Antigravity + Voice),`AgentProvider.swift`(协议)、`LLMProviderFactory.swift`、`ThinkingLevelCatalog.swift`、`LLMTypes.swift`
- `iSH/` + `Agent/ISH/` — 沙箱;`NativeOffloads/` — 原生能力;`Views/` — UI;`Agent/Sync/` — iCloud 同步
- 入口:`MinisApp.swift`、`AppDelegate.swift`、`Shared/DeepLinkRouter.swift`

### Android(`src/android/app/src/main/java/com/openminis/app/`,根包 `com.openminis.app`)
- `ui/chat/ChatViewModel.kt` — agent loop(~9844 行,`runAgentLoop` L5779)+ `ChatViewModel{Store,UiStateExt,MentionExt,SlashExt}.kt`
- `provider/` — LLMProvider + ProviderFactory + 各家子目录;`data/model/` — AgentTypes/AgentContentPart/LLMMessage/ContentPart/AgentToolDefinition;`data/db/` — Room
- `sandbox/` + `sandbox/offload/` + `offload/` — 沙箱与原生;`tools/` — 工具实现;`ui/` — Compose
- 入口:`MinisApp.kt`、`MainActivity.kt`、`deeplink/`
- ⚠️ 别混淆:`providers/`(复数)只有 `MinisDocumentsProvider.kt`(Android SAF,与 LLM 无关);`antigravity/` 目录只有 `AntigravityModelsApi.kt`,ProviderType 枚举里**没有** antigravity。

---

## 5. 双端对称速查表

| 维度 | iOS | Android |
|---|---|---|
| Provider 协议 | `AgentProvider` | `LLMProvider` |
| 统一入口 | `streamAgentMessage(Clamped)` | `streamMessage`/`sendMessage`→`…Clamped` |
| 运行时中立消息 | `AgentMessage`/`AgentContentPart` | `LLMMessage` + `AgentMessage`/`AgentContentPart` |
| 统一流事件 | `AgentStreamEvent` | `LLMStreamChunk`(实际)+ `AgentStreamEvent`(superset) |
| 持久化中立格式 | `ContentPart`/`RawMessage` + SQLite | `ContentPart` + Room(minis.db) |
| thinking 上限表 | `ThinkingLevelCatalog.swift` | `ThinkingLevelCatalog.kt` |
| thinking 参数注入 | `OpenAIAgentProvider.injectThinkingParams` | `OpenAIProvider.injectThinkingParams` |
| OpenAI 兼容复用 | `OpenAIAgentProvider` | `OpenAIProvider` |
| agent 主循环 | `AIChatViewModel` | `ChatViewModel.runAgentLoop` |

**改任何跨端功能,默认需要 iOS + Android 两侧对称实现。** Android 代码里大量注释显式标 `Mirrors iOS ...`,改动时优先查对端对应实现。

---

## 6. scripts/ 目录用途

| 脚本 | 用途 | 触发时机 |
|---|---|---|
| `update-axel.sh` | 同步上游到 axel + 按需重编 deps + 验证([见 AGENTS.md](../AGENTS.md)) | 手动,同步上游时 |
| `gen_debug_skill.sh` / `gen_debug_skill_android.sh` | 生成 debug server 的 skill 文档(base64 嵌入) | Xcode/Gradle 构建阶段自动 |
| `prepare_android_sandbox.sh` | 下载 Android 的 Alpine rootfs + proot 二进制 | 手动,Android native deps 构建 |
| `prepare_rootfs.sh` / `install_alpine.sh` / `optimize_rootfs.sh` | QEMU 制作/优化 Alpine qcow2 镜像(rootfs 底层工具) | 极少,制作 rootfs 时手动 |
| `update_models_dev.sh` | 更新内置 models.dev 模型注册表 JSON | 周期性手动 |
| `symbolicate_hang.py` | 崩溃/卡顿日志符号化 | 调试时手动 |

> 这些脚本的产物大多**会进 git**(如 models JSON、debug skill),官方跑过后同步 main 就自动带来,**无需在 update-axel.sh 里重复调用**。gen_debug_skill 已是构建期自动触发。
