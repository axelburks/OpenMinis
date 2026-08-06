# 服务商与模型请求头、请求体自定义技术设计

## 1. 设计目标

在 Provider 已生成协议默认请求之后、网络发送之前，使用统一编排层修改工作 Header 和 Body。表达式实现、配置 UI 和运行时编排尽量放在 Minix-owned 文件中，上游 Provider 文件只保留必要接入点。

关联设计：

- [对应需求文档](provider-model-request-customization-requirements.md)
- [自定义请求控制技术设计](request-controls-technical.md)
- [表达式能力技术设计](request-expression-language-technical.md)

## 2. 模块边界

### 2.1 iOS

- 表达式 AST：`Providers/MinixRequestExpression.swift`
- 请求编排：`Providers/MinixRequestControls.swift`
- 配置 UI：`Views/Providers/MinixRequestCustomizationViews.swift`
- Provider 配置：`ProviderInstance.swift`
- 模型配置：`ModelEntry.swift`
- SQLite：`ProviderConfigDB.swift`
- 分享与导入：`ProviderConfigStore.swift`
- Provider 工厂：`LLMProviderFactory.swift`
- Anthropic 网络拦截：`Anthropic/OAuthHTTPClient.swift`

### 2.2 Android

- 表达式 AST：`provider/MinixRequestExpression.kt`
- 请求编排：`provider/MinixRequestCustomization.kt`
- 共享表达式 UI：`ui/settings/MinixRequestExpressionEditor.kt`
- Provider 配置 UI：`ui/settings/MinixProviderRequestCustomizationScreen.kt`
- 模型配置 UI：`ui/settings/MinixModelRequestCustomizationEditor.kt`
- Provider/模型配置：`data/model/ProviderConfig.kt`
- Room 映射：`data/db/ProviderConfigMapping.kt`
- Room 数据库：`data/db/ProviderDatabase.kt`
- 分享与导入：`data/repository/ProviderRepository.kt`
- Provider 工厂：`provider/ProviderFactory.kt`

## 3. 数据模型

### 3.1 服务商配置

双端语义：

```text
customRequestHeaders: [String]
customRequestBody: [String]
```

数据库使用单一 `request_customization_json`：

```json
{
  "headers": [
    "User-Agent = \"custom-client/1.0\"",
    "X-Session = session.id"
  ],
  "body": [
    "temperature = 0.7"
  ]
}
```

设计约束：

- Header、Body 必须共用同一 envelope。
- 不创建 `custom_request_headers_json`。
- 不创建 `custom_user_agent` 或 `customUserAgent`。
- 空数组解码为空配置。

Minix 是全新 App，没有历史用户和旧数据，因此 `request_customization_json` 直接作为 `ProviderInstanceEntity` 的内联列声明，由 Room 在首次建库时随表创建。Provider DB 版本保持在官方基线 v3，不新增 v3→v4 迁移，也不保留任何开发阶段的中间 schema：

```text
ProviderDatabase.version = 3   // 官方基线，不升级
ProviderInstanceEntity.requestCustomizationJson  // 内联列，无迁移
```

iOS 侧同理，不因本需求引入任何数据库版本升级或迁移。

### 3.2 模型配置

iOS：

```text
ModelOverrides.customRequestHeaders: [String]?
ModelOverrides.customRequestBody: [String]?
```

Android：

```text
ModelOverrides.customRequestHeaders: List<String>
ModelOverrides.customRequestBody: List<String>
```

模型配置与其他 override 一同持久化、分享和导入。空配置必须满足 `ModelOverrides.isEmpty`。

## 4. 运行时上下文

求值上下文包含：

```text
provider
model
sessionId
apiKey
headers
body
```

每次应用表达式前都基于最新工作 Header、Body 创建上下文，因此后一层及同层后一行可以读取已有修改。

`provider.apiKey` 使用惰性读取：

- 未被任何表达式引用时，不提前读取 OAuth Token。
- 被引用时，仅在内存中提供给本次求值。
- 不写入运行状态、分享文件或日志。

## 5. 编排算法

伪代码：

```text
headers, body = protocolDefaultRequest()

applyHeader(provider.headers, headers, body)
applyBody(provider.body, headers, body)
applyHeader(model.headers, headers, body)
applyBody(model.body, headers, body)
applyControls(model.controls, headers, body)

send(headers, body)
```

