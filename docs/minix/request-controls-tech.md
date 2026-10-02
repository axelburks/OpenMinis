# 自定义请求控制技术设计

关联需求：

- [对应需求文档](request-controls-prd.md)

## 1. 架构概览

Request Controls 由四层组成：

1. 持久化控制定义
2. App 级思考档位注册表
3. 每个会话或草稿的当前模型运行快照
4. 聊天 UI 与请求编排

表达式语法由 [表达式能力技术设计](exp-lang-tech.md) 定义，请求 Header、Body 的基础编排由 [服务商与模型请求头、请求体自定义技术设计](request-customization-tech.md) 定义。

## 2. 核心文件

### 2.1 iOS

- 控制模型、默认模板、运行状态、编排：`Providers/MinixRequestControls.swift`
- 档位注册表：`Providers/MinixThinkingLevelRegistry.swift`
- 模型配置 UI：`Views/Providers/MinixRequestCustomizationViews.swift`
- 聊天面板：`Views/Chat/MinixChatRequestControls.swift`
- 聊天弹层编排：`Views/Chat/AIChatView.swift`
- 会话控制状态与解析：`Agent/Chat/AIChatViewModel+MinixRequestControls.swift`
- fallback：`Agent/Chat/AIChatViewModel+Fallback.swift`
- 上游默认兼容规则：`Providers/Thinking/ThinkingRuleResolver.swift`
- 上游规则持久化/UI：`Providers/ProviderConfigDB.swift`、`Views/Providers/ThinkingRulesSection.swift`

### 2.2 Android

- 控制模型：`data/model/MinixRequestControlModels.kt`
- 档位注册表：`data/model/MinixThinkingLevelRegistry.kt`
- 默认模板、运行状态、编排：`provider/MinixRequestCustomization.kt`
- 模型配置 UI：`ui/settings/MinixModelRequestCustomizationEditor.kt`
- 档位管理 UI：`ui/settings/MinixThinkingLevelsManagerDialog.kt`
- 图标选择 UI：`ui/components/MinixRequestControlIcons.kt`
- 聊天面板：`ui/chat/MinixChatRequestControls.kt`
- 聊天弹层编排：`ui/chat/ChatScreen.kt`
- 会话与 fallback：`ui/chat/ChatViewModel.kt`
- 上游默认兼容规则：`provider/thinking/ThinkingRuleResolver.kt`
- 上游规则持久化/UI：`data/db/ProviderDatabase.kt`、`ui/settings/ThinkingRulesSection.kt`

## 3. 控制数据模型

```text
RequestBodyControl
  id
  title
  iconName
  kind: toggle | optionGroup
  semanticKind: thinkingBudget?
  isEnabled
  defaultIsActive
  defaultOptionID
  isSliderEnabled
  sliderStartColorHex?
  sliderEndColorHex?
  payloadExpressions
  options[]

RequestBodyControlOption
  id
  thinkingDefinitionId?
  title
  payloadExpressions
```

说明：

- `payloadExpressions` 同时支持 Header 和 Body，通过左值根区分。
- Toggle 使用 control 自身的 `payloadExpressions`。
- Option Group 使用选中 option 的 `payloadExpressions`。
- `semanticKind` 是明确语义，不扫描表达式文本判断是否为思考控制。
- `id` 用于运行状态；思考语义使用 `thinkingDefinitionId`。

## 4. 运行状态

```text
RequestBodyControlState
  toggleValuesByControlID
  selectedOptionIDsByControlID

RequestBodyControlRuntimeSnapshot
  activeModelKey
  state
```

存储：

- iOS：`UserDefaults`，key 前缀 `requestBodyControls.state.session.`
- Android：`SharedPreferences("request_body_control_state")`

完整 key 只包含会话或草稿 ID。值中的 `activeModelKey` 保存当前 `ModelEntry.id`，同一个 key 下不保留历史模型的多份状态。

读取规则：

1. 仅当请求允许读取交互状态，且 snapshot 的 `activeModelKey` 与当前 `ModelEntry.id` 相同时读取 state。
2. snapshot 不存在、模型不匹配或请求不允许读取交互状态时使用配置默认值。
3. 选项 ID 已删除时回退到默认选项。
4. 默认选项也无效时使用第一可用选项。
5. Slider 只保存 `selectedOptionIDsByControlID`；连续位置仅是 UI 拖动期间的瞬时状态。
6. `activateModel` 遇到相同 `activeModelKey` 时保留 state，遇到不同 key 时用空 state 替换整个 snapshot。
7. 新会话首次发送前使用草稿 ID；创建真实会话后迁移单个 snapshot 并删除草稿键。

