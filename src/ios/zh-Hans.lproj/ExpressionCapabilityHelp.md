# 表达式能力

每行写一个赋值：

```text
key = expression
```

服务商和模型的请求头/请求体编辑器在左侧省略根节点；请求控制的左值必须以 `body.<路径>` 或 `headers.<名称>` 开头。

## 值与路径

- 字符串必须加引号；数字、`true`、`false` 和 `null` 保持对应 JSON 类型。
- 对象写成 `{key: value}`，数组写成 `[value1, value2]`。
- 普通字段使用 `.field`，特殊字段名使用 `["quoted name"]`，数组使用 `[index]`。
- 负索引从末尾读取，`[-1]` 表示最后一个元素；任意中间结果都可以继续取字段或索引。

```text
body.reasoning.summary
headers["X Custom Header"]
body.messages[-1].content
```

## 上下文

- **服务商：** `provider.id`、`provider.label`、`provider.type`、`provider.credentialType`、`provider.apiKey`、`provider.baseURL`
- **模型：** `model.id`、`model.displayName`、`model.provider`
- **会话：** `session.id`
- **当前请求：** `headers.<名称>`、`body.<路径>`

请求头名称及引用不区分大小写。

## 模板

带引号字符串中可使用 `{{ expression }}`。任意内嵌值为 missing 时，会跳过整条赋值。

```text
Authorization = "Bearer {{ provider.apiKey }}"
metadata.session_id = "{{ session.id }}"
```

## missing、null 与删除

- **`missing`** 表示值不存在；最终结果为 missing 时跳过该条赋值。
- **`null`** 会写入真实的 JSON null。
- **`delete()`** 用于删除目标请求体字段或请求头。
- `value ?? fallback` 只在左值为 missing 或 null 时计算 fallback。
- `exists(value)` 仅在值为 missing 时返回 false。

```text
body.optional = body.source ?? "fallback"
body.explicit_null = null
body.legacy_field = delete()
headers.x-debug = delete()
```

## 运算符

优先级从高到低：字段/索引、一元 `! + -`、`* / %`、`+ -`、大小比较、`== !=`、`&&`、`||`、`??`、`condition ? yes : no`。

`&&`、`||`、`??`、条件运算符和 `if(...)` 都是惰性求值。

## 集合函数

集合函数都会返回新值，不会修改作为参数传入的原值。

- **`array.filter(item, predicate) -> array`**：保留 `predicate` 结果为 `true` 的元素。`item` 只在条件表达式内可用。结果为 `false` 或 `missing` 时不保留该元素；返回其他类型会报错。
- **`array.map(item, expression) -> array`**：按原顺序为每个元素计算一个替换值。任意一次计算得到 `missing` 时，整条赋值会被跳过。
- **`array.reduce(acc, item, initial, expression) -> any`**：从左向右归并数组。`acc` 从 `initial` 开始，并接收每次计算结果。空数组直接返回 `initial`；`acc` 和 `item` 只在表达式内可用。
- **`append(array, value...) -> array`**：把每个待追加值作为一个完整元素放到数组末尾。待追加值本身是数组时会保留为嵌套数组。
- **`concat(array...) -> array`**：连接一个或多个数组，每个参数展开一层。所有参数都必须是数组。
- **`remove(array, match...) -> array`**：删除匹配任一值或对象条件的所有元素。多个条件之间是“或”。对象条件要求其中全部字段都递归匹配；数组形式的匹配参数会展开一层。
- **`update(array, objectMatch, objectPatch) -> array`**：对所有符合字段子集条件的对象递归应用补丁，其他元素保持不变。补丁中的 `delete()` 会删除对应字段。
- **`insert(array, index, value) -> array`**：插入一个完整值。`-1` 表示追加；其他负索引从末尾计算。超出范围的位置会收敛到数组开头或末尾。
- **`remove_at(array, index) -> array`**：按索引删除一个元素。`-1` 删除最后一个元素；索引越界时返回未改变的数组。
- **`deep_merge(object, object...) -> object`**：按从左到右的顺序合并对象。嵌套对象递归合并；后面的标量和数组覆盖前值；后续对象中的 `delete()` 删除对应字段。

示例：

```text
body.enabled_tools = body.tools.filter(tool, tool.enabled == true)
body.tool_names = body.tools.map(tool, tool.name)
body.total = body.items.reduce(total, item, 0, total + item.price)
body.appended = append([1], [2, 3])
body.concatenated = concat([1], [2, 3])
body.tools = remove(body.tools, {type: "web_search"}, {disabled: true})
body.items = update(body.items, {id: "old"}, {enabled: true, legacy: delete()})
body.messages = insert(body.messages, 0, {role: "system", content: "Follow policy"})
body.messages = remove_at(body.messages, -1)
body.settings = deep_merge(body.settings ?? {}, {mode: "fast", debug: delete(), nested: {legacy: delete()}})
```

## 数值与长度函数

数值聚合参数可以是数字或数字数组，数组会展开一层；也支持 `body.scores.sum()` 这样的无参数方法写法。展开后的所有值都必须是数字。

