# 服务商与模型请求头、请求体自定义需求

## 1. 文档信息

- 状态：已实现，待评审
- 平台：iOS、Android
- 需求边界：服务商和模型的 Header、Body 自定义
- 关联需求：
  - [对应技术设计](provider-model-request-customization-technical.md)
  - [自定义请求控制需求](request-controls-requirements.md)
  - [表达式能力需求](request-expression-language-requirements.md)
- 数据原则：当前仍处于开发阶段，不兼容开发期旧字段和中间数据结构

## 2. 背景

不同模型服务商、兼容网关和模型版本经常要求不同的认证补充字段、客户端标识、Body 参数或实验性开关。原有“自定义 User-Agent”只能修改一个 Header，无法覆盖一般网关和新模型的请求差异。

若继续在 Provider 代码中按服务商、Base URL 或模型 ID 添加分支，会产生以下问题：

- 新协议或新模型必须等待 App 更新。
- 相同兼容协议被重复适配，分支持续增加。
- Provider 热点文件与上游改动冲突频繁。
- 用户无法修正代理网关的私有字段要求。

因此需要以通用 Header、Body 自定义替换专用 User-Agent 配置，并允许在服务商和模型两个层级分别配置。

## 3. 目标

1. 服务商支持自定义 Header 和 Body。
2. 模型支持自定义 Header 和 Body。
3. 表达式可以读取服务商、模型、会话、当前 Header 和当前 Body。
4. 用户可通过帮助入口查看语法、变量、函数、合并规则和示例。
5. 用户配置在协议默认请求之后应用，并具备稳定、可解释的覆盖顺序。
6. 用户可以通过普通 Header 表达式设置 `User-Agent`，不再维护专用字段。
7. 配置可保存、分享、导入并在双端保持一致语义。

## 4. 非目标

- 不在服务商层提供 Request Controls；Request Controls 属于模型能力。
- 不执行任意 JavaScript，也不引入 JavaScript 引擎。
- 不恢复原有的“自定义 User-Agent”专用配置字段。
- 不兼容开发期旧表达式语法或中间数据库版本。
- 不通过本需求改变 Provider 的响应解析、思考内容展示或历史 reasoning 回传。

## 5. 配置层级

### 5.1 服务商

服务商详情页提供：

- 自定义请求头
- 自定义请求体
- 帮助入口
- 表达式即时校验

服务商 Header 和 Body 属于该服务商实例，应用于其下所有模型。

### 5.2 模型

模型详情页提供：

- 自定义请求头
- 自定义请求体
- Request Controls 入口
- 从另一模型复制完整请求配置
- 帮助入口
- 表达式即时校验

模型配置只影响当前模型条目。复制操作同时复制 Header、Body 和 Request Controls，不复制模型能力、显示名或其他模型属性。

## 6. 请求应用顺序

真实请求必须按以下固定顺序构造：

1. Provider 或 SDK 生成协议默认请求。
2. 应用服务商 Header。
3. 应用服务商 Body。
4. 应用模型 Header。
5. 应用模型 Body。
6. 应用模型 Request Controls。
7. 发送最终请求。

规则：

- 后层可以覆盖前层。
- 同层表达式按界面顺序执行。
- 同层后一行可以读取前一行刚写入的 Header 或 Body。
- 用户最终结果直接发送，不得在定制后恢复认证、客户端标识或 Body 默认值。
- Codex OAuth、Claude OAuth 等先生成完整协议默认请求，再进入同一应用顺序。

## 7. 编辑器规则

### 7.1 基本格式

每行一个赋值：

```text
key = expression
```

Header 编辑器的左值是 Header 名称：

```text
User-Agent = "custom-client/1.0"
X-Session = session.id
```

Body 编辑器的左值是相对 Body 路径：

```text
temperature = 0.7
reasoning.summary = "auto"
metadata["session-id"] = session.id
```

服务商和模型专用编辑器已经限定目标，因此左值不写 `headers.` 或 `body.` 前缀。

### 7.2 可读取信息

表达式可读取：

- `provider.id`
- `provider.label`
- `provider.type`
- `provider.credentialType`
- `provider.apiKey`
- `provider.baseURL`
- `model.id`
- `model.displayName`
- `model.provider`
- `session.id`
- `headers.<name>`
- `body.<path>`

完整语法和函数定义见 [表达式能力需求](request-expression-language-requirements.md)。

### 7.3 合并与删除

- Header 名称和 Header 引用不区分大小写。
- Body 对象递归合并。
- 标量和数组由后值替换。
- `null` 写入真实 JSON null。
- `delete()` 删除目标 Header 或 Body 字段。
- 显式空字符串必须保留。
- 最终表达式结果为 `missing` 时跳过该行。
- Header 最终值必须是字符串；Header 删除必须使用 `delete()`。

## 8. 帮助与错误反馈

Header、Body 编辑区必须提供信息按钮。帮助内容至少包含：

- 每行一个赋值的格式
- 可用上下文变量
- 路径和模板示例
- `missing`、`null`、`delete()` 的区别
- Header 大小写规则
- 对象递归合并和数组替换规则
- 常用函数和完整表达式示例
- 与 Request Controls 左值格式的区别

编辑时必须显示带行号的错误信息。存在无效表达式时：

- 保存按钮不可用。
- 离开页面时仍按统一未保存修改流程处理。
- 不得静默丢弃整份配置。

iOS 的服务商请求配置、模型请求配置使用“取消/保存”事务：

- 禁用系统右滑返回和下滑关闭。
- 点击取消且存在未保存修改时，允许保存、放弃或继续编辑。
- 不存在修改时，取消可直接关闭页面。

导入配置或运行时上下文仍可能产生静态校验无法判断的类型错误或资源超限。此时仅跳过失败行并记录不含敏感值的诊断信息，后续表达式及请求构建继续。

## 9. 持久化、分享与导入

- 服务商的 Header、Body 配置随服务商实例一起保存。
- 模型的 Header、Body 配置随该模型条目一起保存。
- 空列表不产生额外请求行为。
- 服务商分享必须包含服务商配置及其模型请求配置。
- 导入后表达式文本保持原样，不在导入阶段求值。
- 不保留原有的专用 User-Agent 配置或转换兼容逻辑。

## 10. 安全与隐私

- `provider.apiKey` 只在表达式实际引用时读取。
- API Key 不写入日志、分享文件或持久化表达式结果。
- 表达式只能访问显式提供的请求上下文，不可访问文件系统、网络、进程或任意 App 对象。
- 日志不得输出最终认证 Header 或完整敏感 Body。

## 11. 验收标准

1. 双端均可新增、编辑、保存并重新加载服务商 Header 和 Body。
2. 双端均可新增、编辑、保存并重新加载模型 Header 和 Body。
3. `User-Agent` 可通过普通 Header 表达式覆盖，不存在专用配置字段。
4. 同名 Header 大小写不同仍按同一 Header 覆盖。
5. Body 对象递归合并，标量和数组按规则替换。
6. `null`、`delete()`、空字符串和 `missing` 行为符合定义。
7. 同层后一行可以读取前一行结果。
8. 固定应用顺序在 OpenAI、Anthropic、Gemini 及 OAuth 请求路径一致。
9. 分享导入和数据库 round trip 后表达式不丢失。
10. 无效表达式显示行号并阻止保存。
11. 单行运行时错误不影响后续表达式和请求发送。
