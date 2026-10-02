# Expression Capability

Use one assignment per line:

```text
key = expression
```

Provider and model Header/Body editors omit the root on the left. Request Controls require `body.<path>` or `headers.<name>`.

## Values and paths

- Strings must be quoted. Numbers, `true`, `false`, and `null` keep their JSON types.
- Objects use `{key: value}`. Arrays use `[value1, value2]`.
- Use `.field`, `["quoted name"]`, and `[index]`. Negative indexes read from the end; `[-1]` is the last item.
- Any intermediate result can continue with another field or index.

```text
body.reasoning.summary
headers["X Custom Header"]
body.messages[-1].content
```

## Context

- **Provider:** `provider.id`, `provider.label`, `provider.type`, `provider.credentialType`, `provider.apiKey`, `provider.baseURL`
- **Model:** `model.id`, `model.displayName`, `model.provider`
- **Session:** `session.id`
- **Current request:** `headers.<name>`, `body.<path>`

Header names and references are case-insensitive.
Do not override or delete `Authorization` or `Content-Type`; the transport manages them.

## Templates

Use `{{ expression }}` inside a quoted string. If an embedded value is missing, the whole assignment is skipped.

```text
X-API-Key = "{{ provider.apiKey }}"
metadata.session_id = "{{ session.id }}"
```

## Missing, null, and deletion

- **`missing`** means no value exists. A final `missing` result skips that assignment.
- **`null`** writes a real JSON null.
- **`delete()`** removes the target Body field or Header.
- `value ?? fallback` evaluates the fallback only for `missing` or `null`.
- `exists(value)` is false only for `missing`.

```text
body.optional = body.source ?? "fallback"
body.explicit_null = null
body.legacy_field = delete()
headers.x-debug = delete()
```

## Operators

Highest to lowest: field/index access, unary `! + -`, `* / %`, `+ -`, comparisons, `== !=`, `&&`, `||`, `??`, and `condition ? yes : no`.

`&&`, `||`, `??`, the conditional operator, and `if(...)` evaluate lazily.

## Collection functions

Collection functions return new values and do not modify their inputs.

- **`array.filter(item, predicate) -> array`**: Keeps elements for which `predicate` is `true`. `item` is local to the predicate. `false` and `missing` omit an element; any other result is an error.
- **`array.map(item, expression) -> array`**: Calculates one replacement value for every element while preserving order. If any calculation returns `missing`, the whole assignment is skipped.
- **`array.reduce(acc, item, initial, expression) -> any`**: Folds the array from left to right. `acc` starts as `initial` and receives each result. An empty array returns `initial`; `acc` and `item` are local to the expression.
- **`append(array, value...) -> array`**: Appends each supplied value as one complete element. An array value stays nested.
- **`concat(array...) -> array`**: Joins one or more arrays, expanding each argument by one level. Every argument must be an array.
- **`remove(array, match...) -> array`**: Removes every element matching any supplied value or object pattern. Multiple matches use OR. An object pattern requires all of its fields to match recursively; an array match argument expands by one level.
- **`update(array, objectMatch, objectPatch) -> array`**: Recursively applies `objectPatch` to every object matching the field-subset pattern. Other elements stay unchanged. `delete()` inside the patch removes a field.
- **`insert(array, index, value) -> array`**: Inserts one complete value. `-1` appends; other negative indexes count from the end. Positions outside the array are clamped to the start or end.
- **`remove_at(array, index) -> array`**: Removes one element by index. `-1` removes the last element. An out-of-range index leaves the array unchanged.
- **`deep_merge(object, object...) -> object`**: Merges objects from left to right. Nested objects merge recursively; later scalars and arrays replace earlier values. `delete()` in a later object removes the field.

Examples:

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

## Numeric and length functions

Numeric aggregate arguments may be numbers or arrays of numbers; arrays expand by one level. They also support no-argument method syntax such as `body.scores.sum()`. All expanded values must be numeric.

