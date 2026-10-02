# 表达式能力需求

## 1. 文档信息

- 正式名称：表达式能力
- 英文名称：Expression Capability
- 状态：已实现，待评审
- 平台：iOS、Android
- 使用位置：
  - 服务商 Header
  - 服务商 Body
  - 模型 Header
  - 模型 Body
  - 模型 Request Controls
- 关联需求：
  - [对应技术设计](exp-lang-tech.md)
  - [服务商与模型请求头、请求体自定义需求](request-customization-prd.md)
  - [自定义请求控制需求](request-controls-prd.md)

## 2. 命名与定位

该能力不是 CEL，也不是 JavaScript 子集。它是 Minix 自有的受限表达式能力，由 App 内置解析与求值实现，不执行任意外部代码。

面向用户统一称“表达式能力”，具体配置项称“请求表达式”；内部实现方式不作为用户需要理解的产品名称。

## 3. 背景

简单字符串模板无法满足以下场景：

- 读取最后一条用户消息。
- 按消息 role、content type 筛选嵌套数组。
- 根据文本长度动态计算 token 上限。
- 构造嵌套 JSON Header。
- 根据请求已有字段决定是否覆盖。
- 对 tools 数组增删改。
- 计算哈希、URL 编码和稳定 JSON。
- 在 Request Controls 中同时修改 Header 和 Body。

引入通用函数式原语可以避免为每个业务场景增加 `find_last_user_message` 等专用函数。

## 4. 目标

1. 支持结构化 JSON 值、路径、模板和复杂运算。
2. 支持任意中间结果继续读取字段和索引。
3. 支持 `filter`、`map`、`reduce` 等通用集合操作。
4. 明确区分 `missing`、`null` 和删除。
5. 支持安全、确定、有限的求值，不执行任意代码。
6. iOS、Android 对同一表达式产生相同结果。
7. 错误可在保存前定位到具体行。

## 5. 非目标

- 不实现 JavaScript、CEL、Lua 或其他通用脚本运行时。
- 不支持文件、网络、进程、反射或动态模块。
- 不支持用户自定义函数。
- 不保证浮点运算适用于金融精度。
- 不兼容开发期已废弃的对象 `{key = value}` 语法。
- 不增加模型或服务商专用函数。

## 6. 表达式行

每行一个赋值：

```text
path = expression
```

示例：

```text
temperature = 0.7
metadata = {session_id: session.id}
body.max_tokens = clamp(length(body.input) * 2, 512, 8192)
```

规则：

- 只使用第一个顶层赋值号分隔左右值。
- 字符串内部的 `=` 保留为字符串内容。
- 右值不支持赋值表达式。
- 对象字段使用冒号：`{key: value}`。
- 对象内使用 `=` 必须报错。

## 7. 值类型

语言支持：

- `missing`
- `null`
- 删除标记
- 布尔
- 整数
- 浮点数
- 字符串
- 数组
- 对象

用户可直接书写：

```text
true
false
null
123
0.75
"text"
[1, "two", {three: 3}]
{mode: "strict", nested: {enabled: true}}
```

`missing` 和删除标记不是普通 JSON 字面量：

- `missing` 由不存在的字段、空结果索引或越界产生。
- 删除标记由 `delete()` 产生。

## 8. 上下文变量

```text
provider.id
provider.label
provider.type
provider.credentialType
provider.apiKey
provider.baseURL

model.id
model.displayName
model.provider

session.id

headers.<name>
body.<path>
```

Header 名称和 Header 引用不区分大小写。

某个上下文在当前请求阶段不可用时返回 `missing`，不伪造空字符串。

## 9. 路径

### 9.1 点路径

```text
body.reasoning.summary
provider.credentialType
```

### 9.2 quoted/bracket path

字段名包含空格、点、连字符或标点时使用：

```text
headers["x custom.header"]
body.metadata["session-id"]
```

### 9.3 数组索引

```text
body.messages[0]
body.messages[-1]
```

