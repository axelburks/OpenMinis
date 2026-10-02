# 自定义请求控制需求

## 1. 文档信息

- 状态：已实现，待评审
- 平台：iOS、Android
- 需求边界：模型 Request Controls、思考档位、聊天选择入口
- 关联需求：
  - [对应技术设计](request-controls-tech.md)
  - [服务商与模型请求头、请求体自定义需求](request-customization-prd.md)
  - [表达式能力需求](exp-lang-prd.md)

## 2. 背景

思考强度、温度、Web Search 和实验性能力在不同 Provider、兼容网关和模型之间存在细微差异。上游通过 Provider Thinking Rules 维护已知的 OpenAI Chat Completions 兼容规则；Minix Request Controls 为单个模型提供可编辑的最终覆盖能力。

请求控制把“用户在聊天时选择的离散状态”映射为一组 Header/Body 表达式。未启用语义思考控制时保留上游默认行为；启用后由该控制完整接管 thinking 字段，避免默认注入与用户表达式叠加。

## 3. 目标

1. 支持 Toggle 和 Option Group 两种控制。
2. Option Group 可切换为离散渐变 Slider。
3. 用户可以完整编辑控制名称、图标、默认状态、选项、顺序和表达式。
4. 支持语义化思考强度控制，并允许自定义档位突破内置档位集合与内置最高档位。
5. 未配置自定义思考控制时继续使用上游默认链路，包括适用路径上的 Provider Thinking Rules。
6. 配置自定义思考控制时精确替代内置 thinking 注入。
7. 聊天页提供独立 Request Controls 按钮，不再把思考强度放在 `/` 菜单中。
8. 每个会话或草稿只保存当前模型条目的一份运行状态快照，新会话和模型切换从目标模型的配置默认值开始。

## 4. 非目标

- 不在 Minix Request Controls 中复制上游 Provider Thinking Rules；已知兼容规则仍由上游 resolver 集中维护。
- 不在服务商层配置 Request Controls。
- 不改变 Provider 响应解析、思考内容展示和历史 reasoning 回传。
- 不要求所有控制都是思考强度；普通控制完全由用户定义。
- 不承诺用户表达式一定被目标服务接受，App 只保证按配置发送。

## 5. 控制模型

### 5.1 Toggle

Toggle 包含：

- 标题
- 图标
- 是否启用该控制
- 默认开关状态
- 开启时应用的表达式列表

运行行为：

- 控制被禁用：不显示、不执行。
- 控制启用但运行状态关闭：显示但不执行表达式。
- 运行状态开启：按顺序执行表达式。

示例：

```text
标题：Web Search
body.tools = append(body.tools, {type: "web_search"})
```

### 5.2 Option Group

Option Group 包含：

- 标题
- 图标
- 是否启用该控制
- 默认选项
- 选项列表
- 每个选项的标题和表达式
- 是否使用 Slider

普通 Option Group 的选项顺序由用户管理。选中一个选项时，只执行该选项的表达式。

### 5.3 Slider

Option Group 开启 Slider 后：

- 仍然只选择离散选项，不产生连续业务值。
- Slider 位置映射到有序选项。
- 拖动时显示渐变样式。
- 普通控制按配置顺序排列。
- 思考控制按 App 级档位 `rank` 排列。

## 6. 配置管理

模型详情页必须支持：

- 通过单一“添加请求控制”菜单新增 Toggle、Option Group 或思考强度控制
- 左滑删除控制
- 编辑控制标题和图标
- 启用或禁用控制
- 增加、左滑删除和排序普通选项
- 编辑选项标题和表达式
- 为思考选项选择其他尚未占用的已注册档位
- 设置默认开关或默认选项
- 开关 Slider
- 从另一模型复制 Header、Body 和 Request Controls
- 图标、默认选项、思考档位和复制来源使用可滚动二级选择页

思考控制约束：

- 一个模型最多一个启用的 `thinkingBudget` 语义控制。
- 每个选项必须引用一个已注册的 `definitionId`。
- 同一思考控制内不得重复引用同一档位。
- 思考选项顺序由 App 级档位 `rank` 决定，不单独拖动。

iOS 的模型请求配置和思考档位管理属于事务型编辑：

- 使用“取消/保存”操作，不使用系统返回箭头。
- 禁用右滑返回和下滑关闭，防止绕过未保存修改处理。
- 点击取消且存在修改时，允许保存、放弃或继续编辑。

## 7. Request Control 表达式目标