- **`min(numberOrArray, ...) -> number`**: Returns the smallest value.
- **`max(numberOrArray, ...) -> number`**: Returns the largest value.
- **`sum(numberOrArray, ...) -> number`**: Returns the total. `min`, `max`, and `sum` preserve an integer result when all inputs are integers.
- **`avg(numberOrArray, ...) -> decimal`**: Returns the arithmetic mean as a decimal.
- **`clamp(value, lower, upper) -> number`**: Limits `value` to the inclusive range. All three values must be numeric, and `lower` cannot exceed `upper`.
- **`length(value) -> integer`**: Returns the Unicode code-point count of a string, the element count of an array, or the key count of an object.
- **`count(value) -> integer`**: An alias of `length`. Both functions support method syntax such as `body.tools.count()`.

Examples:

```text
body.lowest = min(body.scores, 0)
body.highest = body.scores.max()
body.total = sum(body.costs)
body.average = body.scores.avg()
body.max_tokens = clamp(length(body.messages.filter(message, message.role == "user")[-1].content), 512, 8192)
body.message_count = length(body.messages)
body.tool_count = body.tools.count()
```

## Text, encoding, JSON, and hash functions

- **`upper(string) -> string`**: Converts a string to uppercase.
- **`lower(string) -> string`**: Converts a string to lowercase. Both case-conversion functions reject non-string values.
- **`string(value) -> string`**: Produces plain text for scalars and JSON text for arrays or objects. An input string is returned without JSON quotes; `null` becomes an empty string.
- **`json(value) -> string`**: Produces valid JSON text with stable object-key ordering. Input strings include JSON quotes and escapes. Neither `string` nor `json` accepts `missing` or the `delete()` marker.
- **`url_encode(string) -> string`**: Percent-encodes a UTF-8 URL component. Spaces become `%20`; only letters, digits, and `-._~` remain unescaped.
- **`url_decode(string) -> string`**: Decodes UTF-8 percent sequences. `+` remains `+`; malformed percent encoding is an error.
- **`md5(string) -> string`**: Returns the MD5 digest of the UTF-8 bytes as lowercase hexadecimal text.
- **`sha256(string) -> string`**: Returns the SHA-256 digest of the UTF-8 bytes as lowercase hexadecimal text.

Examples:

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

## Dynamic and utility functions

- **`if(condition, yes, no) -> any`**: Returns `yes` when the Boolean condition is true, otherwise `no`. Only the selected branch is evaluated.
- **`exists(value) -> boolean`**: Returns `false` only for `missing`. An explicitly present `null` returns `true`, so this distinguishes an absent field from a null field.
- **`now(unit?) -> integer`**: Returns the current Unix timestamp. The default unit is seconds; `unit` may be `"seconds"` or `"milliseconds"`. Each call is evaluated independently.
- **`format_time(timestamp, format, unit?, timezone?) -> string`**: Formats a timestamp using exactly the content specified by `format`. The timestamp unit defaults to seconds. The time zone defaults to the device time zone and may be an IANA identifier such as `UTC` or `Asia/Shanghai`.
- **`parse_time(text, format, unit?, timezone?) -> integer`**: Parses text with the specified format and time zone and returns a timestamp. The result unit defaults to seconds. The format must include a complete year, month, and day; a 12-hour clock must include `a`.
- **`uuid() -> string`**: Returns a new UUID string. Each call creates a different value.
- **`delete() -> deletion marker`**: Returns an internal deletion marker, not a JSON value. Use it as the final assignment result or inside an object patch. It cannot be placed in an array or passed to `string` or `json`.

Examples:

```text
body.mode = if(body.fast == true, "fast", "normal")
body.has_tools = exists(body.tools)
headers["x-request-time-ms"] = now("milliseconds")
body.local_time = format_time(now(), "YY-M-D h:m:s a")
body.utc_time = format_time(now(), "YYYY-MM-DD HH:mm:ss", "seconds", "UTC")
body.created_at = parse_time("2026-08-04 09:30:00", "YYYY-MM-DD HH:mm:ss", "seconds", "Asia/Shanghai")
headers["x-request-id"] = uuid()
headers.x-legacy = delete()
body.settings = deep_merge(body.settings, {legacy: delete()})
```

## Merge order

Objects merge recursively; scalars and arrays replace. A later line can read a value written by an earlier line in the same layer.

The fixed layer order is: **Provider Header -> Provider Body -> Model Header -> Model Body -> Model Request Controls**.
