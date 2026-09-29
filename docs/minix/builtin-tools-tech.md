# 内置工具记录、展示与回传技术设计

关联需求：

- [对应需求文档](builtin-tools-prd.md)

## 1. 架构概览

内置工具项（服务端执行的 web_search / code_interpreter / shell 等）作为一等中立内容贯穿五层：

1. 持久化层中立内容片段
2. 运行时层中立内容片段
3. Provider 采集（从终态流事件提取内置项）
4. Provider 回传（按序原样塞回请求 input）
5. 聊天 UI 展示（调用胶囊 + 结果 sheet）

核心原则：引入通用中立类型 `AgentNativeItem`，原样承载任意内置工具项的完整结构（`rawJSON`），采集、落库、展示、回传全程不解析其内部字段。新增内置工具无需改动数据模型。

采集为兜底式（catch-all）：除文本、reasoning、函数调用三个专线类型外的输出项一律原样采集。回传采用黑名单：默认把每个内置项作为独立 input 项回传，只有内联载体（标注 annotations）例外，随所属助手文本内嵌。

## 2. 核心文件

### 2.1 iOS

- 中立类型 `AgentNativeItem`、运行时 `AgentContentPart.nativeItem`、流事件 `AgentStreamEvent.nativeItem`：`Providers/AgentProvider.swift`
- 采集与回传：`Providers/OpenAI/OpenAIAgentProvider.swift`（`nativeItemCaptureSkipTypes`、`inlineCarrierTypes`、`convertMessagesResponsesAPI`）
- 持久化片段 `ContentPart.nativeItem` 与恢复 `toAgentMessage`：`Agent/Chat/ChatStore.swift`
- 落库 `buildRawMessage`：`Agent/Chat/AIChatViewModel+Persistence.swift`
- 流式采集入 UI 块：`Agent/Chat/AIChatViewModel+SSEStream.swift`
- UI 块类型 `AssistantBlockKind.nativeTool`：`Agent/Chat/ChatModels.swift`
- 胶囊渲染与统一样式 `nativeToolIcon` / `nativeToolColor`：`Views/Chat/AssistantBlockView.swift`
- 结果 sheet：`Views/Chat/ToolLiveSheet.swift`
- sheet 承载：`Views/Chat/ChatMessageViews.swift`、`Agent/MessageList/CollectionViewMessageListV3.swift`

### 2.2 Android

- 中立类型：`data/model/MinixAgentNativeItem.kt`
- 内容片段与流事件：`data/model/AgentContentPart.kt`、`data/model/ContentPart.kt`、`data/model/LLMStreamChunk.kt`
- 采集与回传：`provider/openai/OpenAIProvider.kt`
- 持久化、恢复与流消费：`ui/chat/ChatViewModel.kt`
- UI 展示：`ui/chat/ChatToolFormatting.kt`、`ChatAssistantMessageUI.kt`、`ChatToolDetailUI.kt`

双端内联落点均带 `[Minix]` 注释。

## 3. 数据模型

### 3.1 通用中立类型

```text
AgentNativeItem
  type: String        // 内置项 type，如 "web_search_call"
  id: String?         // 服务端项 id
  status: String?     // "completed" / "in_progress" 等，展示并原样回传
  rawJSON: String     // 该项的完整原始结构，原样落库、原样回传
```

### 3.2 持久化层

- `ContentPart` 新增 `case nativeItem(AgentNativeItem)`，并补齐 `CodingKeys` / `PartType` / `encode` / `init(from:)` 分支。
- 落库到既有消息 `parts_json`（TEXT），不新增列、不升 DB 版本。

### 3.3 运行时层

- `AgentContentPart` 新增 `case nativeItem(AgentNativeItem)`。
- `AgentStreamEvent` 新增 `case nativeItem(AgentNativeItem)`。

`AgentNativeItem` 与 `ReasoningEcho` 的关键差异：内置项持久化（`rawJSON` 落库），门控仅 `providerKind`；reasoning 仅存内存，门控 `providerKind + modelId`。二者互不影响。

### 3.4 标注（annotations）

标注不是独立输出项，而挂在助手 `message` 项的文本内容标注字段上（web_search 的 url_citation、未来 file_search 的 file_citation 等）。采集时聚合成一个合成 `AgentNativeItem(type: "annotations", rawJSON: 标注数组)`，走同一 `.nativeItem` 管线落库、展示、恢复。标注是内联载体，回传规则见 §5。

## 4. 采集

在 `OpenAIAgentProvider` 处理，分两个时机：`response.output_item.added`（项开始，占位）与 `response.completed`（终态，完整）。终态输出数组是完整、等价的，是结果字段的唯一可信来源；`output_item.added` 的项只有 `type` / `id` / `status`，结果字段尚未就绪。

