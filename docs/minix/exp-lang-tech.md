# 表达式能力技术设计

## 1. 设计原则

表达式能力采用原生安全 AST：

```text
source
  -> Lexer
  -> Parser
  -> Assignment + Expression AST
  -> Evaluator
  -> typed Value
  -> Header/Body mutation
```

原则：

- 不使用 JavaScript 引擎或 `eval`。
- iOS、Android 独立原生实现，但共享语言规范和测试向量。
- 语言实现放在 Minix-owned 文件，避免侵入上游 Provider 热点文件。
- 结构化值始终通过 JSON API 转换，不拼接 JSON 文本。

关联设计：

- [对应需求文档](exp-lang-prd.md)
- [服务商与模型请求头、请求体自定义技术设计](request-customization-tech.md)
- [自定义请求控制技术设计](request-controls-tech.md)

## 2. 实现文件

- iOS：`src/ios/Providers/MinixRequestExpression.swift`
- Android：`src/android/app/src/main/java/com/openminis/app/provider/MinixRequestExpression.kt`

外部 facade：

- iOS：`RequestCustomizationExpression`，位于 `MinixRequestControls.swift`
- Android：`RequestExpressionValidator` 和 `RequestCustomization`，位于 `MinixRequestCustomization.kt`

UI 不直接调用 Parser 内部类型，只调用 Validator 和请求编排 facade。

## 3. 目标模式

```text
Target.header
Target.body
Target.control
```

### 3.1 Header

- 左值是相对 Header 名称。
- 结果必须是字符串或删除标记。
- Header 对象内部使用大小写不敏感 map。

### 3.2 Body

- 左值是相对 Body path。
- 结果转换为 JSON 值。
- 对象递归 merge，标量和数组 replace。

### 3.3 Control

- 左值必须以 `body` 或 `headers` 为根。
- 根据根分发到 Body 或 Header mutation。
- `headers` 后只能解析为一个最终 Header 名称。

## 4. 词法分析

Token 类型：

```text
identifier
number
string
symbol
end
```

Lexer 负责：

- 跳过空白
- 识别 quoted string 和 escape
- 区分整数、浮点数
- 识别多字符运算符
- 保留括号、方括号、花括号和逗号
- 限制 token 数

字符串内的 `=` 不参与顶层赋值切分。顶层赋值切分必须跟踪：

- 字符串状态
- escape 状态
- `()`
- `[]`
- `{}`
- 模板边界

## 5. Parser

Parser 为 Pratt 风格的递归下降实现。

核心 AST：

```text
Assignment(path, expression)

Expression
  Literal
  Template
  Identifier
  Array
  Object
  Unary
  Binary
  Conditional
  Call
  Member
  Index
  Method
```

简化语法：

```text
assignment  := path "=" expression
expression  := conditional
conditional := coalesce ["?" expression ":" expression]
coalesce    := logicalOr {"??" logicalOr}
logicalOr   := logicalAnd {"||" logicalAnd}
logicalAnd  := equality {"&&" equality}
equality    := comparison {("==" | "!=") comparison}
comparison  := additive {(">" | ">=" | "<" | "<=") additive}
additive    := multiply {("+" | "-") multiply}
multiply    := unary {("*" | "/" | "%") unary}
unary       := ("!" | "+" | "-") unary | postfix
postfix     := primary {member | index | methodCall}
primary     := literal | identifier | array | object | call | "(" expression ")"
```

对象字段仅接受：

```text
identifier ":" expression
quotedString ":" expression
```

对象中的 `=` 必须在 parse 阶段拒绝。

## 6. 值模型

内部值：

```text
Missing
Null
Delete
Bool
Integer
Decimal
Text
Array<Value>
Object<String, Value>
```

iOS：

```text
fileprivate indirect enum Value
```

Android：

```text
private sealed interface Value
```

`Missing`、`Null`、`Delete` 不可合并为同一 sentinel：

- `Missing` 控制整行跳过和惰性回退。
- `Null` 转换为 `NSNull`/`JSONObject.NULL`。
- `Delete` 只在 mutation/merge 阶段删除字段。

## 7. 环境

```text
Environment
  context
  locals
  steps
```

Context：

```text
provider
model
apiKey
sessionId
headers
body
```

Locals 用于 `filter/map/reduce` 的 lambda 参数，采用词法嵌套作用域。集合回调结束后不得泄漏变量。

## 8. 求值限制

每个表达式 Environment 维护 step counter：

```text
maxSteps = 100_000
```