请求上下文拆分为：

```text
expressionSessionId
useConversationRequestControlState
```

- 普通聊天：当前 session + `true`。
- 标题、压缩、已有会话语音纠错：当前 session + `false`。
- Quick Test、模型列表刷新、`minis-model-use`：`nil` + `false`。
- `minis-model-use` 的 raw、image、image-edit 额外设置 `includeControls = false`：仍执行 Provider/Model Header 与 Body，但不执行 Request Controls。
- iOS 使用两个独立 `TaskLocal`；Anthropic OAuth pending patcher 同时捕获两者。
- Android 使用 `LLMProvider.requestSessionId` 和 `usesConversationRequestControlState` 两个独立属性。

## 5. App 级档位注册表

```text
ThinkingLevelDefinition
  definitionId
  levelId
  title
  rank
  isBuiltIn
```

内置定义顺序：

```text
off, minimal, low, medium, high, xhigh, max, ultra
```

约束：

- 内置 `definitionId` 固定。
- 自定义 `definitionId` 为 UUID。
- `levelId` 可编辑且唯一。
- rank 由数组顺序重新编号。
- 持久引用只能保存 `definitionId`。

持久化：

- iOS 将完整定义数组保存在 `UserDefaults`。
- Android 将完整定义数组保存在 `SharedPreferences("request_controls_thinking_levels")`。
- 保存时规范化别名、恢复内置定义的固定身份信息，并按数组位置重新编号 `rank`。
- 读取时补回缺失的内置定义，但不级联修复任何外部引用。
- 管理页允许全部定义参与排序；内置定义不可编辑或删除。

## 6. 可用档位解析

### 6.1 无自定义思考控制

```text
supportsReasoning == false -> []
otherwise -> ThinkingLevel.allCases up to catalogMaxThinkingLevel
unknown catalog model -> xhigh
```

随后将原生 `ThinkingLevel` 转换为内置 `definitionId`。

### 6.2 有自定义思考控制

可用列表直接来自启用的 `thinkingBudget` 控制：

```text
control.options
  -> filter valid thinkingDefinitionId
  -> deduplicate
  -> sort by registry rank
```

不经过 `ThinkingLevelCatalog`，也不限制在 `ultra`。

### 6.3 解析算法

```text
requested ID exact in available -> exact ID
requested definition exists -> highest available rank <= requested rank
requested definition missing -> off
off unavailable -> first available
```

自定义定义高于 `ultra` 时：

- `definitionId` 始终保持自定义值。
- Request Control 精确选择其 option。
- `nativeLevel` 仅为通用 Provider/UI 投影到最近内置级别，通常为 `.ultra`。
- 因自定义思考控制关闭内置注入，投影值不会覆盖自定义表达式。

## 7. 内置 thinking 注入切换

```text
disablesBuiltInThinkingInjection =
  exists enabled control where semanticKind == thinkingBudget
```

Provider 路径必须遵守：

- `false`：执行完整上游默认链路。上游已接线的 OpenAI Chat Completions 路径进入 `ThinkingRuleResolver`（Provider 用户规则优先、内置规则兜底）；Responses、Anthropic、Gemini 和 Antigravity 执行各自的上游协议映射。
- `true`：跳过 resolver 或协议默认 thinking 字段，只执行控制表达式。

不得通过搜索表达式是否包含 `thinking`、`reasoning` 或 `effort` 推断语义。

## 8. 默认模板

默认模板只负责初始化编辑器，不参与后续自动适配。

当前生成规则：

```text
OpenAI Chat / Kimi / default:
  body.reasoning_effort = "<level>"

OpenAI Responses:
  body.reasoning = {effort: "<level>", summary: "auto"}

OpenRouter:
  body.reasoning.effort = "<level>"

Anthropic off:
  body.thinking = {type: "disabled"}

Anthropic enabled:
  body.thinking = {type: "adaptive", display: "summarized"}
  body.output_config.effort = "<mapped>"

Gemini / Antigravity:
  body.generationConfig.thinkingConfig =
    {thinkingLevel: "<mapped>", includeThoughts: true}
```

Antigravity 复用 Gemini 模板：其请求定制作用于信封内层的 Gemini 格式 body，因此 `body.generationConfig.*` 的形状与 Gemini 一致。