### 4.1 兜底采集内置项

采集不维护支持类型清单：默认行为为采集，仅 `nativeItemCaptureSkipTypes`（`message` / `reasoning` / `function_call`，各有专线：文本与标注 / `ReasoningEcho` / `.toolUse`）跳过。未来新增内置工具无需改采集代码。

- `output_item.added`：遇非跳过类型且带 `id` 的项，立即以当前（空壳）整项发一个占位 `.nativeItem`（`status` 缺省记 `in_progress`）。此时 message 文本尚未流式产出，UI 据此在正确位置插入胶囊（见 §6）。无 `id` 的项跳过占位，留待终态。
- `response.completed`：遍历输出数组，非跳过类型一律序列化整项为 `rawJSON`，构造 `AgentNativeItem` 并按原序发出 `.nativeItem` 事件——携带完整结果字段，与占位同 `id`。

消费侧按 `id` 去重：占位先建、终态覆盖，`nativeItems` 每项仅保留终态完整版，首现顺序即服务端产出顺序。标注（§4.2）无 `id`、仅终态发一次，直接追加。

### 4.2 采集标注

扫描 `message` 项的文本内容标注字段，全量保留（不去重、不筛类型、保留位置锚点），聚合成合成 `AgentNativeItem(type: "annotations")`。存全部标注类型使 file_citation 等未来类型零改动顺带存储。

## 5. 回传

在 `convertMessagesResponsesAPI` 中处理。本 converter 即 Responses 家族专用，进入即满足家族门控，不比较 modelId。

### 5.1 内置项独立回传（黑名单）

内置项用黑名单 `guard !inlineCarrierTypes.contains(item.type)`：默认反序列化 `rawJSON` 后作为独立 input 项原样回传（含 `status`，见 §5.4）；仅内联载体（`annotations`）跳过。回传位置见 §5.5。

采用黑名单而非白名单：Responses API 的输出项本就可原样作为 input 回传，独立回传是默认正确行为；未登记的新内置项默认独立回传，非法时由服务端拒绝，不因遗漏而丢弃。

### 5.2 标注内嵌回传

Responses 的 input 数组接受完整助手 message，其 `output_text` 携带 `annotations`——这是 input schema 中唯一能承载标注的位置，裸标注数组不是合法 input 项。因此：

- 每条助手消息回传前预扫 `parts`，取出合成 `annotations` 项的标注数组（`pendingAnnotations`）与最后一段 `.text` 的下标（`lastTextPartIdx`）。持久化时所有 `.nativeItem` 堆在 `parts` 末尾，故需预扫定位归属文本。
- `.text` 分支：若该段是 `lastTextPartIdx` 且存在 pending 标注，把这段助手文本升级为结构化 `message`（含 `status`，见 §5.4）并原样内嵌标注（保留锚点）；否则回传最简 `{role, content}` 形态（兼容只实现简单形态的 Responses 兼容代理，仅在有标注的轮次才结构化）。
- 无任何 `.text` 段时丢弃 pending 标注。
- 合成 `annotations` 项在 `.nativeItem` 分支被黑名单跳过，不重复作为独立项。

### 5.3 门控

- 内置项与标注均无模型绑定加密内容，只门控家族、不门控 modelId，跨模型回传安全。
- reasoning 回传维持 `providerKind + modelId` 门控，跨模型自动剥离加密内容。
- 其他家族（Chat Completions、Anthropic 等）的 convertMessages 遇到 `.nativeItem` 时跳过。

### 5.4 回传项保留 `status`

回传的 output 类 input 项（`web_search_call` 等独立项、内嵌标注的 assistant `message`）必须带 `status`：

- 火山 ark 对回传项要求 `status` 必填，缺失时整请求 400 `MissingParameter: input.status`。
- OpenAI 对 `status` 的存在是容忍的（schema 中 `status` 为 optional）。

因此始终保留/补全 `status`（内置项原样带回其 `status`；内嵌标注的 message 追加 `status: "completed"`），无需按厂商分支。二者均由回放捕获请求实测确认。

### 5.5 回传顺序

同一 assistant 轮内 input 项按 `reasoning → 内置工具项 → message → function_call` 顺序回传：

- reasoning 在头部（Responses API 要求 reasoning 项不得出现在同轮 function_call 之后）。
- 内置工具项（`web_search_call` 等）先于 message：服务端在生成回答前执行（先搜索再答）。
- `function_call` 是本轮收尾动作，客户端据其执行并在下一轮补 `function_call_output`，故排在 message 之后。