每个 AST 节点、集合迭代和关键递归操作调用 `tick()`。超限时返回明确 evaluation limit 错误。

双端还执行相同的源码门禁：

```text
UTF-8 source <= 65,536 bytes
token count <= 1,024
nesting depth <= 128
```

双端应避免：

- 无限递归
- 极深对象 merge
- 无界集合展开
- 未选惰性分支求值

请求 JSON 自身大小仍是集合遍历的外部上界。

## 9. 路径求值

### 9.1 Member

```text
base.field
```

- Object：读取 field。
- case-insensitive Header Object：忽略大小写。
- 其他类型：类型错误或 Missing，按入口语义处理。

### 9.2 Index

```text
base[index]
```

- Array + Integer：正负索引。
- Object + Text：quoted key。
- 越界或 key 不存在：Missing。

负索引读取：

```text
resolved = count + index
```

### 9.3 Mutation Path

左值 path 在求值后写入：

- 中间对象不存在时创建对象。
- 中间值不是对象时按覆盖语义替换为对象。
- Delete 删除叶子 key。
- 对象值递归 merge 到叶子。

## 10. 模板

模板字符串在 Lexer/Parser 中保留为独立 AST，而不是先做文本替换。

Parser 同时接受：

- quoted string 内嵌模板
- RHS 完全由一个 `{{ expression }}` 组成的 whole-value 模板

求值：

1. 扫描 `{{ ... }}`。
2. 对每个片段递归 parse expression。
3. 使用当前 Environment 求值。
4. 任一结果 Missing，整个模板 Missing。
5. 其他结果转换为字符串并拼接。

需要拒绝：

- 未闭合模板
- 多余 `}}`
- 嵌套 `{{`
- 空模板表达式

## 11. 运算

### 11.1 数值

- Integer 与 Integer 尽量保留 Integer。
- 出现 Decimal 时提升为 Decimal。
- 除法和无法保持整数的运算返回 Decimal。
- 除零、非法取模和溢出必须安全报错。

### 11.2 字符串

`+` 支持：

- 数字加法
- Text + Text
- Array + Array

不得在不同类型之间隐式转换，也不得对 Object 使用 `+`。

### 11.3 布尔和条件

以下 AST 节点惰性：

- logical AND
- logical OR
- coalesce
- conditional
- `if`

Evaluator 先求条件，再只求选中分支。

### 11.4 相等

递归比较：

- Null
- Bool
- 数值
- Text
- Array
- Object

Missing 只参与语言内部传播，不作为普通 JSON 值输出。

## 12. 集合方法

### 12.1 filter

```text
array.filter(item, predicate)
```

每次迭代：

1. 设置 local `item`。
2. 求 predicate。
3. 仅 true 保留。

### 12.2 map

```text
array.map(item, expression)
```

按输入顺序生成结果。单项 Missing 的处理必须双端一致，不得一端丢弃、一端写 Null。

### 12.3 reduce

```text
array.reduce(acc, item, initial, expression)
```

先求 initial，再逐项更新 acc。acc 和 item 只在 reduce body 中可见。

方法调用仍是 AST，不允许把用户变量名编译成宿主语言闭包或代码。

## 13. 数组函数

### 13.1 append 与 concat

```text
append([1], [2, 3]) -> [1, [2, 3]]
concat([1], [2, 3]) -> [1, 2, 3]
```

这是必须保持的语义差异。

### 13.2 remove

匹配：

- 标量递归 equality
- 对象 match 为字段子集
- 多个 match 为 OR

### 13.3 update

对所有匹配对象应用递归 patch。patch 内 Delete 删除 key。

### 13.4 insert/remove_at

边界算法必须共享测试：

- 正索引
- 负索引
- 空数组
- 越界
- `-1`

## 14. JSON 与合并

宿主 JSON 转 Value：

- iOS：`JSONSerialization` 结果递归转换。
- Android：`JSONObject`、`JSONArray` 递归转换。

Value 转宿主 JSON：

- Null -> `NSNull` / `JSONObject.NULL`
- Delete 不可直接序列化
- Missing 不可直接序列化
- Object 保持 key/value 结构
- Array 保持顺序

稳定 `json(value)`：

- Object key 按字典序排序。
- Array 保持顺序。
- 使用标准 JSON escaping。

## 15. Header 大小写

Header Context 使用 case-insensitive object。写入时：

1. 查找已有同名 key，比较忽略大小写。
2. 存在时替换对应 entry。
3. 不存在时添加新 entry。
4. Delete 删除所有大小写等价 entry。