- 正索引从 0 开始。
- 负索引从末尾读取。
- `-1` 表示最后一个元素。
- 越界返回 `missing`。

### 9.4 链式读取

任意表达式结果都可继续读取：

```text
body.messages
  .filter(message, message.role == "user")[-1]
  .content
```

## 10. 字符串模板

带引号字符串中可使用：

```text
"Bearer {{ provider.apiKey }}"
"session-{{ session.id }}"
```

整条右值也可直接使用模板：

```text
metadata.session_id = {{ session.id }}
```

模板规则：

- 模板内使用完整表达式。
- 任一嵌入表达式为 `missing` 时跳过整个赋值。
- 模板不支持嵌套模板。
- 对象和数组插入字符串时使用稳定字符串转换规则。

## 11. 运算符

从高到低：

1. 后缀 `.field`、`[index]`
2. 一元 `!`、`+`、`-`
3. `*`、`/`、`%`
4. `+`、`-`
5. `>`、`>=`、`<`、`<=`
6. `==`、`!=`
7. `&&`
8. `||`
9. `??`
10. `condition ? yes : no`

括号可显式改变优先级：

```text
body.c > 30 && (body.a > 10 || body.b <= 20)
```

短路：

- `&&`
- `||`
- `??`
- 三元条件
- `if(...)`

未选中的分支不得求值。

`+` 的类型语义：

- 数字加法
- 字符串与字符串拼接
- 数组与数组连接
- 不在不同类型之间做隐式转换

## 12. `missing`、`null` 和删除

### 12.1 missing

产生场景：

- 字段不存在
- `filter` 结果为空后取索引
- 数组索引越界
- 当前阶段没有会话或 Body

最终结果为 `missing` 时跳过当前赋值。

### 12.2 null

`null` 是真实 JSON null：

```text
metadata.value = null
```

不得把 `null` 解释为删除。

### 12.3 delete()

```text
obsolete = delete()
headers.X-Legacy = delete()
```

`delete()` 明确删除字段。不得作为数组元素。
`Authorization` 和 `Content-Type` 由传输层管理，约定不覆盖或删除。

### 12.4 回退和存在判断

```text
value ?? fallback
exists(value)
```

- `??` 在左值为 `missing` 或 `null` 时回退。
- `exists(missing)` 为 false。
- `exists(null)` 为 true。

## 13. 集合方法

### 13.1 filter

```text
array.filter(item, predicate)
```

保留 predicate 为 true 的元素。

### 13.2 map

```text
array.map(item, expression)
```

按顺序转换每个元素。

### 13.3 reduce

```text
array.reduce(acc, item, initial, expression)
```

从 `initial` 开始左折叠。

局部变量只在对应集合表达式内部可见。

## 14. 数组函数

```text
append(array, value...)
concat(array...)
remove(array, match...)
update(array, objectMatch, objectPatch)
insert(array, index, value)
remove_at(array, index)
```

语义：

- `append`：每个 value 作为一个完整元素；数组 value 保持嵌套。
- `concat`：参数必须是数组，每个参数展开一层。
- `remove`：匹配任一 match 即删除；多个 match 是 OR。
- 对象 match：match 内字段必须全部匹配，是字段子集 AND。
- `update`：递归 patch 所有匹配对象；patch 中 `delete()` 删除字段。
- `insert`：插入一个完整值；负索引从末尾位置计算，`-1` 表示追加。
- `remove_at`：删除一个索引；`-1` 删除最后一个；越界保持原数组。

## 15. 数值与长度函数

```text
min(numberOrArray, ...)
max(numberOrArray, ...)
sum(numberOrArray, ...)
avg(numberOrArray, ...)
clamp(value, lower, upper)
length(value)
count(value)
```

- 聚合函数接受数字和数字数组，数组展开一层。
- `length/count` 对字符串返回 Unicode 码点数。
- 对数组返回元素数。
- 对对象返回 key 数。
- 不接受隐式字符串转数字。

## 16. 文本、编码、哈希和 JSON