实现：assistant 轮先单趟遍历 `parts` 只回传 `.nativeItem`（内联载体跳过），再走原有 `parts` 遍历回传其余（`.text` / `.toolUse` 等），`.nativeItem` 分支置空。持久化时 `parts` 已按 `[text, toolUse, nativeItem]` 聚类（非模型真实交错序），故此重排不依赖原始时序。`lastTextPartIdx` / `pendingAnnotations` 预扫仍按原始 part 下标计算，标注内嵌到最后一段文本的绑定不变。火山与 modelhub 回放捕获请求均确认该顺序 200。

## 6. UI 展示

所有 `.nativeTool(type)` 项——包括合成的 `annotations`——统一渲染为调用胶囊 `ToolCapsuleView`，点击开 `ToolLiveSheet` 展示整项 `rawJSON`：

- `AssistantBlockKind.nativeTool(type:)` 一个 case 承载全部类型；所有类型使用统一图标与配色，标签直接显示原始 `type`，新增类型无需 UI 适配。
- 每个内置项各占一个胶囊，不做按类型的合并（含 `shell_call` 与 `shell_call_output`），无单工具特判。
- 占位与回填：采集占位事件（§4.1）到达时按 `id` 新建 loading 态胶囊，插入当前位置——此刻 message 文本尚未流式输出，故胶囊排在文本前；终态事件按同 `id` 找到该胶囊回填完整 `rawJSON` 并置为 success，位置不变。无匹配胶囊（如无占位）才追加到末尾。
- 展示使用 `prettyJSON`（缩进、稳定键序、URL 斜杠不转义），持久化与回传仍使用原始 `rawJSON`。
- `ToolLiveSheet` 的 native JSON 详情使用单个只读 `UITextView`：支持全文选择与复制，自动识别 http(s) 链接并复用应用内链接预览；不使用分块 `Text`，避免选择范围被块边界截断。

标注与 code_interpreter / shell 展示口径一致（均为原始结构进 sheet），把 url_citation / file_citation / 未来任意标注类型统一收口。已知取舍：web_search 会出现 `web_search_call` 与 `annotations` 两个胶囊，语义不同（搜了什么 / 答案引用了哪些源）；`annotations` 无 `id`、仅终态产出，追加在末尾。

## 7. 持久化与恢复

- `buildRawMessage` 把 `.nativeItem` part 序列化进 `parts_json`。
- `toAgentMessage` 恢复时把持久化 `ContentPart.nativeItem` 还原为运行时 `AgentContentPart.nativeItem`。
- UI 恢复时先重建非 `annotations` 的内置工具胶囊，再按持久化 part 处理文本，最后重建 `annotations` 胶囊，稳定还原 `内置工具 → message → reference` 的流式展示顺序。该重排只作用于 UI block，不改变持久化 part 与回传结构。
- `ReasoningEcho` 不落库；重启后仅凭 DB 内置项即可回传，符合「重启后工具记忆不丢」。

## 8. 测试

关键覆盖：

- 内置项采集按原序、全量 `rawJSON` 落库
- 标注聚合为合成项、全量保留、不去重
- 重启后从 DB 恢复内置项与标注
- 同家族跨模型回传内置项成功、reasoning 加密内容剥离
- 跨家族不回传内置项、不产生结构错误
- 标注内嵌进最后一段助手文本；无文本时丢弃
- 简单形态与结构化 `output_text` 形态的分支
- 胶囊展示与 `ToolLiveSheet` 原始结构呈现
- 未开启 `include` 时结果字段为空不报错

真机端到端验证跨模型回传（同家族跨模型可复述上一轮结果、跨家族不回传）。

## 9. 上游合并参考

必须保留：

- 通用中立类型 `AgentNativeItem` 及三层 `nativeItem` 片段
- 兜底采集（catch-all）与 `nativeItemCaptureSkipTypes` 跳过集
- 黑名单回传与 `inlineCarrierTypes`
- 标注内嵌进 `output_text` 的回传路径
- 内置项按家族门控、reasoning 按家族与 modelId 门控的差异
- 统一胶囊展示（`nativeTool` 单 case + 按 type 分发）

可以接受上游：

- Responses API 输出解析更新
- 历史 reasoning 回传更新
- 工具胶囊与结果 sheet 的 UI 更新

改动 `OpenAIAgentProvider.swift` 后运行 `./scripts/minix-check-invariants.sh` 与相关测试确认无回归。

## 10. 平台实现差异

- iOS 用 `ToolLiveSheet` 承载原始结构；Android 用 `ModalBottomSheet`，支持下拉关闭。
- 双端数据模型、采集与回传逻辑对称；Android 落点见 §2.2，实现镜像 iOS。