应用规则：

1. Header 表达式生成字符串或删除标记。
2. Body 表达式生成 overlay。
3. Body overlay 递归合并对象。
4. 标量和数组覆盖。
5. 删除标记在合并时移除字段。
6. 每行成功后立即更新工作值。
7. 最终 `missing` 只跳过当前行。
8. Parser 和静态 Validator 可确定的错误在保存前阻止。
9. 依赖运行时值的类型错误或求值超限只跳过当前行，后续行和请求构建继续。

## 6. Header 处理

Header 使用大小写不敏感查找和替换：

```text
authorization
Authorization
AUTHORIZATION
```

三者指向同一 Header。实现必须保留最终写入名称，但比较和引用不区分大小写。

Provider/模型 Header 编辑器左值直接表示 Header 名称；quoted path 可处理空格、点和标点：

```text
X-Custom = "value"
["x field.with.dots"] = "value"
```

模型列表请求只应用服务商 Header。模型列表没有聊天 Body 和会话上下文，依赖不可用值的表达式按 `missing` 规则跳过；服务商 Body 不应用到模型列表请求。

## 7. Provider 接入

### 7.1 OpenAI、Responses、OpenRouter

Provider 先生成：

- URL 和方法
- 认证 Header
- Content-Type
- 协议默认 Body
- Codex OAuth 客户端身份

随后调用 `RequestCustomization`。用户 Header、Body 结果直接发送，不在定制后重新写回默认字段。

OpenAI 兼容 Provider 不再按第三方厂商、Base URL 或模型 ID 注入私有 thinking 格式；差异由模型 Request Controls 表达。

### 7.2 Gemini

API Key 和 OAuth 路径在协议默认 Body 完成后应用同一编排。Gemini OAuth 所需客户端 Header 先生成，随后仍允许用户显式覆盖。

### 7.3 Anthropic Android

OkHttp builder 完成认证、beta Header 和默认 Body 后应用请求配置。OAuth 固定 `claude-cli` 身份先写入；非 OAuth 路径使用 App 默认 UA。

### 7.4 Anthropic iOS

SwiftAnthropic 不直接暴露最终请求 Body，因此使用现有 `URLProtocol` 拦截层：

1. materialize `httpBodyStream`
2. 应用上游 Body patchers
3. 按请求 UUID 取得定制快照
4. 恢复本次 `sessionId` 和 `thinkingDefinitionId`
5. 应用 Provider Header、Body 和 Model Header、Body
6. 重新编码并发送

并发请求通过 `AnthropicHTTPClientPool` 的 lease ID 隔离，不以全局“最后一次配置”匹配请求。

### 7.5 Antigravity

Antigravity 走 Google Cloud Code 上游（`v1internal:generateContent` / `:streamGenerateContent`），请求体是一层“信封”：外层携带 `model`、`project`、`userAgent`、`requestType`、`request` 等字段，真正的 Gemini 内容（`contents`、`systemInstruction`、`generationConfig`）嵌在内层 `request` 中。

**iOS（已接入）**：定制**只作用于信封内层**（Gemini 格式 body），外层信封字段用户不可见、不可改。`AntigravityProvider` 持有 `requestCustomization`，`buildRequest` 的流程为：

1. 构建内层 Gemini body 与默认 Header（`Authorization`、`User-Agent`、`X-Client-*`、`x-goog-api-client`、`Accept`）。
2. 在设完默认 Header 之后、包信封之前，对内层 body 与 Header 一起调用 `requestCustomization.apply(...)`，保持全局固定的六层应用顺序，并感知 `delete()`（Header patching 为 set-only，删除的 key 需显式清除）。
3. `wrapEnvelope(customizedInner)` 包上外层信封后序列化发送。

因为定制作用于内层，用户表达式按 Gemini body 的形状书写（如 `body.generationConfig.thinkingConfig`）。内置 thinking 注入受 `disablesBuiltInThinkingInjection` 门禁：存在自定义思考控制时跳过 `thinkingConfig` 的默认写入。默认思考模板与 Gemini 合并（`body.generationConfig.thinkingConfig = {thinkingLevel, includeThoughts}`）。工厂在 `makeAntigravityProvider` 中注入 `RequestCustomization`。

