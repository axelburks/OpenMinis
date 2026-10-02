import Foundation
import SwiftAnthropic
import XCTest

@testable import Minis

final class RequestCustomizationExpressionTests: XCTestCase {

    func testParseBodyExpressions_supportsScalarObjectArrayAndQuotedPaths_BitsUT() throws {
        let result = try RequestCustomizationExpression.parseBodyExpressions(
            [
                "enabled = true",
                "count = 3",
                "ratio = 0.75",
                #"metadata["x custom"]["field.with.dots"] = "value""#,
                #"config = {mode: "strict", nested: {flag: false}}"#,
                #"items = [1, "two", {three: 3}]"#,
            ],
            context: makeContext()
        )

        XCTAssertEqual(result["enabled"] as? Bool, true)
        XCTAssertEqual(result["count"] as? Int, 3)
        XCTAssertEqual(result["ratio"] as? Double, 0.75)
        let metadata = try XCTUnwrap(result["metadata"] as? [String: Any])
        let custom = try XCTUnwrap(metadata["x custom"] as? [String: Any])
        XCTAssertEqual(custom["field.with.dots"] as? String, "value")
        let config = try XCTUnwrap(result["config"] as? [String: Any])
        XCTAssertEqual(config["mode"] as? String, "strict")
        XCTAssertEqual((config["nested"] as? [String: Any])?["flag"] as? Bool, false)
        let items = try XCTUnwrap(result["items"] as? [Any])
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0] as? Int, 1)
        XCTAssertEqual(items[1] as? String, "two")
        XCTAssertEqual((items[2] as? [String: Any])?["three"] as? Int, 3)
    }

    func testEvaluateTemplate_resolvesAllSupportedContextRootsAndFunctions_BitsUT() throws {
        let context = makeContext(
            apiKey: "secret-key",
            sessionId: "session-123",
            headers: ["X Custom Header": "header-value"],
            body: [
                "reasoning config": ["summary": "brief"],
                "items": [["name": "first"]],
            ]
        )

        XCTAssertEqual(
            try RequestCustomizationExpression.evaluateTemplate("{{ provider.apiKey }}", context: context) as? String,
            "secret-key"
        )
        XCTAssertEqual(
            try RequestCustomizationExpression.evaluateTemplate("{{ session.id }}", context: context) as? String,
            "session-123"
        )
        XCTAssertEqual(
            try RequestCustomizationExpression.evaluateTemplate(
                #"{{ headers["X Custom Header"] }}"#,
                context: context
            ) as? String,
            "header-value"
        )
        XCTAssertEqual(
            try RequestCustomizationExpression.evaluateTemplate(
                #"{{ body["reasoning config"].summary }}"#,
                context: context
            ) as? String,
            "brief"
        )
        XCTAssertEqual(
            try RequestCustomizationExpression.evaluateTemplate("{{ body.items[0].name }}", context: context) as? String,
            "first"
        )
        XCTAssertEqual(
            try RequestCustomizationExpression.evaluateTemplate("{{ upper(model.id) }}", context: context) as? String,
            "TEST-MODEL"
        )
        XCTAssertEqual(
            try RequestCustomizationExpression.evaluateTemplate("{{ lower(provider.label) }}", context: context) as? String,
            "test provider"
        )
    }

    func testParseExpressions_missingAnyTemplateValueSkipsOnlyThatExpression_BitsUT() throws {
        let context = makeContext(apiKey: nil, sessionId: nil, customBaseURL: nil)

        var headers: [String: String] = [:]
        try RequestCustomizationExpression.applyHeaderExpressions(
            [
                #"X-Trace = "provider={{ provider.id }};session={{ session.id }}""#,
                "X-API-Key = {{ provider.apiKey }}",
                "X-Base = {{ provider.baseURL }}",
                "X-Valid = {{ provider.id }}",
            ],
            to: &headers,
            context: context
        )
        let body = try RequestCustomizationExpression.parseBodyExpressions(
            [
                #"metadata.trace = "provider={{ provider.id }};session={{ session.id }}""#,
                #"metadata.valid = "{{ provider.id }}""#,
            ],
            context: context
        )

        XCTAssertNil(headers["X-Trace"])
        XCTAssertNil(headers["X-API-Key"])
        XCTAssertNil(headers["X-Base"])
        XCTAssertEqual(headers["X-Valid"], "provider-test")
        let metadata = try XCTUnwrap(body["metadata"] as? [String: Any])
        XCTAssertNil(metadata["trace"])
        XCTAssertEqual(metadata["valid"] as? String, "provider-test")
    }

    func testParseBodyExpressions_acceptsBareWholeValueTemplate_BitsUT() throws {
        let result = try RequestCustomizationExpression
            .parseBodyExpressions(
                [
                    "metadata.session_id = {{ session.id }}",
                    #"thinking = {type: "enabled"}"#,
                ],
                context: makeContext(
                    sessionId: "session-123"
                )
            )

        let metadata = try XCTUnwrap(
            result["metadata"] as? [String: Any]
        )
        XCTAssertEqual(
            metadata["session_id"] as? String,
            "session-123"
        )
        XCTAssertEqual(
            (result["thinking"] as? [String: Any])?[
                "type"
            ] as? String,
            "enabled"
        )
    }

    func testParseBodyExpressions_quotedWholeTemplateForcesString_BitsUT() throws {
        let context = makeContext(body: ["count": 3])

        // Bare whole template keeps the native type.
        let bare = try RequestCustomizationExpression.parseBodyExpressions(
            ["value = {{ body.count }}"],
            context: context
        )
        XCTAssertEqual(bare["value"] as? Int, 3)
        XCTAssertNil(bare["value"] as? String)

        // Quoting the same whole template forces a string result.
        let quoted = try RequestCustomizationExpression.parseBodyExpressions(
            [#"value = "{{ body.count }}""#],
            context: context
        )
        XCTAssertEqual(quoted["value"] as? String, "3")
        XCTAssertNil(quoted["value"] as? Int)
    }

    func testParseHeaderExpressions_laterLinesReadEarlierHeaderValues_BitsUT() throws {
        var headers: [String: String] = [:]
        try RequestCustomizationExpression.applyHeaderExpressions(
            [
                #"X-First = "provider""#,
                #"X-Second = "{{ headers["x-first"] }}-model""#,
            ],
            to: &headers,
            context: makeContext()
        )

        XCTAssertEqual(headers["X-First"], "provider")
        XCTAssertEqual(headers["X-Second"], "provider-model")
    }

    func testParseBodyExpressions_laterLinesReadEarlierBodyValues_BitsUT() throws {
        let body = try RequestCustomizationExpression.parseBodyExpressions(
            [
                #"metadata.source = "provider""#,
                #"metadata.copy = "{{ body.metadata.source }}-model""#,
            ],
            context: makeContext()
        )

        let metadata = try XCTUnwrap(body["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["source"] as? String, "provider")
        XCTAssertEqual(metadata["copy"] as? String, "provider-model")
    }

    func testControlExpressions_writeHeadersBodyAndEvaluateConditions_BitsUT() throws {
        var body: [String: Any] = [
            "priority": 7,
            "max_tokens": 1_024,
        ]
        var headers = [
            "X-Remove": "old",
        ]
        let context = makeContext(
            headers: headers,
            body: body
        )

        try RequestCustomizationExpression
            .applyControlExpressions(
                [
                    #"headers["hha ok"] = "haha ha""#,
                    "headers.x-remove = delete()",
                    "body.max_tokens = if(body.priority >= 5, max(body.max_tokens, 4096), min(body.max_tokens, 2048))",
                    "body.is_large = body.max_tokens == 4096",
                ],
                to: &body,
                headers: &headers,
                context: context
            )

        XCTAssertEqual(headers["hha ok"], "haha ha")
        XCTAssertNil(headers["X-Remove"])
        XCTAssertEqual(body["max_tokens"] as? Int, 4_096)
        XCTAssertEqual(body["is_large"] as? Bool, true)
    }

    func testControlExpressions_buildStableJSONHeaderWithLazyFallbackAndFiltering_BitsUT() throws {
        var body: [String: Any] = [
            "input": [
                [
                    "role": "assistant",
                    "content": [
                        ["type": "output_text", "text": "ignored"],
                    ],
                ],
                [
                    "role": "user",
                    "content": [
                        ["type": "image", "url": "ignored"],
                        ["type": "input_text", "text": "hello"],
                    ],
                ],
            ],
        ]
        var headers: [String: String] = [:]

        try RequestCustomizationExpression.applyControlExpressions(
            [
                """
                headers.extra = json({session_id: session.id ?? body.prompt_cache_key ?? md5(body.input.filter(message, message.role == "user")[0].content.filter(part, part.type == "input_text")[0].text)})
                """,
            ],
            to: &body,
            headers: &headers,
            context: makeContext(
                sessionId: nil,
                body: body
            )
        )

        XCTAssertEqual(
            headers["extra"],
            #"{"session_id":"5d41402abc4b2a76b9719d911017c592"}"#
        )

        headers.removeAll()
        body["prompt_cache_key"] = "body-priority"
        try RequestCustomizationExpression.applyControlExpressions(
            [
                """
                headers.extra = json({session_id: session.id ?? body.prompt_cache_key ?? "fallback"})
                """,
            ],
            to: &body,
            headers: &headers,
            context: makeContext(
                sessionId: "session-priority",
                body: body
            )
        )
        XCTAssertEqual(
            headers["extra"],
            #"{"session_id":"session-priority"}"#
        )

        headers.removeAll()
        try RequestCustomizationExpression.applyControlExpressions(
            [
                """
                headers.extra = json({session_id: session.id ?? body.prompt_cache_key ?? "fallback"})
                """,
            ],
            to: &body,
            headers: &headers,
            context: makeContext(
                sessionId: nil,
                body: body
            )
        )
        XCTAssertEqual(
            headers["extra"],
            #"{"session_id":"body-priority"}"#
        )
    }

    func testBodyExpression_filtersLastUserMessageAndClampsComputedLength_BitsUT() throws {
        let longText = String(repeating: "a", count: 5_000)
        let result = try RequestCustomizationExpression
            .parseBodyExpressions(
                [
                    """
                    max_tokens = clamp(length(body.messages.filter(message, message.role == "user")[-1].content) * 2, 512, 8192)
                    """,
                ],
                context: makeContext(body: [
                    "messages": [
                        ["role": "user", "content": "short"],
                        ["role": "assistant", "content": "ignored"],
                        ["role": "user", "content": longText],
                        ["role": "assistant", "content": "last"],
                    ],
                ])
            )

        XCTAssertEqual(result["max_tokens"] as? Int, 8_192)

        let short = try RequestCustomizationExpression
            .parseBodyExpressions(
                [
                    """
                    max_tokens = clamp(length(body.messages.filter(message, message.role == "user")[-1].content) * 2, 512, 8192)
                    """,
                ],
                context: makeContext(body: [
                    "messages": [
                        ["role": "user", "content": "short"],
                    ],
                ])
            )
        XCTAssertEqual(short["max_tokens"] as? Int, 512)
    }

    func testBodyExpressions_supportBooleanArithmeticMapReduceAndAggregates_BitsUT() throws {
        let result = try RequestCustomizationExpression
            .parseBodyExpressions(
                [
                    """
                    selected = body.items.filter(item, item.enabled && item.value >= 2)
                    """,
                    """
                    doubled = body.items.filter(item, item.enabled).map(item, item.value * 2)
                    """,
                    """
                    total = body.items.map(item, item.value).sum()
                    """,
                    """
                    average = avg(body.items.map(item, item.value))
                    """,
                    """
                    reduced = body.items.reduce(acc, item, 0, acc + item.value)
                    """,
                    """
                    selected_count = body.items.filter(item, item.enabled).count()
                    """,
                    """
                    normalized = upper(lower(body.label))
                    """,
                ],
                context: makeContext(body: [
                    "items": [
                        ["enabled": true, "value": 1],
                        ["enabled": false, "value": 2],
                        ["enabled": true, "value": 3],
                    ],
                    "label": "MiNiX",
                ])
            )

        XCTAssertEqual(
            (result["selected"] as? [[String: Any]])?.count,
            1
        )
        XCTAssertEqual(result["doubled"] as? [Int], [2, 6])
        XCTAssertEqual(result["total"] as? Int, 6)
        XCTAssertEqual(result["average"] as? Double, 2)
        XCTAssertEqual(result["reduced"] as? Int, 6)
        XCTAssertEqual(result["selected_count"] as? Int, 2)
        XCTAssertEqual(result["normalized"] as? String, "MINIX")
    }

    func testBodyExpressions_supportParenthesizedPrecedenceAndURLCoding_BitsUT() throws {
        let result = try RequestCustomizationExpression
            .parseBodyExpressions(
                [
                    "matched = body.c > 30 && (body.a > 10 || body.b <= 20)",
                    #"encoded = url_encode("a b+c/中文?")"#,
                    #"decoded = url_decode("a%20b%2Bc%2F%E4%B8%AD%E6%96%87%3F")"#,
                    #"roundtrip = url_decode(url_encode("x y+z"))"#,
                ],
                context: makeContext(body: [
                    "a": 11,
                    "b": 99,
                    "c": 31,
                ])
            )

        XCTAssertEqual(result["matched"] as? Bool, true)
        XCTAssertEqual(
            result["encoded"] as? String,
            "a%20b%2Bc%2F%E4%B8%AD%E6%96%87%3F"
        )
        XCTAssertEqual(
            result["decoded"] as? String,
            "a b+c/中文?"
        )
        XCTAssertEqual(result["roundtrip"] as? String, "x y+z")
    }

    func testParseHeaderExpressions_parsesQuotedAndExplicitEmptyStrings_BitsUT() throws {
        var headers: [String: String] = [:]
        try RequestCustomizationExpression.applyHeaderExpressions(
            [
                #"X-Value = "value""#,
                #"X-Empty = """#,
                "X-Number = 42",
                "X-Bool = true",
            ],
            to: &headers,
            context: makeContext()
        )

        XCTAssertEqual(headers["X-Value"], "value")
        XCTAssertEqual(headers["X-Empty"], "")
        XCTAssertEqual(headers["X-Number"], "42")
        XCTAssertEqual(headers["X-Bool"], "true")
    }

    func testHeaderDeleteRemovesValueAndInvalidLineIsSkipped_BitsUT() throws {
        var headers = ["X-Remove": "old"]
        let context = makeContext(headers: headers)

        try RequestCustomizationExpression.applyHeaderExpressions(
            [
                "x-remove = delete()",
                "X-Null = null",
                #"X-After = "kept""#,
            ],
            to: &headers,
            context: context
        )

        XCTAssertNil(headers["X-Remove"])
        XCTAssertNil(headers["X-Null"])
        XCTAssertEqual(headers["X-After"], "kept")
    }

    func testParseBodyExpressions_preservesNullAndDeleteRemovesFields_BitsUT() throws {
        let base: [String: Any] = [
            "top": "remove",
            "config": [
                "keep": "yes",
                "remove": "no",
            ],
            "items": [1, 2, 3],
        ]
        let overlay = try RequestCustomizationExpression.parseBodyExpressions(
            [
                "top = delete()",
                "config.remove = delete()",
                "config.todo = null",
                "items = insert(remove_at(body.items, 1), 1, null)",
            ],
            context: makeContext(body: base)
        )
        let merged = RequestCustomizationExpression.merge(base, with: overlay)

        XCTAssertNil(merged["top"])
        let config = try XCTUnwrap(merged["config"] as? [String: Any])
        XCTAssertEqual(config["keep"] as? String, "yes")
        XCTAssertNil(config["remove"])
        XCTAssertTrue(config["todo"] is NSNull)
        let items = try XCTUnwrap(merged["items"] as? [Any])
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0] as? Int, 1)
        XCTAssertTrue(items[1] is NSNull)
        XCTAssertEqual(items[2] as? Int, 3)
    }

    func testDeleteInObjectPatchRemovesField_BitsUT() throws {
        let result = try RequestCustomizationExpression
            .parseBodyExpressions(
                [
                    #"updated = update(body.items, {id: 1}, {todo: delete(), nullable: null})"#,
                    #"merged = deep_merge(body.config, {todo: delete(), nullable: null})"#,
                ],
                context: makeContext(body: [
                    "items": [["id": 1, "todo": "old"]],
                    "config": ["todo": "old"],
                ])
            )

        let updated = try XCTUnwrap(
            result["updated"] as? [[String: Any]]
        )
        XCTAssertNil(updated[0]["todo"])
        XCTAssertTrue(updated[0]["nullable"] is NSNull)
        let merged = try XCTUnwrap(
            result["merged"] as? [String: Any]
        )
        XCTAssertNil(merged["todo"])
        XCTAssertTrue(merged["nullable"] is NSNull)
    }

    func testMerge_recursesObjectsAndReplacesScalarsAndArrays_BitsUT() throws {
        let base: [String: Any] = [
            "config": ["keep": 1, "shared": "base"],
            "scalar": "base",
            "array": [1, 2],
        ]
        let overlay: [String: Any] = [
            "config": ["added": 2, "shared": "overlay"],
            "scalar": 7,
            "array": [3],
        ]

        let merged = RequestCustomizationExpression.merge(base, with: overlay)

        let config = try XCTUnwrap(merged["config"] as? [String: Any])
        XCTAssertEqual(config["keep"] as? Int, 1)
        XCTAssertEqual(config["added"] as? Int, 2)
        XCTAssertEqual(config["shared"] as? String, "overlay")
        XCTAssertEqual(merged["scalar"] as? Int, 7)
        XCTAssertEqual(merged["array"] as? [Int], [3])
    }

    func testParseBodyExpressions_appendAndConcatExtendContextArrays_BitsUT() throws {
        let context = makeContext(
            body: [
                "tools": [
                    ["type": "function", "name": "existing"],
                ],
                "tags": ["a"],
            ]
        )

        let result = try RequestCustomizationExpression.parseBodyExpressions(
            [
                #"tools = append(body.tools, {type: "web_search"})"#,
                #"tags = concat(body.tags, ["b", "c"])"#,
            ],
            context: context
        )

        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 2)
        XCTAssertEqual(tools[0]["name"] as? String, "existing")
        XCTAssertEqual(tools[1]["type"] as? String, "web_search")
        XCTAssertEqual(result["tags"] as? [String], ["a", "b", "c"])
    }

    func testParseBodyExpressions_arrayFunctionsHaveDistinctSemantics_BitsUT() throws {
        let result = try RequestCustomizationExpression.parseBodyExpressions(
            [
                "nested = append(body.numbers, [2, 3])",
                "flat = concat(body.numbers, [2, 3])",
                #"updated = update(body.tools, {type: "function"}, {a: 2, b: {mode: "strict"}})"#,
                #"inserted = insert(body.tags, 1, "middle")"#,
                #"insertedLast = insert(body.tags, -1, "last")"#,
                "removedAt = remove_at(body.tags, 1)",
                "removedLast = remove_at(body.tags, -1)",
            ],
            context: makeContext(body: [
                "numbers": [1],
                "tools": [
                    ["type": "function", "a": 1],
                    ["type": "web_search"],
                ],
                "tags": ["first", "second", "third"],
            ])
        )

        let nested = try XCTUnwrap(result["nested"] as? [Any])
        XCTAssertEqual(nested[0] as? Int, 1)
        XCTAssertEqual(nested[1] as? [Int], [2, 3])
        XCTAssertEqual(result["flat"] as? [Int], [1, 2, 3])

        let updated = try XCTUnwrap(result["updated"] as? [[String: Any]])
        XCTAssertEqual(updated[0]["a"] as? Int, 2)
        XCTAssertEqual(
            (updated[0]["b"] as? [String: Any])?["mode"] as? String,
            "strict"
        )
        XCTAssertNil(updated[1]["a"])
        XCTAssertEqual(result["inserted"] as? [String], ["first", "middle", "second", "third"])
        XCTAssertEqual(result["insertedLast"] as? [String], ["first", "second", "third", "last"])
        XCTAssertEqual(result["removedAt"] as? [String], ["first", "third"])
        XCTAssertEqual(result["removedLast"] as? [String], ["first", "second"])
    }

    func testParseBodyExpressions_removeFiltersScalarsAndMatchingObjects_BitsUT() throws {
        let result = try RequestCustomizationExpression.parseBodyExpressions(
            [
                #"tools = remove(body.tools, {type: "web_search"})"#,
                #"tags = remove(body.tags, ["old", "unused"])"#,
                #"alternatives = remove(body.mixed, {type: "legacy"}, {disabled: true}, "obsolete")"#,
                #"allFields = remove(body.objects, {type: "legacy", disabled: true})"#,
            ],
            context: makeContext(body: [
                "tools": [
                    ["type": "function", "name": "existing"],
                    ["type": "web_search", "scope": "wide"],
                ],
                "tags": ["keep", "old", "unused"],
                "mixed": [
                    ["type": "legacy", "disabled": false],
                    ["type": "current", "disabled": true],
                    ["type": "current", "disabled": false],
                    "obsolete",
                    "keep",
                ],
                "objects": [
                    ["type": "legacy", "disabled": false],
                    ["type": "legacy", "disabled": true],
                ],
            ])
        )

        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["name"] as? String, "existing")
        XCTAssertEqual(result["tags"] as? [String], ["keep"])
        let alternatives = try XCTUnwrap(
            result["alternatives"] as? [Any]
        )
        XCTAssertEqual(alternatives.count, 2)
        XCTAssertEqual(
            (alternatives[0] as? [String: Any])?["type"]
                as? String,
            "current"
        )
        XCTAssertEqual(alternatives[1] as? String, "keep")
        let allFields = try XCTUnwrap(
            result["allFields"] as? [[String: Any]]
        )
        XCTAssertEqual(allFields.count, 1)
        XCTAssertEqual(allFields[0]["disabled"] as? Bool, false)
    }

    func testParseExpressions_invalidAssignmentsAreSkipped_BitsUT() throws {
        let body = try RequestCustomizationExpression
            .parseBodyExpressions(
                [
                    "missing assignment",
                    #"valid = "kept""#,
                    #"config = {mode = "strict"}"#,
                ],
                context: makeContext()
            )
        var headers: [String: String] = [:]
        try RequestCustomizationExpression
            .applyHeaderExpressions(
                [
                    "= value",
                    #"X-Valid = "kept""#,
                ],
                to: &headers,
                context: makeContext()
            )

        XCTAssertEqual(body["valid"] as? String, "kept")
        XCTAssertNil(body["config"])
        XCTAssertEqual(headers["X-Valid"], "kept")
    }

    func testEvaluateTemplate_supportsDirectRequestRootsAndUtilityFunctions_BitsUT() throws {
        let context = makeContext(
            headers: ["X-Trace": "trace-value"],
            body: ["config": ["mode": "strict"]]
        )

        XCTAssertEqual(
            try RequestCustomizationExpression.evaluateTemplate(
                #"{{ headers["X-Trace"] }}"#,
                context: context
            ) as? String,
            "trace-value"
        )
        XCTAssertEqual(
            try RequestCustomizationExpression.evaluateTemplate(
                "{{ body.config.mode }}",
                context: context
            ) as? String,
            "strict"
        )
        XCTAssertEqual(
            try RequestCustomizationExpression.evaluateTemplate(
                "{{ json(body.config) }}",
                context: context
            ) as? String,
            #"{"mode":"strict"}"#
        )
        let uuid = try XCTUnwrap(
            try RequestCustomizationExpression.evaluateTemplate(
                "{{ uuid() }}",
                context: context
            ) as? String
        )
        XCTAssertNotNil(UUID(uuidString: uuid))
        let before = Int(Date().timeIntervalSince1970)
        let now = try XCTUnwrap(
            try RequestCustomizationExpression.evaluateTemplate(
                "{{ now() }}",
                context: context
            ) as? Int
        )
        XCTAssertTrue(now >= before)
        XCTAssertTrue(
            now <= Int(Date().timeIntervalSince1970)
        )
    }

    func testEvaluateTemplate_coversRemainingFunctionsAndLazyBranches_BitsUT() throws {
        let context = makeContext(
            body: ["present": NSNull()]
        )

        XCTAssertEqual(
            try RequestCustomizationExpression.evaluateTemplate(
                "{{ string({b: 2, a: 1}) }}",
                context: context
            ) as? String,
            #"{"a":1,"b":2}"#
        )
        XCTAssertEqual(
            try RequestCustomizationExpression.evaluateTemplate(
                "{{ string(null) }}",
                context: context
            ) as? String,
            ""
        )
        XCTAssertEqual(
            try RequestCustomizationExpression.evaluateTemplate(
                #"{{ sha256("hello") }}"#,
                context: context
            ) as? String,
            "2cf24dba5fb0a30e26e83b2ac5b9e29e" +
                "1b161e5c1fa7425e73043362938b9824"
        )
        XCTAssertEqual(
            try RequestCustomizationExpression.evaluateTemplate(
                "{{ exists(body.present) }}",
                context: context
            ) as? Bool,
            true
        )
        XCTAssertEqual(
            try RequestCustomizationExpression.evaluateTemplate(
                "{{ exists(body.absent) }}",
                context: context
            ) as? Bool,
            false
        )
        XCTAssertEqual(
            try RequestCustomizationExpression.evaluateTemplate(
                #"{{ if(true, "selected", length(1)) }}"#,
                context: context
            ) as? String,
            "selected"
        )
        XCTAssertEqual(
            try RequestCustomizationExpression.evaluateTemplate(
                #"{{ true ? "selected" : length(1) }}"#,
                context: context
            ) as? String,
            "selected"
        )
        XCTAssertEqual(
            try RequestCustomizationExpression.evaluateTemplate(
                #"{{ "selected" ?? length(1) }}"#,
                context: context
            ) as? String,
            "selected"
        )
        XCTAssertEqual(
            try RequestCustomizationExpression.evaluateTemplate(
                "{{ false && length(1) > 0 }}",
                context: context
            ) as? Bool,
            false
        )
        XCTAssertEqual(
            try RequestCustomizationExpression.evaluateTemplate(
                "{{ true || length(1) > 0 }}",
                context: context
            ) as? Bool,
            true
        )
    }

    func testValidation_reportsExpressionResourceLimits_BitsUT() {
        let oversized = #"value = ""#
            + String(repeating: "a", count: 65_537)
            + #"""#
        let tokenHeavy = "value = ["
            + Array(repeating: "1", count: 1_100)
                .joined(separator: ",")
            + "]"
        let nested = "value = "
            + String(repeating: "(", count: 129)
            + "1"
            + String(repeating: ")", count: 129)

        let issues = RequestCustomizationExpression.validationIssues(
            [oversized, tokenHeavy, nested],
            target: .body
        )

        XCTAssertEqual(issues.map(\.line), [1, 2, 3])
        XCTAssertEqual(
            issues.map(\.message),
            Array(
                repeating: String(
                    localized:
                        "Expression evaluation limit exceeded."
                ),
                count: 3
            )
        )
    }

    func testParseBodyExpressions_evaluationLimitSkipsOnlyFailingLine_BitsUT() throws {
        let result = try RequestCustomizationExpression
            .parseBodyExpressions(
                [
                    "limited = body.items.map(item, item)",
                    #"after = "kept""#,
                ],
                context: makeContext(
                    body: [
                        "items": Array(0..<100_100),
                    ]
                )
            )

        XCTAssertNil(result["limited"])
        XCTAssertEqual(result["after"] as? String, "kept")
    }

    func testEvaluateTemplate_supportsUnixTimestampsFormattingAndParsing_BitsUT() throws {
        let context = makeContext()
        let beforeMilliseconds = Int(
            Date().timeIntervalSince1970 * 1_000
        )
        let nowMilliseconds = try XCTUnwrap(
            try RequestCustomizationExpression.evaluateTemplate(
                #"{{ now("milliseconds") }}"#,
                context: context
            ) as? Int
        )
        XCTAssertTrue(
            nowMilliseconds >= beforeMilliseconds
        )
        XCTAssertTrue(
            nowMilliseconds <= Int(
                Date().timeIntervalSince1970 * 1_000
            )
        )
        XCTAssertEqual(
            try RequestCustomizationExpression.evaluateTemplate(
                #"{{ format_time(1704067200123, "YYYY-MM-DD HH:mm:ss.SSS", "milliseconds", "UTC") }}"#,
                context: context
            ) as? String,
            "2024-01-01 00:00:00.123"
        )
        XCTAssertEqual(
            try RequestCustomizationExpression.evaluateTemplate(
                #"{{ format_time(0, "YYYY-MM-DD HH:mm:ss", "seconds", "Asia/Shanghai") }}"#,
                context: context
            ) as? String,
            "1970-01-01 08:00:00"
        )
        XCTAssertEqual(
            try RequestCustomizationExpression.evaluateTemplate(
                #"{{ parse_time("2024-01-01 00:00:00", "YYYY-MM-DD HH:mm:ss", "seconds", "UTC") }}"#,
                context: context
            ) as? Int,
            1_704_067_200
        )
        XCTAssertEqual(
            try RequestCustomizationExpression.evaluateTemplate(
                #"{{ parse_time("2024-01-01 00:00:00.123", "YYYY-MM-DD HH:mm:ss.SSS", "milliseconds", "UTC") }}"#,
                context: context
            ) as? Int,
            1_704_067_200_123
        )
        XCTAssertEqual(
            try RequestCustomizationExpression.evaluateTemplate(
                #"{{ format_time(1704067200, "YY-M-D H:m:s", "seconds", "UTC") }}"#,
                context: context
            ) as? String,
            "24-1-1 0:0:0"
        )
        XCTAssertEqual(
            try RequestCustomizationExpression.evaluateTemplate(
                #"{{ format_time(1704112496, "HH", "seconds", "UTC") }}"#,
                context: context
            ) as? String,
            "12"
        )
        XCTAssertEqual(
            try RequestCustomizationExpression.evaluateTemplate(
                #"{{ format_time(1704112496, "hh h a", "seconds", "UTC") }}"#,
                context: context
            ) as? String,
            "12 12 PM"
        )
        XCTAssertEqual(
            try RequestCustomizationExpression.evaluateTemplate(
                #"{{ parse_time("24-1-2 3:4:5 PM", "YY-M-D h:m:s a", "seconds", "UTC") }}"#,
                context: context
            ) as? Int,
            1_704_207_845
        )
    }

    func testRuntimeExpressionErrorsSkipOnlyFailingLines_BitsUT() throws {
        let invalidExtra =
            #"headers.extra = json({session_id: session.id ?? body.prompt_cache_key ?? md5(body.input.filter(message, message.role == "user")[0].content.filter(part, part.type == "input_text")[0].text)})"#
        let context = makeContext(
            sessionId: nil,
            body: [
                "input": [[
                    "role": "assistant",
                    "content": "text",
                ]],
            ]
        )
        var headerResult: [String: String] = [:]
        try RequestCustomizationExpression
            .applyHeaderExpressions(
                [
                    #"X-Before = "before""#,
                    "X-Null = null",
                    #"X-After = "after""#,
                ],
                to: &headerResult,
                context: context
            )
        let bodyResult = try RequestCustomizationExpression
            .parseBodyExpressions(
                [
                    "before = 1",
                    "bad = length(1)",
                    "after = 2",
                ],
                context: context
            )
        var body = context.body
        var headers: [String: String] = [:]
        try RequestCustomizationExpression
            .applyControlExpressions(
                [
                    invalidExtra,
                    "body.bad_length = length(1)",
                    #"headers.X-Control = "kept""#,
                    "body.control_value = 3",
                ],
                to: &body,
                headers: &headers,
                context: context
            )

        XCTAssertEqual(headerResult["X-Before"], "before")
        XCTAssertEqual(headerResult["X-After"], "after")
        XCTAssertNil(headerResult["X-Null"])
        XCTAssertEqual(bodyResult["before"] as? Int, 1)
        XCTAssertNil(bodyResult["bad"])
        XCTAssertEqual(bodyResult["after"] as? Int, 2)
        XCTAssertNil(headers["extra"])
        XCTAssertEqual(headers["X-Control"], "kept")
        XCTAssertNil(body["bad_length"])
        XCTAssertEqual(body["control_value"] as? Int, 3)
    }

    func testParseBodyExpressions_supportsNestedFunctionsAndSkipsMissingDirectReferences_BitsUT() throws {
        let result = try RequestCustomizationExpression.parseBodyExpressions(
            [
                #"missing = append(body.notPresent, ["ignored"])"#,
                "numbers = concat([1], [2], [3, 4])",
                #"valid = "kept""#,
            ],
            context: makeContext()
        )

        XCTAssertNil(result["missing"])
        XCTAssertEqual(result["numbers"] as? [Int], [1, 2, 3, 4])
        XCTAssertEqual(result["valid"] as? String, "kept")
    }

    func testParseExpressions_preservesEscapesEqualsAndHeaderJSONValues_BitsUT() throws {
        let context = makeContext()
        let body = try RequestCustomizationExpression.parseBodyExpressions(
            [
                #"text = "a=b,\"quoted\"\nnext""#,
                #"object = {url: "https://example.com?a=b", flag: true}"#,
            ],
            context: context
        )
        var headers: [String: String] = [:]
        try RequestCustomizationExpression.applyHeaderExpressions(
            [
                #"X-Object = {mode: "strict", count: 2}"#,
                #"X-Array = ["a", "b"]"#,
            ],
            to: &headers,
            context: context
        )

        XCTAssertEqual(body["text"] as? String, "a=b,\"quoted\"\nnext")
        XCTAssertEqual(
            (body["object"] as? [String: Any])?["url"] as? String,
            "https://example.com?a=b"
        )
        XCTAssertEqual(headers["X-Object"], #"{"count":2,"mode":"strict"}"#)
        XCTAssertEqual(headers["X-Array"], #"["a","b"]"#)
    }

    func testValidation_acceptsSupportedSyntaxAndMissingValues_BitsUT() {
        let headerIssues = RequestCustomizationExpression.validationIssues(
            [
                #"User-Agent = "Minix/1.0""#,
                #"Authorization = "Bearer {{ provider.apiKey }}""#,
                #"X-Missing = "{{ body.not_present }}""#,
            ],
            target: .header
        )
        let bodyIssues = RequestCustomizationExpression.validationIssues(
            [
                #"reasoning = {effort: "high", summary: "auto"}"#,
                #"tools = append(body.tools, {type: "web_search"})"#,
                #"filtered = remove(body.tools, {type: "web_search"})"#,
                #"updated = update(body.tools, {type: "function"}, {strict: true})"#,
                #"inserted = insert(body.tools, 0, {type: "web_search"})"#,
                "removedAt = remove_at(body.tools, 0)",
                "removedLast = remove_at(body.tools, -1)",
                #"metadata.id = "{{ uuid() }}""#,
                #"metadata.model = "{{ upper(model.id) }}""#,
            ],
            target: .body
        )

        XCTAssertTrue(headerIssues.isEmpty)
        XCTAssertTrue(bodyIssues.isEmpty)
    }

    func testNormalizedExpressionEditorText_removesBlankLinesAndKeepsOneEditingLine_BitsUT() {
        XCTAssertEqual(normalizedExpressionEditorText(""), "")
        XCTAssertEqual(normalizedExpressionEditorText("\n\n"), "")
        XCTAssertEqual(
            normalizedExpressionEditorText("temperature = 0.7\n\nmax_tokens = 4096"),
            "temperature = 0.7\nmax_tokens = 4096"
        )
        XCTAssertEqual(
            normalizedExpressionEditorText("temperature = 0.7\n\n\n"),
            "temperature = 0.7\n"
        )
        XCTAssertEqual(
            finalizedExpressionEditorText("temperature = 0.7\n\n\n"),
            "temperature = 0.7"
        )
    }

    func testValidation_reportsLineNumbersForMalformedExpressions_BitsUT() {
        let issues = RequestCustomizationExpression.validationIssues(
            [
                #"valid = "value""#,
                "missing_assignment",
                #"broken = {value: "unterminated""#,
                #"unknown = "{{ mystery(model.id) }}""#,
                #"template = "{{ session.id ""#,
                #"function = apend(body.tools, [])"#,
                #"arguments = update(body.tools, {})"#,
                "alias = request.body.tools",
                "legacy = remove_last(body.tools)",
            ],
            target: .body
        )

        XCTAssertEqual(issues.map(\.line), [2, 3, 4, 5, 6, 7, 8, 9])
    }

    private func makeContext(
        apiKey: String? = "api-key",
        sessionId: String? = "session-test",
        customBaseURL: String? = "https://example.com/v1",
        headers: [String: String] = [:],
        body: [String: Any] = [:]
    ) -> RequestCustomizationExpression.Context {
        RequestCustomizationExpression.Context(
            provider: ProviderInstance(
                id: "provider-test",
                label: "Test Provider",
                providerType: .openAI,
                credentialType: .apiKey,
                customBaseURL: customBaseURL
            ),
            model: LLMModel(
                id: "test-model",
                displayName: "Test Model",
                provider: "OpenAI",
                supportsReasoning: true
            ),
            apiKey: apiKey,
            sessionId: sessionId,
            headers: headers,
            body: body
        )
    }
}

final class RequestCustomizationApplicationTests: XCTestCase {

    func testReferencesProviderAPIKey_onlyWhenAnExpressionUsesIt_BitsUT() {
        let plainProvider = ProviderInstance(
            id: "plain-provider",
            label: "Plain",
            providerType: .anthropic,
            credentialType: .oauth,
            customRequestBody: [
                #"metadata.source = "custom""#,
            ]
        )
        XCTAssertFalse(
            RequestCustomization(
                provider: plainProvider,
                modelEntry: nil
            ).referencesProviderAPIKey
        )

        let keyProvider = ProviderInstance(
            id: "key-provider",
            label: "Key",
            providerType: .anthropic,
            credentialType: .oauth,
            customRequestHeaders: [
                #"X-Token = {{ provider["apiKey"] }}"#,
            ]
        )
        XCTAssertTrue(
            RequestCustomization(
                provider: keyProvider,
                modelEntry: nil
            ).referencesProviderAPIKey
        )
    }

    func testApply_usesProviderThenModelThenControlPriority_BitsUT() {
        let provider = ProviderInstance(
            id: "provider-priority",
            label: "Priority Provider",
            providerType: .openAI,
            credentialType: .apiKey,
            customRequestHeaders: [
                #"X-Layer = "provider""#,
                #"X-Provider = "provider-only""#,
            ],
            customRequestBody: [
                #"config = {providerOnly: true, shared: "provider"}"#,
            ]
        )
        let control = RequestBodyControl(
            id: "priority-control",
            title: "Priority",
            kind: .toggle,
            defaultIsActive: true,
            payloadExpressions: [#"body.config.shared = "control""#]
        )
        let entry = makeEntry(
            provider: provider,
            modelID: "priority-model",
            overrides: ModelOverrides(
                customRequestHeaders: [
                    #"X-Layer = "model""#,
                    #"X-Model = "model-only""#,
                ],
                customRequestBody: [
                    #"config = {modelOnly: true, shared: "model"}"#,
                ],
                requestBodyControls: [control]
            )
        )
        var headers = ["X-Layer": "default", "X-Default": "default-only"]
        var body: [String: Any] = [
            "config": [
                "defaultOnly": true,
                "shared": "default",
            ],
        ]

        RequestCustomization(provider: provider, modelEntry: entry)
            .apply(to: &body, headers: &headers, apiKey: "api-key")

        XCTAssertEqual(headers["X-Default"], "default-only")
        XCTAssertEqual(headers["X-Provider"], "provider-only")
        XCTAssertEqual(headers["X-Model"], "model-only")
        XCTAssertEqual(headers["X-Layer"], "model")
        let config = body["config"] as? [String: Any]
        XCTAssertEqual(config?["defaultOnly"] as? Bool, true)
        XCTAssertEqual(config?["providerOnly"] as? Bool, true)
        XCTAssertEqual(config?["modelOnly"] as? Bool, true)
        XCTAssertEqual(config?["shared"] as? String, "control")
    }

    func testApply_withoutControlsKeepsProviderAndModelLayers_BitsUT() {
        let provider = ProviderInstance(
            id: "provider-base-layers",
            label: "Base Layers",
            providerType: .openAI,
            credentialType: .apiKey,
            customRequestHeaders: [
                #"X-Provider = "provider""#,
            ],
            customRequestBody: [
                #"metadata.provider = true"#,
            ]
        )
        let control = RequestBodyControl(
            id: "conversation-only",
            title: "Conversation Only",
            kind: .toggle,
            defaultIsActive: true,
            payloadExpressions: [
                "body.control_applied = true",
                #"headers.X-Control = "control""#,
            ]
        )
        let entry = makeEntry(
            provider: provider,
            modelID: "base-layers-model",
            overrides: ModelOverrides(
                customRequestHeaders: [
                    #"X-Model = "model""#,
                ],
                customRequestBody: [
                    #"metadata.model = true"#,
                ],
                requestBodyControls: [control]
            )
        )
        var body: [String: Any] = [:]
        var headers: [String: String] = [:]

        RequestCustomization(provider: provider, modelEntry: entry)
            .apply(
                to: &body,
                headers: &headers,
                apiKey: "api-key",
                includeControls: false
            )

        XCTAssertEqual(headers["X-Provider"], "provider")
        XCTAssertEqual(headers["X-Model"], "model")
        XCTAssertNil(headers["X-Control"])
        let metadata = body["metadata"] as? [String: Any]
        XCTAssertEqual(metadata?["provider"] as? Bool, true)
        XCTAssertEqual(metadata?["model"] as? Bool, true)
        XCTAssertNil(body["control_applied"])
    }

    func testApply_headerNamesAndReferencesAreCaseInsensitive_BitsUT() {
        let provider = ProviderInstance(
            id: "provider-header-case",
            label: "Header Case Provider",
            providerType: .openAI,
            credentialType: .apiKey,
            customRequestHeaders: [
                #"authorization = "Provider""#,
                #"X-From-Initial = {{ headers.ACCEPT }}"#,
            ]
        )
        let entry = makeEntry(
            provider: provider,
            modelID: "header-case-model",
            overrides: ModelOverrides(
                customRequestHeaders: [
                    #"X-From-Provider = {{ headers.authorization }}"#,
                    #"X-From-Bracket = {{ headers["authorization"] }}"#,
                    #"AUTHORIZATION = "Model""#,
                ]
            )
        )
        var headers = [
            "Accept": "application/json",
            "Authorization": "Default",
        ]
        var body: [String: Any] = [:]

        RequestCustomization(provider: provider, modelEntry: entry)
            .apply(to: &body, headers: &headers, apiKey: nil)

        XCTAssertEqual(headers["Authorization"], "Model")
        XCTAssertEqual(headers["X-From-Initial"], "application/json")
        XCTAssertEqual(headers["X-From-Provider"], "Provider")
        XCTAssertEqual(headers["X-From-Bracket"], "Provider")
        XCTAssertEqual(
            headers.keys.filter {
                $0.caseInsensitiveCompare("Authorization") == .orderedSame
            }.count,
            1
        )
    }

    func testApply_eachStageCanReadPriorHeadersAndBody_BitsUT() {
        let provider = ProviderInstance(
            id: "provider-context",
            label: "Context Provider",
            providerType: .openAI,
            credentialType: .apiKey,
            customRequestHeaders: ["X-Provider = {{ provider.id }}"],
            customRequestBody: [#"metadata.providerHeader = "{{ headers["X-Provider"] }}""#]
        )
        let entry = makeEntry(
            provider: provider,
            modelID: "context-model",
            overrides: ModelOverrides(
                customRequestHeaders: [#"X-Model = {{ headers["X-Provider"] }}"#],
                customRequestBody: [#"metadata.modelHeader = "{{ headers["X-Model"] }}""#]
            )
        )
        var headers: [String: String] = [:]
        var body: [String: Any] = [:]

        RequestCustomization(provider: provider, modelEntry: entry)
            .apply(to: &body, headers: &headers, apiKey: "api-key")

        XCTAssertEqual(headers["X-Provider"], provider.id)
        XCTAssertEqual(headers["X-Model"], provider.id)
        let metadata = body["metadata"] as? [String: Any]
        XCTAssertEqual(metadata?["providerHeader"] as? String, provider.id)
        XCTAssertEqual(metadata?["modelHeader"] as? String, provider.id)
    }

    func testProviderHeadersForModelList_appliesAvailableValuesAndSkipsBodyValues_BitsUT() {
        let provider = ProviderInstance(
            id: "provider-model-list",
            label: "Model List Provider",
            providerType: .openAI,
            credentialType: .apiKey,
            customRequestHeaders: [
                "X-API-Key = {{ provider.apiKey }}",
                "X-Body = {{ body.model }}",
            ]
        )

        let headers = RequestCustomization.providerHeadersForModelList(
            provider: provider,
            apiKey: "list-key",
            initialHeaders: ["Accept": "application/json"]
        )

        XCTAssertEqual(headers["Accept"], "application/json")
        XCTAssertEqual(headers["X-API-Key"], "list-key")
        XCTAssertNil(headers["X-Body"])
    }

    func testApply_toggleUsesRuntimeStateInsteadOfDefault_BitsUT() {
        let provider = makeProvider(id: "provider-toggle")
        let control = RequestBodyControl(
            id: "web-search",
            title: "Web Search",
            kind: .toggle,
            defaultIsActive: false,
            payloadExpressions: [#"body.tools = [{type: "web_search"}]"#]
        )
        let entry = makeEntry(
            provider: provider,
            modelID: "toggle-model",
            overrides: ModelOverrides(requestBodyControls: [control])
        )
        let sessionKey = "session-\(UUID().uuidString)"
        let defaultsKey = runtimeDefaultsKey(
            sessionKey: sessionKey
        )
        defer { UserDefaults.standard.removeObject(forKey: defaultsKey) }
        RequestBodyControlRuntimeStore.save(
            RequestBodyControlState(toggleValuesByControlID: [control.id: true]),
            forSessionKey: sessionKey,
            modelKey: entry.id,
            controls: [control]
        )
        var body: [String: Any] = [:]
        var headers: [String: String] = [:]

        RequestCustomizationRuntime.$sessionId.withValue(
            sessionKey
        ) {
            RequestCustomizationRuntime
                .$usesConversationRequestControlState
                .withValue(true) {
                    RequestCustomization(
                        provider: provider,
                        modelEntry: entry
                    ).apply(
                        to: &body,
                        headers: &headers,
                        apiKey: nil
                    )
                }
        }

        XCTAssertEqual((body["tools"] as? [[String: Any]])?.first?["type"] as? String, "web_search")
    }

    func testApply_optionGroupUsesFirstOptionByDefaultAndPersistsSelection_BitsUT() {
        let provider = makeProvider(id: "provider-option")
        let control = RequestBodyControl(
            id: "temperature",
            title: "Temperature",
            kind: .optionGroup,
            options: [
                RequestBodyControlOption(id: "low", title: "Low", payloadExpressions: ["body.temperature = 0.2"]),
                RequestBodyControlOption(id: "high", title: "High", payloadExpressions: ["body.temperature = 1.0"]),
            ]
        )
        let entry = makeEntry(
            provider: provider,
            modelID: "option-model",
            overrides: ModelOverrides(requestBodyControls: [control])
        )
        let sessionKey = "session-\(UUID().uuidString)"
        let defaultsKey = runtimeDefaultsKey(
            sessionKey: sessionKey
        )
        defer { UserDefaults.standard.removeObject(forKey: defaultsKey) }
        var body: [String: Any] = [:]
        var headers: [String: String] = [:]

        RequestCustomization(provider: provider, modelEntry: entry)
            .apply(to: &body, headers: &headers, apiKey: nil)
        XCTAssertEqual(body["temperature"] as? Double, 0.2)

        RequestBodyControlRuntimeStore.save(
            RequestBodyControlState(selectedOptionIDsByControlID: [control.id: "high"]),
            forSessionKey: sessionKey,
            modelKey: entry.id,
            controls: [control]
        )
        RequestCustomizationRuntime.$sessionId.withValue(
            sessionKey
        ) {
            RequestCustomizationRuntime
                .$usesConversationRequestControlState
                .withValue(true) {
                    RequestCustomization(
                        provider: provider,
                        modelEntry: entry
                    ).apply(
                        to: &body,
                        headers: &headers,
                        apiKey: nil
                    )
                }
        }
        XCTAssertEqual(body["temperature"] as? Double, 1.0)
    }

    func testApply_internalTaskGetsSessionButUsesConfiguredDefaults_BitsUT() {
        let provider = makeProvider(id: "provider-internal")
        let control = RequestBodyControl(
            id: "web-search",
            title: "Web Search",
            kind: .toggle,
            defaultIsActive: false,
            payloadExpressions: ["body.web_search = true"]
        )
        let entry = makeEntry(
            provider: provider,
            modelID: "internal-model",
            overrides: ModelOverrides(
                customRequestBody: [
                    "expression_session = session.id",
                ],
                requestBodyControls: [control]
            )
        )
        let sessionKey = "session-\(UUID().uuidString)"
        let defaultsKey = runtimeDefaultsKey(
            sessionKey: sessionKey
        )
        defer {
            UserDefaults.standard.removeObject(
                forKey: defaultsKey
            )
        }
        RequestBodyControlRuntimeStore.save(
            RequestBodyControlState(
                toggleValuesByControlID: [
                    control.id: true,
                ]
            ),
            forSessionKey: sessionKey,
            modelKey: entry.id,
            controls: [control]
        )
        var body: [String: Any] = [:]
        var headers: [String: String] = [:]

        RequestCustomizationRuntime.$sessionId.withValue(
            sessionKey
        ) {
            RequestCustomizationRuntime
                .$usesConversationRequestControlState
                .withValue(false) {
                    RequestCustomization(
                        provider: provider,
                        modelEntry: entry
                    ).apply(
                        to: &body,
                        headers: &headers,
                        apiKey: nil
                    )
                }
        }

        XCTAssertEqual(
            body["expression_session"] as? String,
            sessionKey
        )
        XCTAssertNil(body["web_search"])
    }

    func testApply_sliderUsesPersistedOptionID_BitsUT() {
        let provider = makeProvider(id: "provider-slider")
        let control = RequestBodyControl(
            id: "quality",
            title: "Quality",
            kind: .optionGroup,
            isSliderEnabled: true,
            options: [
                RequestBodyControlOption(id: "low", title: "Low", payloadExpressions: [#"body.quality = "low""#]),
                RequestBodyControlOption(id: "medium", title: "Medium", payloadExpressions: [#"body.quality = "medium""#]),
                RequestBodyControlOption(id: "high", title: "High", payloadExpressions: [#"body.quality = "high""#]),
            ]
        )
        let entry = makeEntry(
            provider: provider,
            modelID: "slider-model",
            overrides: ModelOverrides(requestBodyControls: [control])
        )
        let sessionKey = "session-\(UUID().uuidString)"
        let defaultsKey = runtimeDefaultsKey(
            sessionKey: sessionKey
        )
        defer { UserDefaults.standard.removeObject(forKey: defaultsKey) }
        RequestBodyControlRuntimeStore.save(
            RequestBodyControlState(
                selectedOptionIDsByControlID: [
                    control.id: "high",
                ]
            ),
            forSessionKey: sessionKey,
            modelKey: entry.id,
            controls: [control]
        )
        var body: [String: Any] = [:]
        var headers: [String: String] = [:]

        RequestCustomizationRuntime.$sessionId.withValue(
            sessionKey
        ) {
            RequestCustomizationRuntime
                .$usesConversationRequestControlState
                .withValue(true) {
                    RequestCustomization(
                        provider: provider,
                        modelEntry: entry
                    ).apply(
                        to: &body,
                        headers: &headers,
                        apiKey: nil
                    )
                }
        }

        XCTAssertEqual(body["quality"] as? String, "high")
    }

    func testApply_sliderUsesConfiguredDefaultWithoutRuntimeState_BitsUT() {
        let provider = makeProvider(id: "provider-slider-default")
        let control = RequestBodyControl(
            id: "quality-default",
            title: "Quality",
            kind: .optionGroup,
            defaultOptionID: "high",
            isSliderEnabled: true,
            options: [
                RequestBodyControlOption(
                    id: "low",
                    title: "Low",
                    payloadExpressions: [#"body.quality = "low""#]
                ),
                RequestBodyControlOption(
                    id: "high",
                    title: "High",
                    payloadExpressions: [#"body.quality = "high""#]
                ),
            ]
        )
        let entry = makeEntry(
            provider: provider,
            modelID: "slider-default-model",
            overrides: ModelOverrides(requestBodyControls: [control])
        )
        var body: [String: Any] = [:]
        var headers: [String: String] = [:]

        RequestCustomization(provider: provider, modelEntry: entry)
            .apply(to: &body, headers: &headers, apiKey: nil)

        XCTAssertEqual(body["quality"] as? String, "high")
    }

    func testApply_thinkingControlUsesSessionLevelIdOverStaleModelState_BitsUT() {
        let provider = makeProvider(id: "provider-thinking-session")
        let control = RequestBodyControl(
            id: "thinking",
            title: "Thinking",
            kind: .optionGroup,
            semanticKind: .thinkingBudget,
            isSliderEnabled: true,
            options: [
                RequestBodyControlOption(
                    id: "low-option",
                    thinkingDefinitionId: "low",
                    title: "Low",
                    payloadExpressions: [#"body.effort = "low""#]
                ),
                RequestBodyControlOption(
                    id: "high-option",
                    thinkingDefinitionId: "high",
                    title: "High",
                    payloadExpressions: [#"body.effort = "high""#]
                ),
            ]
        )
        let entry = makeEntry(
            provider: provider,
            modelID: "thinking-session-model",
            overrides: ModelOverrides(requestBodyControls: [control])
        )
        let sessionKey = "session-\(UUID().uuidString)"
        let defaultsKey = runtimeDefaultsKey(
            sessionKey: sessionKey
        )
        defer { UserDefaults.standard.removeObject(forKey: defaultsKey) }
        RequestBodyControlRuntimeStore.save(
            RequestBodyControlState(
                selectedOptionIDsByControlID: [
                    control.id: "low-option",
                ]
            ),
            forSessionKey: sessionKey,
            modelKey: entry.id,
            controls: [control]
        )
        var body: [String: Any] = [:]
        var headers: [String: String] = [:]

        RequestCustomizationRuntime.$sessionId.withValue(
            sessionKey
        ) {
            RequestCustomizationRuntime
                .$thinkingDefinitionId.withValue("high") {
                RequestCustomization(
                    provider: provider,
                    modelEntry: entry
                ).apply(
                    to: &body,
                    headers: &headers,
                    apiKey: nil
                )
            }
        }

        XCTAssertEqual(body["effort"] as? String, "high")
    }

    func testApply_thinkingControlClampsCustomLevelByRank_BitsUT() {
        let original = ThinkingLevelRegistry.definitions
        defer { ThinkingLevelRegistry.saveDefinitions(original) }
        var definitions = ThinkingLevelRegistry.builtInDefinitions
        definitions.insert(
            ThinkingLevelDefinition(
                definitionId: "between-uuid",
                levelId: "between_low_medium",
                title: "Between",
                rank: 3
            ),
            at: 3
        )
        ThinkingLevelRegistry.saveDefinitions(definitions)

        let provider = makeProvider(id: "provider-thinking-rank")
        let control = RequestBodyControl(
            id: "thinking-rank",
            title: "Thinking",
            kind: .optionGroup,
            semanticKind: .thinkingBudget,
            options: [
                RequestBodyControlOption(
                    id: "low-option",
                    thinkingDefinitionId: "low",
                    title: "Low",
                    payloadExpressions: [#"body.effort = "low""#]
                ),
                RequestBodyControlOption(
                    id: "medium-option",
                    thinkingDefinitionId: "medium",
                    title: "Medium",
                    payloadExpressions: [#"body.effort = "medium""#]
                ),
            ]
        )
        let entry = makeEntry(
            provider: provider,
            modelID: "thinking-rank-model",
            overrides: ModelOverrides(requestBodyControls: [control])
        )
        var body: [String: Any] = [:]
        var headers: [String: String] = [:]

        RequestCustomizationRuntime
            .$thinkingDefinitionId.withValue(
            "between-uuid"
        ) {
            RequestCustomization(provider: provider, modelEntry: entry)
                .apply(to: &body, headers: &headers, apiKey: nil)
        }

        XCTAssertEqual(body["effort"] as? String, "low")
    }

    func testApply_skipsDisabledControlsAndInactiveToggles_BitsUT() {
        let provider = makeProvider(id: "provider-disabled-controls")
        let inactive = RequestBodyControl(
            id: "inactive",
            title: "Inactive",
            kind: .toggle,
            defaultIsActive: false,
            payloadExpressions: ["body.inactive = true"]
        )
        let disabled = RequestBodyControl(
            id: "disabled",
            title: "Disabled",
            kind: .toggle,
            isEnabled: false,
            defaultIsActive: true,
            payloadExpressions: ["body.disabled = true"]
        )
        let entry = makeEntry(
            provider: provider,
            modelID: "disabled-controls-model",
            overrides: ModelOverrides(requestBodyControls: [inactive, disabled])
        )
        var body: [String: Any] = [:]
        var headers: [String: String] = [:]

        RequestCustomization(provider: provider, modelEntry: entry)
            .apply(to: &body, headers: &headers, apiKey: nil)

        XCTAssertNil(body["inactive"])
        XCTAssertNil(body["disabled"])
    }

    private func makeProvider(id: String) -> ProviderInstance {
        ProviderInstance(
            id: id,
            label: "Test Provider",
            providerType: .openAI,
            credentialType: .apiKey
        )
    }

    private func makeEntry(
        provider: ProviderInstance,
        modelID: String,
        overrides: ModelOverrides
    ) -> ModelEntry {
        ModelEntry(
            uuid: "uuid-\(modelID)",
            providerInstanceId: provider.id,
            model: LLMModel(
                id: modelID,
                displayName: modelID,
                provider: "OpenAI",
                supportsReasoning: true
            ),
            overrides: overrides
        )
    }

    private func runtimeDefaultsKey(
        sessionKey: String
    ) -> String {
        RequestBodyControlRuntimeStore.storageKey(
            forSessionKey: sessionKey
        )
    }
}

final class RequestBodyControlRuntimeStoreTests: XCTestCase {

    func testSaveAndLoad_normalizesControlIDsAndOptions_BitsUT() {
        let sessionKey = "session-\(UUID().uuidString)"
        let modelKey = "runtime-\(UUID().uuidString)"
        let defaultsKey =
            RequestBodyControlRuntimeStore.storageKey(
                forSessionKey: sessionKey
            )
        defer { UserDefaults.standard.removeObject(forKey: defaultsKey) }
        let toggle = RequestBodyControl(id: "toggle", title: "Toggle", kind: .toggle)
        let option = RequestBodyControl(
            id: "option",
            title: "Option",
            kind: .optionGroup,
            options: [
                RequestBodyControlOption(id: "a", title: "A"),
                RequestBodyControlOption(id: "b", title: "B"),
            ]
        )
        let controls = [toggle, option]
        let state = RequestBodyControlState(
            toggleValuesByControlID: ["toggle": true, "deleted-toggle": true],
            selectedOptionIDsByControlID: [
                "option": "b",
                "deleted-option": "a",
                "option-invalid": "missing",
            ]
        )

        RequestBodyControlRuntimeStore.save(
            state,
            forSessionKey: sessionKey,
            modelKey: modelKey,
            controls: controls
        )
        let loaded = RequestBodyControlRuntimeStore.state(
            forSessionKey: sessionKey,
            modelKey: modelKey,
            controls: controls
        )

        XCTAssertEqual(loaded.toggleValuesByControlID, ["toggle": true])
        XCTAssertEqual(loaded.selectedOptionIDsByControlID, ["option": "b"])
    }

    func testState_newConversationUsingSameModelStartsFromDefaults_BitsUT() {
        let firstSessionKey = "session-a-\(UUID().uuidString)"
        let secondSessionKey = "session-b-\(UUID().uuidString)"
        let modelKey = "runtime-\(UUID().uuidString)"
        let firstDefaultsKey =
            RequestBodyControlRuntimeStore.storageKey(
                forSessionKey: firstSessionKey
            )
        defer {
            UserDefaults.standard.removeObject(
                forKey: firstDefaultsKey
            )
        }
        let control = RequestBodyControl(
            id: "toggle",
            title: "Toggle",
            kind: .toggle,
            defaultIsActive: false
        )

        RequestBodyControlRuntimeStore.save(
            RequestBodyControlState(
                toggleValuesByControlID: [control.id: true]
            ),
            forSessionKey: firstSessionKey,
            modelKey: modelKey,
            controls: [control]
        )

        let newConversationState =
            RequestBodyControlRuntimeStore.state(
                forSessionKey: secondSessionKey,
                modelKey: modelKey,
                controls: [control]
            )
        let firstConversationState =
            RequestBodyControlRuntimeStore.state(
                forSessionKey: firstSessionKey,
                modelKey: modelKey,
                controls: [control]
            )

        XCTAssertTrue(
            newConversationState.toggleValuesByControlID.isEmpty
        )
        XCTAssertEqual(
            firstConversationState
                .toggleValuesByControlID[control.id],
            true
        )
    }

    func testActivateModel_sameModelPreservesStateAcrossReload_BitsUT() {
        let sessionKey = "session-\(UUID().uuidString)"
        let modelKey = "runtime-\(UUID().uuidString)"
        let defaultsKey =
            RequestBodyControlRuntimeStore.storageKey(
                forSessionKey: sessionKey
            )
        defer { UserDefaults.standard.removeObject(forKey: defaultsKey) }
        let control = RequestBodyControl(
            id: "toggle",
            title: "Toggle",
            kind: .toggle,
            defaultIsActive: false
        )
        RequestBodyControlRuntimeStore.save(
            RequestBodyControlState(
                toggleValuesByControlID: [control.id: true]
            ),
            forSessionKey: sessionKey,
            modelKey: modelKey,
            controls: [control]
        )
        RequestBodyControlRuntimeStore.activateModel(
            forSessionKey: sessionKey,
            modelKey: modelKey
        )

        let state = RequestBodyControlRuntimeStore.state(
            forSessionKey: sessionKey,
            modelKey: modelKey,
            controls: [control]
        )

        XCTAssertEqual(
            state.toggleValuesByControlID[control.id],
            true
        )
    }

    func testActivateModel_AtoBtoAUsesDefaultsEachSwitch_BitsUT() {
        let sessionKey = "session-\(UUID().uuidString)"
        let defaultsKey =
            RequestBodyControlRuntimeStore.storageKey(
                forSessionKey: sessionKey
            )
        defer { UserDefaults.standard.removeObject(forKey: defaultsKey) }
        let control = RequestBodyControl(
            id: "toggle",
            title: "Toggle",
            kind: .toggle
        )
        let controls = [control]

        RequestBodyControlRuntimeStore.save(
            RequestBodyControlState(
                toggleValuesByControlID: [control.id: true]
            ),
            forSessionKey: sessionKey,
            modelKey: "model-a",
            controls: controls
        )
        RequestBodyControlRuntimeStore.activateModel(
            forSessionKey: sessionKey,
            modelKey: "model-b"
        )

        XCTAssertTrue(
            RequestBodyControlRuntimeStore.state(
                forSessionKey: sessionKey,
                modelKey: "model-a",
                controls: controls
            ).toggleValuesByControlID.isEmpty
        )
        XCTAssertTrue(
            RequestBodyControlRuntimeStore.state(
                forSessionKey: sessionKey,
                modelKey: "model-b",
                controls: controls
            ).toggleValuesByControlID.isEmpty
        )

        RequestBodyControlRuntimeStore.save(
            RequestBodyControlState(
                toggleValuesByControlID: [control.id: false]
            ),
            forSessionKey: sessionKey,
            modelKey: "model-b",
            controls: controls
        )
        RequestBodyControlRuntimeStore.activateModel(
            forSessionKey: sessionKey,
            modelKey: "model-a"
        )

        XCTAssertTrue(
            RequestBodyControlRuntimeStore.state(
                forSessionKey: sessionKey,
                modelKey: "model-a",
                controls: controls
            ).toggleValuesByControlID.isEmpty
        )
    }

    func testState_internalTaskIgnoresConversationSnapshot_BitsUT() {
        let sessionKey = "session-\(UUID().uuidString)"
        let modelKey = "runtime-\(UUID().uuidString)"
        let defaultsKey =
            RequestBodyControlRuntimeStore.storageKey(
                forSessionKey: sessionKey
            )
        defer { UserDefaults.standard.removeObject(forKey: defaultsKey) }
        let control = RequestBodyControl(
            id: "toggle",
            title: "Toggle",
            kind: .toggle
        )
        RequestBodyControlRuntimeStore.save(
            RequestBodyControlState(
                toggleValuesByControlID: [control.id: true]
            ),
            forSessionKey: sessionKey,
            modelKey: modelKey,
            controls: [control]
        )

        let state = RequestBodyControlRuntimeStore.state(
            forSessionKey: sessionKey,
            modelKey: modelKey,
            controls: [control],
            useConversationState: false
        )

        XCTAssertTrue(state.toggleValuesByControlID.isEmpty)
    }

    func testMigrate_movesCurrentDraftSnapshot_BitsUT() {
        let draftKey = "__new__\(UUID().uuidString)"
        let sessionKey = "session-\(UUID().uuidString)"
        let control = RequestBodyControl(
            id: "toggle",
            title: "Toggle",
            kind: .toggle
        )
        let controls = [control]
        let allDefaultsKeys = [
            RequestBodyControlRuntimeStore.storageKey(
                forSessionKey: draftKey
            ),
            RequestBodyControlRuntimeStore.storageKey(
                forSessionKey: sessionKey
            ),
        ]
        defer {
            for key in allDefaultsKeys {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        RequestBodyControlRuntimeStore.save(
            RequestBodyControlState(
                toggleValuesByControlID: [
                    control.id: true,
                ]
            ),
            forSessionKey: draftKey,
            modelKey: "model-a",
            controls: controls
        )

        RequestBodyControlRuntimeStore.migrate(
            fromSessionKey: draftKey,
            toSessionKey: sessionKey
        )

        XCTAssertTrue(
            RequestBodyControlRuntimeStore.state(
                forSessionKey: draftKey,
                modelKey: "model-a",
                controls: controls
            ).toggleValuesByControlID.isEmpty
        )
        XCTAssertEqual(
            RequestBodyControlRuntimeStore.state(
                forSessionKey: sessionKey,
                modelKey: "model-a",
                controls: controls
            ).toggleValuesByControlID[control.id],
            true
        )
        XCTAssertTrue(
            RequestBodyControlRuntimeStore.state(
                forSessionKey: sessionKey,
                modelKey: "model-b",
                controls: controls
            ).toggleValuesByControlID.isEmpty
        )
    }
}

final class RequestBodyControlDefaultsTests: XCTestCase {

    func testThinkingExpressions_matchProviderWireFormats_BitsUT() {
        XCTAssertEqual(
            RequestBodyControlDefaults.thinkingExpressions(providerType: .openAI, level: .high),
            [#"body.reasoning_effort = "high""#]
        )
        XCTAssertEqual(
            RequestBodyControlDefaults.thinkingExpressions(providerType: .openAIResponses, level: .high),
            [#"body.reasoning = {effort: "high", summary: "auto"}"#]
        )
        XCTAssertEqual(
            RequestBodyControlDefaults.thinkingExpressions(providerType: .openRouter, level: .high),
            [#"body.reasoning.effort = "high""#]
        )
        XCTAssertEqual(
            RequestBodyControlDefaults.thinkingExpressions(providerType: .anthropic, level: .off),
            [#"body.thinking = {type: "disabled"}"#]
        )
        XCTAssertEqual(
            RequestBodyControlDefaults.thinkingExpressions(providerType: .anthropic, level: .medium),
            [
                #"body.thinking = {type: "adaptive", display: "summarized"}"#,
                #"body.output_config.effort = "medium""#,
            ]
        )
        XCTAssertEqual(
            RequestBodyControlDefaults.thinkingExpressions(providerType: .anthropic, level: .max),
            [
                #"body.thinking = {type: "adaptive", display: "summarized"}"#,
                #"body.output_config.effort = "max""#,
            ]
        )
        XCTAssertEqual(
            RequestBodyControlDefaults.thinkingExpressions(providerType: .gemini, level: .off),
            [#"body.generationConfig.thinkingConfig = {thinkingLevel: "minimal", includeThoughts: true}"#]
        )
        XCTAssertEqual(
            RequestBodyControlDefaults.thinkingExpressions(providerType: .gemini, level: .medium),
            [#"body.generationConfig.thinkingConfig = {thinkingLevel: "medium", includeThoughts: true}"#]
        )
        XCTAssertEqual(
            RequestBodyControlDefaults.thinkingExpressions(providerType: .gemini, level: .xhigh),
            [#"body.generationConfig.thinkingConfig = {thinkingLevel: "high", includeThoughts: true}"#]
        )
        XCTAssertEqual(
            RequestBodyControlDefaults.thinkingExpressions(providerType: .openAI, level: .off),
            [#"body.reasoning_effort = "none""#]
        )
    }

    func testContainsThinkingControl_usesSemanticKindInsteadOfPayloadText_BitsUT() {
        let semanticControl = RequestBodyControl(
            id: "semantic",
            title: "Renamed",
            kind: .optionGroup,
            semanticKind: .thinkingBudget
        )
        let ordinaryControl = RequestBodyControl(
            id: "ordinary",
            title: "Summary",
            kind: .toggle,
            payloadExpressions: [
                #"body.metadata.reasoning_note = "enabled""#,
                #"body.effort_label = "fast""#,
            ]
        )

        XCTAssertTrue(RequestBodyControlDefaults.containsThinkingControl([semanticControl]))
        XCTAssertFalse(
            RequestBodyControlDefaults.containsThinkingControl([
                RequestBodyControl(
                    id: "disabled-semantic",
                    title: "Disabled",
                    kind: .optionGroup,
                    semanticKind: .thinkingBudget,
                    isEnabled: false
                ),
            ])
        )
        XCTAssertFalse(RequestBodyControlDefaults.containsThinkingControl([ordinaryControl]))
    }

    func testThinkingOptionGroup_usesStableLevelIDsAndRankOrder_BitsUT() {
        let provider = ProviderInstance(
            label: "OpenAI",
            providerType: .openAI,
            credentialType: .apiKey
        )

        let control = RequestBodyControlDefaults
            .thinkingOptionGroup(for: provider)

        XCTAssertEqual(control.semanticKind, .thinkingBudget)
        XCTAssertTrue(control.isSliderEnabled)
        XCTAssertNil(control.defaultOptionID)
        XCTAssertEqual(
            control.options.map(
                \.thinkingDefinitionId
            ),
            ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
        )
        XCTAssertEqual(
            control.options.map(\.id),
            control.options.compactMap(
                \.thinkingDefinitionId
            )
        )
    }

    func testThinkingOptionGroup_usesActualResponsesRouting_BitsUT() throws {
        func highExpression(for instance: ProviderInstance) throws -> String {
            let control =
                RequestBodyControlDefaults
                    .thinkingOptionGroup(for: instance)
            return try XCTUnwrap(
                control.options.first {
                    $0.thinkingDefinitionId == "high"
                }?.payloadExpressions.first
            )
        }

        let explicitResponses = ProviderInstance(
            label: "Responses",
            providerType: .openAIResponses,
            credentialType: .apiKey
        )
        let codexOAuth = ProviderInstance(
            label: "Codex",
            providerType: .openAI,
            credentialType: .oauth
        )
        let chatCompletions = ProviderInstance(
            label: "Chat",
            providerType: .openAI,
            credentialType: .apiKey,
            customBaseURL: "https://example.com/v1"
        )

        for instance in [explicitResponses, codexOAuth] {
            XCTAssertEqual(
                try highExpression(for: instance),
                #"body.reasoning = {effort: "high", summary: "auto"}"#
            )
        }
        XCTAssertEqual(
            try highExpression(for: chatCompletions),
            #"body.reasoning_effort = "high""#
        )
        XCTAssertEqual(
            RequestBodyControlDefaults.thinkingExpressions(
                for: codexOAuth,
                level: .high
            ),
            [#"body.reasoning = {effort: "high", summary: "auto"}"#]
        )
        XCTAssertTrue(
            RequestBodyControlDefaults.thinkingExpressions(
                for: ThinkingLevelDefinition(
                    definitionId: "custom-extreme",
                    levelId: "extreme",
                    title: "Extreme",
                    rank: 100
                ),
                provider: codexOAuth
            ).isEmpty
        )
    }

    @MainActor
    func testFallbackThinkingSelection_preservesConversationAndClampsToCandidate_BitsUT() {
        let control = RequestBodyControl(
            id: "thinking",
            title: "Thinking",
            kind: .optionGroup,
            semanticKind: .thinkingBudget,
            defaultOptionID: "high-option",
            options: [
                RequestBodyControlOption(
                    id: "low-option",
                    thinkingDefinitionId: "low",
                    title: "Low"
                ),
                RequestBodyControlOption(
                    id: "high-option",
                    thinkingDefinitionId: "high",
                    title: "High"
                ),
            ]
        )
        let entry = ModelEntry(
            providerInstanceId: "provider",
            model: LLMModel(
                id: "reasoning-model",
                displayName: "Reasoning Model",
                provider: "OpenAI",
                supportsReasoning: true
            ),
            overrides: ModelOverrides(
                requestBodyControls: [control]
            )
        )

        XCTAssertEqual(
            AIChatViewModel.resolvedThinkingDefinitionId(
                "low",
                forModelEntry: entry
            ),
            "low"
        )
        XCTAssertEqual(
            AIChatViewModel.resolvedThinkingDefinitionId(
                "xhigh",
                forModelEntry: entry
            ),
            "high"
        )
    }
}

final class GeminiRequestCustomizationTests: XCTestCase {

    func testCloudCodeCustomizationTargetsInnerRequestBody_BitsUT() throws {
        let instance = ProviderInstance(
            id: "gemini-oauth",
            label: "Gemini OAuth",
            providerType: .gemini,
            credentialType: .oauth,
            customRequestBody: [
                #"generationConfig.marker = "custom""#,
            ]
        )
        let model = LLMModel(
            id: "gemini-3-flash-preview",
            displayName: "Gemini",
            provider: "Google",
            supportsReasoning: true
        )
        let entry = ModelEntry(
            providerInstanceId: instance.id,
            model: model
        )
        let provider = GeminiProvider(
            oauthTokenProvider: { "token" },
            model: model
        )
        provider.gcpProjectID = "project"
        provider.requestCustomization = RequestCustomization(
            provider: instance,
            modelEntry: entry
        )
        var headers = ["Authorization": "Bearer token"]

        let finalBody = provider.prepareRequestBodyForTransport(
            [
                "contents": [],
                "generationConfig": ["maxOutputTokens": 1024],
            ],
            headers: &headers,
            apiKey: "token"
        )

        XCTAssertNil(finalBody["generationConfig"])
        let request = try XCTUnwrap(finalBody["request"] as? [String: Any])
        let config = try XCTUnwrap(
            request["generationConfig"] as? [String: Any]
        )
        XCTAssertEqual(config["maxOutputTokens"] as? Int, 1024)
        XCTAssertEqual(config["marker"] as? String, "custom")
    }
}

final class AnthropicRequestCustomizationTests: XCTestCase {

    func testRequestBodyPatcher_appliesAllLayersAfterDefaults_BitsUT() throws {
        let provider = ProviderInstance(
            id: "anthropic-provider",
            label: "Anthropic",
            providerType: .anthropic,
            credentialType: .apiKey,
            customRequestHeaders: [
                #"X-Layer = "provider""#,
                "X-Key = {{ provider.apiKey }}",
            ],
            customRequestBody: [
                #"config = {provider: true, shared: "provider"}"#,
                "removeMe = delete()",
            ]
        )
        let control = RequestBodyControl(
            id: "anthropic-control",
            title: "Control",
            kind: .toggle,
            defaultIsActive: true,
            payloadExpressions: [#"body.config.shared = "control""#]
        )
        let entry = ModelEntry(
            uuid: "anthropic-entry",
            providerInstanceId: provider.id,
            model: LLMModel(
                id: "claude-test",
                displayName: "Claude Test",
                provider: "Anthropic",
                supportsReasoning: true
            ),
            overrides: ModelOverrides(
                customRequestHeaders: [#"X-Layer = "model""#],
                customRequestBody: [#"config.model = true"#],
                requestBodyControls: [control]
            )
        )
        let customization = RequestCustomization(
            provider: provider,
            modelEntry: entry
        )
        let request = try makeRequest(
            body: [
                "model": "claude-test",
                "removeMe": "default",
                "config": [
                    "default": true,
                    "shared": "default",
                ],
            ],
            headers: ["X-Layer": "default"]
        )

        register(
            customization,
            apiKey: "secret",
            thinkingDefinitionId: nil,
            for: request
        )
        let overrides = RequestBodyPatcher.applyRequestCustomization(into: request)

        let body = try requestBody(request)
        let config = try XCTUnwrap(body["config"] as? [String: Any])
        XCTAssertEqual(config["default"] as? Bool, true)
        XCTAssertEqual(config["provider"] as? Bool, true)
        XCTAssertEqual(config["model"] as? Bool, true)
        XCTAssertEqual(config["shared"] as? String, "control")
        XCTAssertNil(body["removeMe"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Layer"), "model")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Key"), "secret")
        XCTAssertEqual(overrides["X-Layer"], "model")
        XCTAssertEqual(overrides["X-Key"], "secret")
        XCTAssertNil(
            request.value(
                forHTTPHeaderField:
                    RequestBodyPatcher.customizationRequestHeader
            )
        )
    }

    func testRequestBodyPatcher_customAuthorizationRemainsFinalAndStateIsOneShot_BitsUT() throws {
        let provider = ProviderInstance(
            id: "anthropic-oauth",
            label: "Anthropic OAuth",
            providerType: .anthropic,
            credentialType: .oauth,
            customRequestHeaders: [
                #"Authorization = "Custom {{ provider.apiKey }}""#,
            ]
        )
        let customization = RequestCustomization(
            provider: provider,
            modelEntry: nil
        )
        let first = try makeRequest(body: ["model": "claude-test"])

        register(
            customization,
            apiKey: "oauth-token",
            thinkingDefinitionId: nil,
            for: first
        )
        let overrides = RequestBodyPatcher.applyRequestCustomization(into: first)
        first.setValue("Bearer refreshed-token", forHTTPHeaderField: "Authorization")
        for (name, value) in overrides {
            first.setValue(value, forHTTPHeaderField: name)
        }

        XCTAssertEqual(
            first.value(forHTTPHeaderField: "Authorization"),
            "Custom oauth-token"
        )

        let second = try makeRequest(body: ["model": "claude-test"])
        XCTAssertTrue(
            RequestBodyPatcher.applyRequestCustomization(into: second).isEmpty
        )
        XCTAssertNil(second.value(forHTTPHeaderField: "Authorization"))
    }

    func testRequestBodyPatcher_isolatesConcurrentSameModelRequestsByID_BitsUT() throws {
        let providerA = ProviderInstance(
            id: "anthropic-a",
            label: "Anthropic A",
            providerType: .anthropic,
            credentialType: .apiKey,
            customRequestBody: [#"marker = "A""#]
        )
        let providerB = ProviderInstance(
            id: "anthropic-b",
            label: "Anthropic B",
            providerType: .anthropic,
            credentialType: .apiKey,
            customRequestBody: [#"marker = "B""#]
        )
        let customizationA = RequestCustomization(
            provider: providerA,
            modelEntry: makeEntry(provider: providerA, modelID: "same-model")
        )
        let customizationB = RequestCustomization(
            provider: providerB,
            modelEntry: makeEntry(provider: providerB, modelID: "same-model")
        )
        let requestA = try makeRequest(body: ["model": "same-model"])
        let requestB = try makeRequest(body: ["model": "same-model"])

        register(
            customizationA,
            apiKey: "key-a",
            thinkingDefinitionId: "low",
            for: requestA
        )
        register(
            customizationB,
            apiKey: "key-b",
            thinkingDefinitionId: "high",
            for: requestB
        )
        RequestBodyPatcher.applyRequestCustomization(into: requestB)
        RequestBodyPatcher.applyRequestCustomization(into: requestA)

        XCTAssertEqual(try requestBody(requestA)["marker"] as? String, "A")
        XCTAssertEqual(try requestBody(requestB)["marker"] as? String, "B")
    }

    // delete() on a header the request already carries as a preset default must
    // clear it off the real URLRequest, not just drop it from the working dict.
    // URLRequest header patching is set-only, so a vanished key would otherwise
    // leave the default in place. The other providers (Gemini/OpenAI/Antigravity)
    // run the byte-identical set-only loop; this covers that shared behavior.
    func testRequestBodyPatcher_headerDeleteClearsPresetDefaultOnRequest_BitsUT() throws {
        let provider = ProviderInstance(
            id: "anthropic-delete-header",
            label: "Anthropic",
            providerType: .anthropic,
            credentialType: .apiKey,
            customRequestHeaders: [
                "X-Default = delete()",
                #"X-Keep = "kept""#,
            ]
        )
        let customization = RequestCustomization(
            provider: provider,
            modelEntry: makeEntry(provider: provider, modelID: "claude-test")
        )
        let request = try makeRequest(
            body: ["model": "claude-test"],
            headers: [
                "X-Default": "preset",
                "X-Untouched": "stays",
            ]
        )

        register(
            customization,
            apiKey: "secret",
            thinkingDefinitionId: nil,
            for: request
        )
        let overrides = RequestBodyPatcher.applyRequestCustomization(into: request)

        // Deleted preset default is gone from the actual request…
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Default"))
        // …and stays out of overrides so the token-fetch re-apply loop won't re-add it.
        XCTAssertNil(overrides["X-Default"])
        // Non-customized presets survive, and new headers apply.
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Untouched"), "stays")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Keep"), "kept")
    }

    func testRequestBodyPatcher_preservesThinkingLevelTaskContext_BitsUT() throws {
        let provider = ProviderInstance(
            id: "anthropic-thinking",
            label: "Anthropic Thinking",
            providerType: .anthropic,
            credentialType: .apiKey
        )
        let control = RequestBodyControl(
            id: "thinking",
            title: "Thinking",
            kind: .optionGroup,
            semanticKind: .thinkingBudget,
            options: [
                RequestBodyControlOption(
                    id: "low-option",
                    thinkingDefinitionId: "low",
                    title: "Low",
                    payloadExpressions: [#"body.effort = "low""#]
                ),
                RequestBodyControlOption(
                    id: "high-option",
                    thinkingDefinitionId: "high",
                    title: "High",
                    payloadExpressions: [#"body.effort = "high""#]
                ),
            ]
        )
        let entry = ModelEntry(
            uuid: "anthropic-thinking-entry",
            providerInstanceId: provider.id,
            model: LLMModel(
                id: "same-model",
                displayName: "Same Model",
                provider: "Anthropic",
                supportsReasoning: true
            ),
            overrides: ModelOverrides(requestBodyControls: [control])
        )
        let customization = RequestCustomization(
            provider: provider,
            modelEntry: entry
        )
        let request = try makeRequest(body: ["model": "same-model"])
        register(
            customization,
            apiKey: "key",
            thinkingDefinitionId: "high",
            for: request
        )

        RequestBodyPatcher.applyRequestCustomization(into: request)

        XCTAssertEqual(try requestBody(request)["effort"] as? String, "high")
    }

    func testRequestBodyPatcher_preservesConversationStateFlag_BitsUT() throws {
        let provider = ProviderInstance(
            id: "anthropic-runtime",
            label: "Anthropic Runtime",
            providerType: .anthropic,
            credentialType: .apiKey
        )
        let control = RequestBodyControl(
            id: "web-search",
            title: "Web Search",
            kind: .toggle,
            defaultIsActive: false,
            payloadExpressions: [
                "body.web_search = true",
            ]
        )
        let entry = ModelEntry(
            uuid: "anthropic-runtime-entry",
            providerInstanceId: provider.id,
            model: LLMModel(
                id: "same-model",
                displayName: "Same Model",
                provider: "Anthropic"
            ),
            overrides: ModelOverrides(
                requestBodyControls: [control]
            )
        )
        let sessionKey = "session-\(UUID().uuidString)"
        let defaultsKey =
            RequestBodyControlRuntimeStore.storageKey(
                forSessionKey: sessionKey
            )
        defer {
            UserDefaults.standard.removeObject(
                forKey: defaultsKey
            )
        }
        RequestBodyControlRuntimeStore.save(
            RequestBodyControlState(
                toggleValuesByControlID: [
                    control.id: true,
                ]
            ),
            forSessionKey: sessionKey,
            modelKey: entry.id,
            controls: [control]
        )
        let customization = RequestCustomization(
            provider: provider,
            modelEntry: entry
        )
        let chatRequest = try makeRequest(
            body: ["model": "same-model"]
        )
        let internalRequest = try makeRequest(
            body: ["model": "same-model"]
        )
        let chatID =
            RequestBodyPatcher
                .registerRequestCustomization(
                    customization,
                    apiKey: "key",
                    thinkingDefinitionId: nil,
                    sessionId: sessionKey,
                    usesConversationRequestControlState:
                        true
                )
        let internalID =
            RequestBodyPatcher
                .registerRequestCustomization(
                    customization,
                    apiKey: "key",
                    thinkingDefinitionId: nil,
                    sessionId: sessionKey,
                    usesConversationRequestControlState:
                        false
                )
        chatRequest.setValue(
            chatID,
            forHTTPHeaderField:
                RequestBodyPatcher
                    .customizationRequestHeader
        )
        internalRequest.setValue(
            internalID,
            forHTTPHeaderField:
                RequestBodyPatcher
                    .customizationRequestHeader
        )

        RequestBodyPatcher.applyRequestCustomization(
            into: chatRequest
        )
        RequestBodyPatcher.applyRequestCustomization(
            into: internalRequest
        )

        XCTAssertEqual(
            try requestBody(chatRequest)["web_search"]
                as? Bool,
            true
        )
        XCTAssertNil(
            try requestBody(internalRequest)["web_search"]
        )
    }

    func testRequestBodyPatcher_discardsMissingBodyAndUnknownRequestIDs_BitsUT() throws {
        let provider = ProviderInstance(
            id: "anthropic-discard",
            label: "Anthropic Discard",
            providerType: .anthropic,
            credentialType: .apiKey,
            customRequestBody: [#"marker = "applied""#]
        )
        let customization = RequestCustomization(
            provider: provider,
            modelEntry: makeEntry(provider: provider, modelID: "discard-model")
        )
        let requestWithoutBody = NSMutableURLRequest(
            url: try XCTUnwrap(URL(string: "https://api.anthropic.com/v1/messages"))
        )
        let requestID = RequestBodyPatcher.registerRequestCustomization(
            customization,
            apiKey: "key",
            thinkingDefinitionId: "high"
        )
        requestWithoutBody.setValue(
            requestID,
            forHTTPHeaderField: RequestBodyPatcher.customizationRequestHeader
        )

        XCTAssertTrue(
            RequestBodyPatcher.applyRequestCustomization(into: requestWithoutBody)
                .isEmpty
        )
        XCTAssertNil(
            requestWithoutBody.value(
                forHTTPHeaderField: RequestBodyPatcher.customizationRequestHeader
            )
        )

        let requestAfterDiscard = try makeRequest(body: ["model": "discard-model"])
        requestAfterDiscard.setValue(
            requestID,
            forHTTPHeaderField: RequestBodyPatcher.customizationRequestHeader
        )
        XCTAssertTrue(
            RequestBodyPatcher.applyRequestCustomization(into: requestAfterDiscard)
                .isEmpty
        )
        XCTAssertNil(try requestBody(requestAfterDiscard)["marker"])

        let unknownRequest = try makeRequest(body: ["model": "discard-model"])
        unknownRequest.setValue(
            UUID().uuidString,
            forHTTPHeaderField: RequestBodyPatcher.customizationRequestHeader
        )
        XCTAssertTrue(
            RequestBodyPatcher.applyRequestCustomization(into: unknownRequest)
                .isEmpty
        )
        XCTAssertNil(
            unknownRequest.value(
                forHTTPHeaderField: RequestBodyPatcher.customizationRequestHeader
            )
        )
        RequestBodyPatcher.discardRequestCustomization(id: nil)
    }

    func testHTTPClientPool_reusesReleasedLaneWithoutSharingActiveLane_BitsUT() {
        let pool = AnthropicHTTPClientPool { _ in
            URLSessionHTTPClientAdapter(
                urlSession: .shared
            )
        }

        let first = pool.acquire()
        let concurrent = pool.acquire()
        XCTAssertNotEqual(first.id, concurrent.id)

        pool.release(first)
        let reused = pool.acquire()
        XCTAssertEqual(reused.id, first.id)

        pool.release(concurrent)
        pool.release(reused)
    }

    func testRequestBodyPatcher_reusesExplicitLaneIDAfterConsumption_BitsUT() throws {
        let provider = ProviderInstance(
            id: "anthropic-lane",
            label: "Anthropic Lane",
            providerType: .anthropic,
            credentialType: .apiKey,
            customRequestBody: [
                #"marker = "applied""#,
                #"metadata.session_id = "{{ session.id }}""#,
            ]
        )
        let customization = RequestCustomization(
            provider: provider,
            modelEntry: nil
        )
        let laneID = "reusable-lane"

        for index in 0..<2 {
            let sessionID = "session-\(index)"
            let id =
                RequestBodyPatcher
                    .registerRequestCustomization(
                        customization,
                        apiKey: "key",
                        thinkingDefinitionId: nil,
                        sessionId: sessionID,
                        id: laneID
                    )
            XCTAssertEqual(id, laneID)
            let request = try makeRequest(
                body: ["model": "claude-test"]
            )
            request.setValue(
                id,
                forHTTPHeaderField:
                    RequestBodyPatcher
                        .customizationRequestHeader
            )

            RequestBodyPatcher
                .applyRequestCustomization(
                    into: request
                )

            XCTAssertEqual(
                try requestBody(request)["marker"]
                    as? String,
                "applied"
            )
            let metadata = try XCTUnwrap(
                try requestBody(request)["metadata"]
                    as? [String: Any]
            )
            XCTAssertEqual(
                metadata["session_id"] as? String,
                sessionID
            )
        }
    }

    private func register(
        _ customization: RequestCustomization,
        apiKey: String?,
        thinkingDefinitionId: String?,
        for request: NSMutableURLRequest
    ) {
        let id = RequestBodyPatcher.registerRequestCustomization(
            customization,
            apiKey: apiKey,
            thinkingDefinitionId:
                thinkingDefinitionId
        )
        request.setValue(
            id,
            forHTTPHeaderField: RequestBodyPatcher.customizationRequestHeader
        )
    }

    private func makeRequest(
        body: [String: Any],
        headers: [String: String] = [:]
    ) throws -> NSMutableURLRequest {
        let request = NSMutableURLRequest(
            url: try XCTUnwrap(URL(string: "https://api.anthropic.com/v1/messages"))
        )
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private func requestBody(
        _ request: NSMutableURLRequest
    ) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func makeEntry(
        provider: ProviderInstance,
        modelID: String
    ) -> ModelEntry {
        ModelEntry(
            uuid: "uuid-\(modelID)",
            providerInstanceId: provider.id,
            model: LLMModel(
                id: modelID,
                displayName: modelID,
                provider: "Anthropic",
                supportsReasoning: true
            )
        )
    }
}

final class OpenAIDefaultThinkingTests: XCTestCase {

    func testApplyDefaultChatThinking_handlesProtocolAndLevelBranches_BitsUT() {
        let model = LLMModel(
            id: "future-model",
            displayName: "Future Model",
            provider: "OpenAI",
            supportsReasoning: true
        )

        var offBody: [String: Any] = [:]
        let standard = OpenAIProvider(apiKey: "key", model: model)
        OpenAIAgentProvider.applyDefaultChatThinking(
            into: &offBody,
            provider: standard,
            model: model,
            level: .off
        )
        XCTAssertEqual(offBody["reasoning_effort"] as? String, "none")

        var openRouterBody: [String: Any] = [:]
        let openRouter = OpenAIProvider(apiKey: "key", model: model)
        openRouter.useOpenRouterCompat = true
        OpenAIAgentProvider.applyDefaultChatThinking(
            into: &openRouterBody,
            provider: openRouter,
            model: model,
            level: .high
        )
        XCTAssertEqual(
            (openRouterBody["reasoning"] as? [String: Any])?["effort"] as? String,
            "high"
        )

        var ultraBody: [String: Any] = [:]
        OpenAIAgentProvider.applyDefaultChatThinking(
            into: &ultraBody,
            provider: standard,
            model: model,
            level: .ultra
        )
        XCTAssertEqual(ultraBody["reasoning_effort"] as? String, "max")
    }

    func testApplyDefaultChatThinking_skipsUnsupportedModelAndCustomThinkingControl_BitsUT() {
        let unsupportedModel = LLMModel(
            id: "plain-model",
            displayName: "Plain Model",
            provider: "OpenAI",
            supportsReasoning: false
        )
        let unsupportedProvider = OpenAIProvider(apiKey: "key", model: unsupportedModel)
        var unsupportedBody: [String: Any] = [:]
        OpenAIAgentProvider.applyDefaultChatThinking(
            into: &unsupportedBody,
            provider: unsupportedProvider,
            model: unsupportedModel,
            level: .high
        )
        XCTAssertTrue(unsupportedBody.isEmpty)

        let reasoningModel = LLMModel(
            id: "reasoning-model",
            displayName: "Reasoning Model",
            provider: "OpenAI",
            supportsReasoning: true
        )
        let providerInstance = ProviderInstance(
            id: "custom-provider",
            label: "Custom Provider",
            providerType: .openAI,
            credentialType: .apiKey
        )
        let control = RequestBodyControl(
            id: "thinking-control",
            title: "Custom Thinking",
            kind: .optionGroup,
            semanticKind: .thinkingBudget
        )
        let entry = ModelEntry(
            providerInstanceId: providerInstance.id,
            model: reasoningModel,
            overrides: ModelOverrides(requestBodyControls: [control])
        )
        let customProvider = OpenAIProvider(apiKey: "key", model: reasoningModel)
        customProvider.requestCustomization = RequestCustomization(
            provider: providerInstance,
            modelEntry: entry
        )
        var customBody: [String: Any] = [:]

        OpenAIAgentProvider.applyDefaultChatThinking(
            into: &customBody,
            provider: customProvider,
            model: reasoningModel,
            level: .high
        )

        XCTAssertTrue(customBody.isEmpty)

        let disabledControl = RequestBodyControl(
            id: "disabled-thinking-control",
            title: "Disabled Thinking",
            kind: .optionGroup,
            semanticKind: .thinkingBudget,
            isEnabled: false
        )
        let disabledEntry = ModelEntry(
            providerInstanceId: providerInstance.id,
            model: reasoningModel,
            overrides: ModelOverrides(
                requestBodyControls: [disabledControl]
            )
        )
        let disabledProvider = OpenAIProvider(
            apiKey: "key",
            model: reasoningModel
        )
        disabledProvider.requestCustomization = RequestCustomization(
            provider: providerInstance,
            modelEntry: disabledEntry
        )
        var disabledBody: [String: Any] = [:]

        OpenAIAgentProvider.applyDefaultChatThinking(
            into: &disabledBody,
            provider: disabledProvider,
            model: reasoningModel,
            level: .high
        )

        XCTAssertEqual(disabledBody["reasoning_effort"] as? String, "high")
    }

    func testApplyDefaultChatThinking_preservesProviderScopedUserRules_BitsUT() {
        let instanceID = "thinking-rules-\(UUID().uuidString)"
        ThinkingRuleCache.shared.set(
            [
                ThinkingRule(
                    kind: .custom,
                    scope: .allModels,
                    wireFormat: .customPath(
                        path: "custom_thinking_effort",
                        values: [.high: "provider-rule"],
                        offValue: nil
                    ),
                    label: "provider-rule"
                ),
            ],
            for: instanceID
        )
        defer { ThinkingRuleCache.shared.set([], for: instanceID) }

        let model = LLMModel(
            id: "mistral-large-latest",
            displayName: "Mistral",
            provider: "OpenAI",
            supportsReasoning: true
        )
        let provider = OpenAIProvider(apiKey: "key", model: model)
        provider.providerInstanceId = instanceID
        provider.isMistral = true
        var body: [String: Any] = [:]

        OpenAIAgentProvider.applyDefaultChatThinking(
            into: &body,
            provider: provider,
            model: model,
            level: .high
        )

        XCTAssertEqual(body["custom_thinking_effort"] as? String, "provider-rule")
        XCTAssertNil(body["reasoning_effort"])
    }

    func testApplyDefaultResponsesThinking_preservesCodexOffFallbackAndSemanticOverride_BitsUT() {
        let model = LLMModel(
            id: "gpt-5-test",
            displayName: "Test Model",
            provider: "OpenAI",
            supportsReasoning: true
        )
        let defaultProvider = OpenAIProvider(apiKey: "key", model: model)
        var defaultBody: [String: Any] = [:]

        let requestsEncryptedReasoning =
            OpenAIAgentProvider.applyDefaultResponsesThinking(
                into: &defaultBody,
                provider: defaultProvider,
                model: model,
                level: .off,
                isCodexOAuth: true
            )

        XCTAssertTrue(requestsEncryptedReasoning)
        XCTAssertEqual(
            (defaultBody["reasoning"] as? [String: Any])?["effort"] as? String,
            "low"
        )

        let instance = ProviderInstance(
            id: "custom-provider",
            label: "Custom Provider",
            providerType: .openAIResponses,
            credentialType: .oauth
        )
        let control = RequestBodyControl(
            id: "thinking-control",
            title: "Custom Thinking",
            kind: .optionGroup,
            semanticKind: .thinkingBudget
        )
        let entry = ModelEntry(
            providerInstanceId: instance.id,
            model: model,
            overrides: ModelOverrides(requestBodyControls: [control])
        )
        let customProvider = OpenAIProvider(apiKey: "key", model: model)
        customProvider.requestCustomization = RequestCustomization(
            provider: instance,
            modelEntry: entry
        )
        var customBody: [String: Any] = [:]

        let customRequestsEncryptedReasoning =
            OpenAIAgentProvider.applyDefaultResponsesThinking(
                into: &customBody,
                provider: customProvider,
                model: model,
                level: .off,
                isCodexOAuth: true
            )

        XCTAssertFalse(customRequestsEncryptedReasoning)
        XCTAssertNil(customBody["reasoning"])
    }

    @MainActor
    func testFactory_preservesUpstreamThinkingRuleInstanceScope_BitsUT() {
        let model = LLMModel(
            id: "model",
            displayName: "Model",
            provider: "OpenAI"
        )
        let chatInstance = ProviderInstance(
            id: "openai-chat-\(UUID().uuidString)",
            label: "OpenAI Chat",
            providerType: .openAI,
            credentialType: .apiKey
        )
        let chatEntry = ModelEntry(
            providerInstanceId: chatInstance.id,
            model: model
        )
        let chatProvider = LLMProviderFactory.makeOpenAIProvider(
            instance: chatInstance,
            entry: chatEntry
        )

        XCTAssertEqual(
            chatProvider.providerInstanceId,
            chatInstance.id
        )
        XCTAssertNotNil(chatProvider.requestCustomization)

        let codexInstance = ProviderInstance(
            id: "codex-\(UUID().uuidString)",
            label: "Codex",
            providerType: .openAI,
            credentialType: .oauth
        )
        let codexEntry = ModelEntry(
            providerInstanceId: codexInstance.id,
            model: model
        )
        let codexProvider = LLMProviderFactory.makeOpenAIProvider(
            instance: codexInstance,
            entry: codexEntry
        )

        XCTAssertNil(codexProvider.providerInstanceId)
        XCTAssertNotNil(codexProvider.requestCustomization)
    }
}