Request Controls 使用统一表达式列表，通过左值根区分目标：

```text
body.max_tokens = 4096
body.thinking = {type: "enabled", reasoning_effort: "medium"}
headers.X-Feature = "enabled"
headers.X-Legacy = delete()
```

左值必须以以下形式开始：

- `body.`
- `body[...]`
- `headers.`
- `headers[...]`

语法、函数和类型规则见 [表达式能力需求](exp-lang-prd.md)。

## 8. 默认思考强度行为

### 8.1 未配置自定义思考控制

- UI 使用 App 内置档位及其最高上限。
- 内置顺序为 `off`、`minimal`、`low`、`medium`、`high`、`xhigh`、`max`、`ultra`。
- 未命中内置档位的推理模型默认最高为 `xhigh`。
- 模型不支持推理时不显示档位。
- OpenAI Chat Completions 路径按上游原有接线执行 `ThinkingRuleResolver`；Minix 不扩大 Provider 用户规则的适用范围，Android Mistral 保留上游独立传输门禁。
- OpenAI Responses、Anthropic、Gemini 和 Antigravity 继续执行各自上游协议映射；这些路径不开放 Provider Thinking Rules 编辑。
- OpenAI App 语义 `off` 映射为 wire `"none"`。
- Codex OAuth 不开放 `ultra` 特例。

### 8.2 配置自定义思考控制

- 自定义控制的选项精确替代内置选项。
- App 跳过 Provider 内置 thinking 注入。
- 选中的档位精确匹配控制选项时直接执行该选项表达式。
- 不再应用内置档位上限。
- 用户可创建 rank 高于 `ultra` 的自定义档位并设置任意协议值。
- 高于 `ultra` 的档位在通用原生等级展示中可投影为 `.ultra`，但请求仍执行自定义档位的原始表达式，不会被裁剪。

这保证用户可在 App 尚未认识新 wire 档位时自行适配，例如：

```text
levelId: extreme
body.reasoning.effort = "extreme"
```

## 9. 默认模板

用户新增思考控制时，App 根据当前 Provider 类型生成“当前最新协议”的初始模板：

- OpenAI Chat：`reasoning_effort`
- OpenAI Responses：`reasoning.effort`
- OpenRouter：`reasoning.effort`
- Anthropic：adaptive thinking + `output_config.effort`
- Gemini：`generationConfig.thinkingConfig.thinkingLevel`
- xAI：当前支持的 low/medium/high 选项

模板只是可编辑初始值：

- 不按旧模型 ID 做兼容。
- 不保证未来协议永远不变。
- 用户可删除、增加或修改任何选项。
- 后续加入内置档位时按当前 Provider 的实际路由生成表达式（包括 Codex OAuth 的 Responses 路由）；自定义档位不猜测 wire shape，表达式留空。
- 新 Provider 格式需要 App 更新模板，但已有用户表达式继续生效。

## 10. App 级思考档位

### 10.1 定义

每个 App 级思考档位包含：

- 一个稳定不变的档位标识（`definitionId`），用于被模型控制、分组和会话引用，且不随重命名而改变。
- 一个可编辑、本地唯一的语义别名（`levelId`），仅允许小写字母、数字和下划线。
- 一个可编辑的显示标题。
- 一个由列表顺序决定的排序位置（`rank`）。
- 是否为内置档位的标记。

模型控制、模型分组和会话只保存 `definitionId`，不保存别名或标题。

### 10.2 编辑

- 内置档位不可删除。
- 全部档位都可拖动排序；内置档位只允许修改 `rank`，不可编辑别名和标题。
- 自定义档位可新增、编辑，并在双端通过左滑删除。
- `levelId` 仅允许小写字母、数字和下划线。
- 修改 `levelId` 或标题不修改任何引用。
- 删除被引用档位时双端均需确认。

### 10.3 删除与 fallback

- 删除前统计模型、分组和会话引用。
- 存在引用时显示风险提示。
- 确认后不级联清理引用。
- 悬空引用 fallback 到 `off`；若 `off` 不可用则使用第一可用档位。
- 定义恢复后，原 `definitionId` 引用自动恢复。

### 10.4 模型切换与 fallback

- 先精确匹配相同 `definitionId`。
- 精确值不可用时，按 `rank` 向下选择最高可用档位。
- 无较低档位时使用 `off` 或第一可用档位。
- 降级后的实际有效 `definitionId` 写回会话，切回原模型时不恢复切换前的较高档位。
- 切换分组或分组成员时，目标分组存在默认档位则先覆盖当前值；未设置默认档位和直接选择模型时保留当前值再按目标模型下调。
- fallback 候选取得 stream 后沿用上游行为立即更新模型绑定；用户已中途选择其他模型时不覆盖该选择。