模板档位集合按 Provider 最新协议生成，不按旧模型 ID 生成兼容分支。用户保存后，表达式文本是唯一事实来源。

后续向思考控制加入档位时复用同一模板入口，并按 Provider 的实际路由判断 Chat Completions 或 Responses；因此 Codex OAuth 不会误生成 `reasoning_effort`。只有内置档位自动生成表达式，自定义档位保持空白，由用户定义 wire shape。

## 9. 控制执行

伪代码：

```text
state = load(
  sessionId,
  modelEntryId,
  useConversationRequestControlState
)

for control in controls where control.isEnabled:
  if toggle:
    lines = runtimeToggle ? control.payloadExpressions : []
  if optionGroup:
    option = resolveSelectedOption(control, state, thinkingDefinitionId)
    lines = option.payloadExpressions

  for line in lines:
    applyControlExpression(line, currentHeaders, currentBody)
```

每条表达式执行后立即更新 Header、Body，保证后续控制和后续行可读取结果。

## 10. Provider 默认链路

无自定义思考控制时，Provider 保留上游默认行为：

- OpenAI Chat：保留上游 `ThinkingRuleResolver` 及其原有 `providerInstanceId` 接线边界，不借助 Minix `requestCustomization` 扩大 Provider 用户规则的适用范围；Android Mistral 继续使用独立传输门禁。
- OpenAI Responses：`reasoning.effort`
- OpenRouter：`reasoning.effort`
- Anthropic：Provider 原生 thinking 格式
- Gemini：Provider 原生 thinking 格式

Provider 主体不得复制 `ThinkingRuleResolver` 已拥有的分支：

- 不在 `OpenAIAgentProvider` / `OpenAIProvider` 中重新展开按厂商、Base URL 或模型 ID 的 thinking 分支。
- 上游新增或修正的兼容规则保留在 `ThinkingRuleResolver` 中。
- Provider Thinking Rules 的用户规则只适用于 OpenAI Chat Completions；Responses、Anthropic、Gemini 和 Antigravity 的设置页继续显示不支持提示。
- Minix 语义思考控制优先级高于 resolver：启用时整个默认链路被短路，随后由 Request Control 表达式写入最终字段。

用户差异由 Request Controls 表达。

## 11. 聊天 UI

双端 Minix 面板负责：

- 读取当前模型 controls
- 渲染 Toggle、Option Group、Slider
- 按当前会话或草稿 ID 写运行状态
- 更新当前会话的 `thinkingDefinitionId`
- 展示图标、标题和当前值

配置 UI 约束：

- 顶层控制、普通选项、思考选项和自定义档位均使用从右向左滑动删除。
- 新增控制使用单一菜单入口。
- 图标、复制来源、默认选项及思考档位使用独立可滚动选择页。
- 思考选项只选择已注册的 `definitionId`，不直接编辑 `levelId`。
- 聊天面板最大高度为 `min(screenHeight * 0.36, 300)`；低于上限时按内容高度展示。
- iOS 模型请求配置和思考档位管理使用“取消/保存”，隐藏系统返回键并禁用右滑返回；存在未保存修改时由取消按钮进入确认流程。

上游聊天页只保留：

- Request Controls 按钮入口
- `/`、Mention、Request Controls 三种弹层状态
- `inputPopupOverlay`/对应 Android overlay 定位
- 焦点和键盘协调

这种拆分降低上游聊天 UI 更新时的冲突。

## 12. 模型切换与 fallback

会话全程保存不可变 `definitionId`：

1. 当前模型解析 available IDs。
2. 精确 ID 可用则保持。
3. 不可用时按 rank 向下 clamp。
4. 将解析后的实际有效 ID 写回会话，由现有响应式状态同步 UI 和 Provider。
5. 切换分组或分组成员时，有分组默认档位则先覆盖；否则保留当前值再下调。
6. Request Control snapshot 在模型切换时整体替换，A→B→A 不恢复旧 A。
7. fallback 候选的普通 Request Controls 使用候选默认状态；语义思考控制继承会话 `definitionId`，再按候选可用档位向下 clamp。内部标题、压缩和语音纠错把 `thinkingDefinitionId` 保持为 `nil`，让控件的 `defaultOptionID` 决策，不得用调用参数的 `off` 覆盖默认项。
8. fallback 请求的 system prompt 统一从基础 prompt、候选模型 capability/behavior、父会话 skills/MCP、memory 内容和 memory 状态 footer 组装；取得 stream handle 后再补片段为时已晚。
9. fallback 取得候选 stream 后沿用上游行为立即提交会话模型 binding；若请求期间用户已选择其他模型，则保持该用户选择。
10. 候选档位沿既有流完成和运行时激活路径写回，不额外引入终态白名单、跨字段事务或思考选择 revision。