```text
upper(string)
lower(string)
string(value)
json(value)
url_encode(string)
url_decode(string)
md5(string)
sha256(string)
deep_merge(object, object...)
```

规则：

- `string` 将对象和数组转换为 JSON 文本。
- `json` 输出对象 key 稳定排序的 JSON 字符串。
- `url_encode` 按 URL component 编码 UTF-8，空格为 `%20`。
- `url_decode` 解码 `%HH`，`+` 保持 `+`。
- 哈希输出小写十六进制。
- `deep_merge` 递归合并对象；后值覆盖标量和数组；`delete()` 删除字段。

## 17. 动态函数

```text
if(condition, yes, no)
exists(value)
now(unit?)
format_time(timestamp, format, unit?, timezone?)
parse_time(text, format, unit?, timezone?)
uuid()
delete()
```

- `if` 只计算选中分支。
- `now` 返回 Unix 时间戳，默认单位为秒，可指定 `milliseconds`。
- `format_time` 和 `parse_time` 默认使用设备当前时区，也可指定 IANA 时区。
- 时间格式支持 `YYYY/YY`、`MM/M`、`DD/D`、`HH/H`、`hh/h`、`mm/m`、`ss/s`、`S/SS/SSS`、`a`，其他字符按字面量处理。
- `format_time` 只返回格式中指定的内容；`parse_time` 必须包含完整年月日，12 小时制必须包含 `a`。
- `uuid` 每次调用返回新 UUID。
- 同一表达式多次调用 `now/uuid` 可产生不同值。

## 18. 比较与相等

- `==/!=` 支持标量、数组和对象递归比较。
- `>/<` 系列只接受数字或字符串。
- 不在数字和字符串之间隐式转换。
- 对不支持的类型组合报类型错误。

## 19. Request Controls 目标

Request Controls 必须显式写根：

```text
body.<path>
body[...]
headers.<name>
headers[...]
```

其他根或无根左值必须报错。Header 目标只能表示一个 Header 名称，不支持多级 Header 对象。

## 20. 校验与错误

保存前校验至少区分：

- 缺少赋值号
- 右值为空
- 分隔符不平衡
- 左值路径无效
- 未知函数
- 函数参数无效
- 未知模板引用
- 类型不匹配
- 求值超限

保存前的静态校验只对不依赖运行时数据即可确定的问题负责，例如语法、左值、未知函数和参数数量。运行时类型错误、依赖实际集合大小的求值超限等问题在实际求值时处理。

错误必须包含行号。单行运行时产生 `missing` 不属于错误。单行运行时错误或求值超限只使该行失效，后续行继续，最终请求继续构建和发送。

## 21. 安全与资源限制

- 不执行字符串代码。
- 不访问系统 API、文件、网络或进程。
- 求值必须有步骤上限。
- 必须限制异常大的输入或过深的嵌套。
- 集合函数只遍历请求上下文已有数据。
- 哈希只处理内存字符串。
- 表达式错误不得导致 App 崩溃或发送半成品请求。
- 错误日志只记录目标、行号和错误类别，不输出 API Key、最终认证 Header、完整 Body 或表达式求值结果。

## 22. 验收标准

1. 双端支持相同值类型、运算符和优先级。
2. 对象只接受 `{key: value}`。
3. 任意中间结果可继续读字段和索引。
4. 正负索引、quoted path 和模板按定义工作。
5. `filter/map/reduce` 可处理嵌套请求数组。
6. `append` 与 `concat` 语义不同且有测试。
7. 数组增删改函数符合边界规则。
8. `missing`、`null`、`delete()` 明确区分。
9. 惰性运算不计算未选分支。
10. Header 大小写不敏感。
11. 稳定 JSON、URL 编解码和哈希双端一致。
12. 无效表达式显示行号并阻止保存。
13. 超限求值安全失败。
14. 不引入 JavaScript 或其他通用脚本引擎。
15. 单行运行时错误与资源超限不影响后续表达式和请求发送。