不得仅在读取时忽略大小写而在写入时产生重复 Header。

## 16. 函数分发

函数采用白名单 switch/dispatch：

```text
append, concat, remove, update, insert, remove_at
min, max, sum, avg, count, length, clamp
if, exists, now, format_time, parse_time, uuid
upper, lower, string, json
url_encode, url_decode
md5, sha256, deep_merge, delete
```

未知函数在 parse/validation 阶段报错。函数必须显式校验：

- 参数数量
- 参数类型
- Delete/Missing 是否允许
- 返回类型

哈希使用系统原生实现：

- iOS：CryptoKit
- Android：MessageDigest

## 17. Validation

Validator 对每行独立返回：

```text
line
error kind/message
```

校验需要 parse 完整 RHS，而不是只检查括号或函数名字符串。Request Controls 额外校验 LHS 根。静态 Validator 只报告不依赖上下文实际值即可确定的问题；运行时类型检查和 step limit 由 Evaluator 负责。

保存门禁使用 Validator 结果；运行时仍逐行捕获错误，防止导入数据或外部配置绕过 UI。失败行不写入 Header/Body，后续行继续执行，请求继续构建发送。

## 18. 错误映射

iOS `ExpressionError`：

```text
missingAssignment
invalidTarget
invalidExpression
unknownIdentifier
unknownFunction
invalidArguments
typeMismatch
evaluationLimit
```

Android 使用内部 `ExpressionException` 映射为 `RequestExpressionValidator.ErrorKind`；源码、token、嵌套深度和 step 超限统一映射为独立 `EVALUATION_LIMIT`，不混入普通函数参数错误。

用户文案应按错误类别稳定，不直接展示内部堆栈。运行日志仅记录目标、行号和错误类别，不记录 API Key、最终 Header、完整 Body 或求值结果。

## 19. 双端一致性

新增语法或函数时必须同时完成：

1. iOS Lexer/Parser
2. Android Lexer/Parser
3. iOS Evaluator
4. Android Evaluator
5. 双端帮助文案
6. 双端单元测试
7. 静态守卫需要时更新

不得一端先发布语言能力而另一端仅保存文本，因为分享配置会产生不可执行表达式。

## 20. 测试矩阵

解析：

- 字符串 escape 和字符串内 `=`
- 对象、数组、quoted key
- 括号和运算优先级
- 连续 member/index/method
- 无效对象 `=`

值：

- Missing、Null、Delete
- Int/Decimal 提升
- Unicode 字符长度
- 对象和数组递归 equality

集合：

- filter/map/reduce
- 空数组
- 嵌套 local
- append/concat
- remove/update
- insert/remove_at 正负索引

惰性：

- `&&`、`||`
- `??`
- conditional
- `if`
- 未选分支包含错误或昂贵函数

实用函数：

- stable JSON
- URL encode/decode
- MD5/SHA256
- deep merge
- Unix 秒/毫秒时间戳
- 本地时区和指定 IANA 时区的时间格式化/解析
- 双端固定时间令牌映射：`YYYY/YY`、`MM/M`、`DD/D`、`HH/H`、`hh/h`、`mm/m`、`ss/s`、`S/SS/SSS`、`a`
- now/uuid

请求集成：

- Header 大小写
- Body merge
- 同层顺序
- Control 混合 Header/Body
- 最终 Missing 跳过
- evaluation limit
- 单行运行时错误后续行继续

## 21. 性能与安全

- Parser 不缓存包含动态上下文的结果。
- 可按表达式文本缓存 AST，但不得缓存求值值。
- 所有集合操作受 step limit。
- 不在错误日志中输出 API Key 或完整敏感表达式结果。
- `now/uuid` 是显式非确定函数；`format_time/parse_time` 在未指定时区时依赖设备当前时区；其他函数应保持确定性。
- 不允许宿主类型逃逸到表达式 Value。

## 22. 上游合并参考

必须保留：

- 双端 `MinixRequestExpression.*`
- `missing/null/delete` 三分语义
- 对象 colon-only 语法
- 惰性求值
- Request Controls `body.`/`headers.` 左值门禁
- 100,000 step 上限
- 无 JavaScript 运行时

Provider 上游变更通常不应修改表达式引擎。只有 Context 新增字段、请求 JSON 类型变化或新的用户函数需求才需要改动 Minix 文件。

合并后运行：

```text
scripts/minix-check-invariants.sh
```

并执行双端表达式完整单元测试，不只运行新增用例。