`ThinkingLevel` 只是 Provider 兼容投影，不作为持久外键。

## 13. 删除、分享与同步

引用统计覆盖：

- 模型 Request Control options
- 模型分组默认档位
- 会话 inference config
- Android session DB 引用

删除不级联，Registry 统一 fallback。

CloudKit：

- `ThinkingLevelDefinitionsV3` 同步完整定义列表。
- `ProviderThinkingRuleV3` 保留上游 Provider 用户规则同步。
- 按 `updatedAt` 做 LWW。

备份：

- iOS 和 Android 均保留上游 Provider Thinking Rules 的导出与恢复。
- Android 规则表位于 Provider DB v4 的 `provider_thinking_rules`。

分享导入：

1. 相同 `definitionId` 保留本地定义。
2. 不同 UUID、相同 `levelId` 生成 ID remap。
3. 其他定义按 rank 合并。
4. 导入 controls 应用 remap。

## 14. 校验

保存前必须检查：

- 表达式语法有效。
- 思考 option 均有 `thinkingDefinitionId`。
- 同一思考控制无重复 definition。
- definition 当前已注册。
- 默认 option ID 存在或为空。

运行时仍需防御已导入或已删除定义造成的悬空引用。

## 15. 测试

关键覆盖：

- Toggle 默认值和运行值
- Option Group 默认、选择和删除 fallback
- Slider 只持久化离散 option ID
- 同模型连续使用及重启恢复
- 新会话隔离和 A→B→A 默认值
- 草稿单 snapshot 迁移
- 表达式 session ID 与交互状态读取解耦
- fallback 候选普通控件默认状态、语义档位继承/clamp、即时模型 binding 与用户模型切换保护
- Header/Body 混合表达式
- `semanticKind` 检测
- 自定义档位精确匹配
- 自定义档位突破 `ultra`
- 新增内置档位复用实际 Provider 路由模板，自定义档位保持空表达式
- rank 向下 clamp
- 悬空 ID fallback
- 模型 fallback 保持 definition ID
- raw、image、image-edit 保留 Provider/Model 层并跳过 Request Controls
- CloudKit、分享和数据库 round trip
- Provider Thinking Rules 的 DB/UI/缓存/同步/备份链路
- 无语义思考控制时 resolver 生效，启用时 resolver 被短路
- Codex Responses 在无自定义控制且选择 Off 时保留上游 `low` 兜底
- Gemini `minimal` 作为启用档位请求 `includeThoughts`
- 聊天面板自动化

## 16. 上游合并参考

必须保留：

- `definitionId` 持久引用
- 自定义思考控制精确替代内置注入
- 自定义控制不受 Catalog/`ultra` 限制
- 上游 Provider Thinking Rules 的 DB、UI、缓存、同步、备份和 resolver 接线
- OpenAI Chat Completions 的用户规则优先、内置规则兜底
- Provider 主体不重复实现 resolver 已拥有的厂商 thinking 分支
- 独立 `MinixChatRequestControls.*`
- `/`、Mention、Request Controls 弹层互斥

可以接受上游：

- Provider 协议默认映射更新
- 响应 thinking/reasoning 解析更新
- 历史 reasoning 回传更新
- 聊天输入框布局和上游交互更新

合并后运行静态守卫和双端相关测试。

## 17. 平台实现差异

- iOS、Android 的 Provider 与模型请求配置均使用独立配置页；模型页支持顶层 Request Controls 拖动排序及左滑删除，持久列表顺序即运行时执行顺序。
- 双端均保存完整思考档位列表，内置和自定义档位共享同一 `rank` 顺序；内置档位只禁止编辑和删除，不禁止排序。
- 双端均使用二级选择页处理图标、复制来源、默认选项和思考档位；Android 使用全屏 Compose 页面承载长列表滚动。
- Android 聊天 Slider 使用圆形 thumb、渐变进度轨道和离散档位锚点，与 iOS 保持相同交互语义。
- iOS、Android 均支持为 Slider 保存可选起止颜色并实时预览；iOS 使用系统颜色选择器，Android 使用 HSV 颜色选择器，字段和运行时渐变语义保持一致。