## 11. 聊天交互

- 从 `/` 菜单移除思考强度控制。
- 在 `/` 左侧显示 Request Controls 按钮。
- 按钮展开当前模型的思考强度及其他启用控制。
- Request Controls、`/` 和 Mention 共用输入弹层并互斥。
- 弹层不改变 composer 高度，按内容自适应；最大高度为屏幕高度的 36%，且不超过 300pt/dp。
- 输入框获得焦点时立即关闭弹层。
- 打开弹层时关闭键盘。
- 标题下方思考强度仅展示，不提供点击切换。

## 12. 运行状态

每个会话或草稿只保存一个当前模型的运行状态快照，快照记录当前是哪个模型条目，以及该模型下每个控制的开关状态和已选选项。

配置结构和运行状态分离：

- 同一模型条目连续使用（包括 App 重启后重新打开同一会话）恢复当前快照。
- A→B 时丢弃 A 的状态并使用 B 默认值；B→A 时 A 也重新使用默认值，不恢复旧 A。
- 同一 model ID、不同 Provider 或不同模型条目仍视为模型切换。
- 新会话不继承同一模型在其他会话中的运行选择。
- Slider 只持久化离散的选中选项；拖动中的连续位置仅存在于 UI 内存，松手后吸附到选项。
- 普通聊天请求读取会话快照；标题、压缩和已有会话语音纠错可向表达式提供 session ID，但只使用模型配置默认状态。
- Quick Test、模型列表刷新和 `minis-model-use` 不提供表达式 session ID，也不读取会话快照；其中 raw、image、image-edit 仅执行 Provider/Model Header 与 Body，不执行 Request Controls。
- fallback 候选的普通控件使用候选默认状态；语义思考档位继承会话 `definitionId` 并按候选能力向下 clamp。请求保留原有 skills、MCP、memory 与状态 footer；模型绑定沿用上游的 stream 创建成功即更新行为，用户中途选择其他模型时不覆盖该选择。
- 没有会话上下文的轻量请求不读取其他会话状态，直接使用配置默认值。
- 修改默认值不覆盖已有运行选择。
- 删除控制或选项后，无法匹配的状态安全回退到当前默认值。

## 13. 分享与同步

- App 级档位定义参与 iOS 端的账号云同步。
- iOS 上游 Provider Thinking Rules 继续通过 `ProviderThinkingRuleV3` 同步，并参与备份恢复。
- Android Provider Thinking Rules 继续存放在 Provider DB v4，并参与备份恢复。
- 服务商分享包含模型 Request Controls 和引用的档位定义。
- 导入优先按 `definitionId` 合并。
- 不同 UUID 但相同 `levelId` 时，将导入引用重映射到本地定义。
- 相同 `definitionId` 保留本地标题、别名和顺序。

## 14. 验收标准

1. 双端可创建、编辑、删除 Toggle 和 Option Group。
2. Toggle 关闭时不执行，开启时执行。
3. Option Group 只执行选中选项。
4. Slider 正确映射到离散选项。
5. Request Controls 可同时修改 Header 和 Body。
6. 未配置自定义思考控制时使用内置档位和 Provider 协议映射。
7. 配置自定义思考控制时跳过内置 thinking 注入。
8. 自定义档位可高于 `ultra`，且请求表达式不被裁剪。
9. 模型切换和 fallback 按 `definitionId`、`rank` 工作。
10. 删除被引用档位会提示，删除后安全 fallback。
11. 聊天页三个输入弹层互斥且不改变输入框高度。
12. 运行状态在重启后恢复同一会话的当前模型快照；新会话及 A→B→A 的每次模型切换使用目标模型配置默认值。
13. 双端保存完整思考档位数组，重启及分享导入后保留内置档位和自定义档位的统一顺序。
14. Android 的长列表选择页可滚动，控制、选项和自定义档位均支持左滑删除。
15. iOS 事务型编辑页禁用右滑返回，取消操作正确处理未保存修改。
16. 未启用语义思考控制时，上游 Provider Thinking Rules 的内置规则和用户规则保持有效；启用后 resolver 与协议默认 thinking 注入均被跳过。
17. raw、image、image-edit 保留 Provider/Model Header 与 Body，但不执行 Request Controls。