- **`min(numberOrArray, ...) -> number`**：返回最小值。
- **`max(numberOrArray, ...) -> number`**：返回最大值。
- **`sum(numberOrArray, ...) -> number`**：返回所有数字之和。`min`、`max`、`sum` 在全部输入为整数时会保留整数结果。
- **`avg(numberOrArray, ...) -> decimal`**：返回所有数字的算术平均值，结果为小数。
- **`clamp(value, lower, upper) -> number`**：把 `value` 限制在包含边界的范围内。三个值都必须是数字，且 `lower` 不能大于 `upper`。
- **`length(value) -> integer`**：字符串返回 Unicode 码点数，数组返回元素数，对象返回键数。
- **`count(value) -> integer`**：`length` 的别名。两者都支持 `body.tools.count()` 这样的无参数方法写法。

示例：

```text
body.lowest = min(body.scores, 0)
body.highest = body.scores.max()
body.total = sum(body.costs)
body.average = body.scores.avg()
body.max_tokens = clamp(length(body.messages.filter(message, message.role == "user")[-1].content), 512, 8192)
body.message_count = length(body.messages)
body.tool_count = body.tools.count()
```

## 文本、编码、JSON 与哈希函数

- **`upper(string) -> string`**：把字符串转换为大写。
- **`lower(string) -> string`**：把字符串转换为小写。两个大小写转换函数都不接受非字符串值。
- **`string(value) -> string`**：标量转换为普通文本，数组和对象转换为 JSON 文本。输入字符串不会额外带上 JSON 引号；`null` 返回空字符串。
- **`json(value) -> string`**：生成有效 JSON 文本，对象键会稳定排序。输入字符串会包含 JSON 引号和转义。`string` 和 `json` 都不接受 `missing` 或 `delete()` 标记。
- **`url_encode(string) -> string`**：按 URL component 规则对 UTF-8 字符串进行百分号编码。空格编码为 `%20`，只有字母、数字和 `-._~` 不转义。
- **`url_decode(string) -> string`**：解码 UTF-8 百分号序列。`+` 保持为 `+`；非法百分号编码会报错。
- **`md5(string) -> string`**：按字符串的 UTF-8 字节计算 MD5，返回小写十六进制摘要。
- **`sha256(string) -> string`**：按字符串的 UTF-8 字节计算 SHA-256，返回小写十六进制摘要。

示例：

```text
headers["x-mode"] = upper(body.mode)
body.model_alias = lower(model.id)
headers["x-label"] = string(body.label)
headers["x-context"] = json({model: model.id, session: session.id})
body.encoded_query = url_encode(body.user_query)
body.query = url_decode(body.encoded_query)
headers["x-cache-key"] = md5(body.prompt)
headers["x-content-hash"] = sha256(json(body.messages))
headers.extra = json({session_id: session.id ?? body.prompt_cache_key ?? md5(body.input.filter(message, message.role == "user")[0].content.filter(part, part.type == "input_text")[0].text)})
```

## 动态与工具函数

- **`if(condition, yes, no) -> any`**：布尔条件为真时返回 `yes`，否则返回 `no`。只计算被选中的分支。
- **`exists(value) -> boolean`**：仅当结果为 `missing` 时返回 `false`。明确存在的 `null` 返回 `true`，因此可以用它区分“字段不存在”和“字段为空”。
- **`now(unit?) -> integer`**：返回当前 Unix 时间戳。默认单位为秒；`unit` 可设为 `"seconds"` 或 `"milliseconds"`。每次调用都会独立求值。
- **`format_time(timestamp, format, unit?, timezone?) -> string`**：按 `format` 指定的内容把时间戳格式化为字符串。时间戳单位默认为秒；时区默认为设备当前时区，也可使用 `UTC`、`Asia/Shanghai` 等 IANA 时区标识。
- **`parse_time(text, format, unit?, timezone?) -> integer`**：按指定格式和时区解析字符串并返回时间戳。返回单位默认为秒。格式必须包含完整的年、月、日；使用 12 小时制时必须包含 `a`。
- **`uuid() -> string`**：返回新生成的 UUID 字符串，每次调用都会产生不同的值。
- **`delete() -> 删除标记`**：返回仅供表达式内部使用的删除标记，不是 JSON 值。可作为赋值的最终结果或对象补丁中的值；不能放入数组，也不能传给 `string` 或 `json`。

示例：

```text
body.mode = if(body.fast == true, "fast", "normal")
body.has_tools = exists(body.tools)
headers["x-request-time-ms"] = now("milliseconds")
body.local_time = format_time(now(), "YY-M-D h:m:s a")
body.utc_time = format_time(now(), "YYYY-MM-DD HH:mm:ss", "seconds", "UTC")
body.created_at = parse_time("2026-08-04 09:30:00", "YYYY-MM-DD HH:mm:ss", "seconds", "Asia/Shanghai")
headers["x-request-id"] = uuid()
headers.authorization = delete()
body.settings = deep_merge(body.settings, {legacy: delete()})
```

## 合并顺序

对象递归合并；标量和数组覆盖。后一行可以读取同层前一行刚写入的值。

固定层级顺序为：**服务商 Header -> 服务商 Body -> 模型 Header -> 模型 Body -> 模型请求控制**。