**Android（尚未实现）**：Android 端目前**没有** Antigravity provider——只有 OAuth 与 models API 两个脚手架，`ProviderType` 无 `antigravity`，`ProviderFactory` / `OAuthManager` 均无对应分支，请求链跑不通。这是上游未在 Android 落地的既有状态，不在本次请求定制需求范围内。待 Android 将来实现 Antigravity provider 时，按 iOS 的对称模式一并接入定制，落地清单：

1. 新建 `provider/antigravity/AntigravityProvider.kt`，以 `GeminiProvider.kt` 为模板构建内层 body 与 `buildThinkingConfig`，新增 `wrapEnvelope`，在设完默认 Header 后、包信封前对**内层 body + Header** 调 `requestCustomization.apply(...)`；持有 `requestCustomization` 构造参数并暴露 `thinkingDefinitionId` / `requestSessionId` / `usesConversationRequestControlState` / `requestCustomizationModelKey` 等 override 属性；thinking 注入加 `disablesBuiltInThinkingInjection` 门禁。
2. `data/model/ProviderConfig.kt`：`ProviderType` 增加 `antigravity`，补 `builtInModels` 穷尽 `when` 分支。
3. `auth/OAuthManager.kt`：`forInstance` 增加 `antigravity -> AntigravityOAuthManager(...)`。
4. `provider/ProviderFactory.kt`：`when` 增加 antigravity 分支，`discoverProjectIfNeeded` 后构造 provider 并传入 `requestCustomization`、`projectID`、`activeBaseURL`。

## 8. User-Agent 设计

专用 User-Agent 配置已删除。生产代码只保留两类默认：

- 普通 App 请求：`Minis/<version> (...)`
- 协议指定客户端身份：`codex_cli_rs/...`、`claude-cli/...`、Gemini CLI 或 Antigravity 对应身份

用户自定义 UA 走普通 Header 表达式：

```text
User-Agent = "custom-client/1.0"
```

默认 UA 在用户 Header 之前写入，所以用户值最终生效。静态守卫禁止 Provider 生产代码重新出现专用 `customUserAgent` API。

## 9. UI 实现

双端页面只保存编辑草稿；输入组件负责：

- 多行编辑
- 中文输入法兼容
- 保留一个尾部编辑行
- 失焦时清理多余空行
- 行号校验错误
- 帮助弹窗
- 未保存修改确认

Android 的 Provider 与模型详情页均只显示摘要入口，请求配置在独立页面编辑。共享 Header/Body 输入组件放在 `MinixRequestExpressionEditor.kt`，避免两个独立页面复制表达式编辑和校验逻辑。

iOS 的 Provider 请求配置、模型请求配置和思考档位管理属于事务型页面：顶栏使用“取消/保存”，隐藏系统返回键并禁用右滑返回。取消时若存在修改，进入统一的保存、放弃或继续编辑确认流程。

## 10. 分享与导入

服务商导出包含：

- Provider Header、Body
- 该服务商下模型的 Header、Body
- 该模型的 Request Controls
- Request Controls 引用的思考档位定义

导入不执行表达式，只校验结构并保存文本。首次真实请求时按当前上下文求值。

## 11. 测试

必须覆盖：

- Provider/Model 持久化 round trip
- 单一 `request_customization_json` envelope
- 旧专用 UA 字段不存在
- 固定六层应用顺序
- 同层后一行读取前一行
- Header 大小写不敏感
- Header delete() 清除请求上的预置默认值
- 单行运行时错误和求值超限不影响后续行
- OAuth 默认字段可被用户配置覆盖且不被恢复
- Anthropic 请求 UUID 并发隔离
- 分享导入不丢失表达式

## 12. 上游合并参考

必须保留 Minix 侧：

- `MinixRequestExpression.*`
- `MinixRequestControls.swift`
- `MinixRequestCustomization.kt`
- `MinixRequestCustomizationViews.swift`
- `MinixRequestExpressionEditor.kt`
- `request_customization_json`
- 固定请求应用顺序
- Codex/Claude 定制后不恢复字段
- 专用 `customUserAgent` API 已删除

可以接受上游：

- Provider endpoint、认证流程、响应解析和工具格式更新
- 新协议默认 Header、Body
- 模型目录和能力更新

合并后必须确认上游新增默认字段发生在 Minix 定制之前，并运行：

```text
scripts/minix-check-invariants.sh
```
