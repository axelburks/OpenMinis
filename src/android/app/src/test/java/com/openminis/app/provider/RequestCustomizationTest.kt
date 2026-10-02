package com.openminis.app.provider

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import com.openminis.app.data.model.LLMModel
import com.openminis.app.data.model.ModelEntry
import com.openminis.app.data.model.ModelOverrides
import com.openminis.app.data.model.ProviderCredential
import com.openminis.app.data.model.ProviderInstance
import com.openminis.app.data.model.ProviderType
import com.openminis.app.data.model.RequestBodyControl
import com.openminis.app.data.model.RequestBodyControlOption
import com.openminis.app.data.model.RequestBodyControlState
import com.openminis.app.data.model.ThinkingLevel
import com.openminis.app.data.model.ThinkingLevelDefinition
import com.openminis.app.ui.settings.normalizedExpressionEditorText
import com.openminis.app.ui.settings.finalizedExpressionEditorText
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RequestCustomizationTest {

    @Test
    fun testApply_usesProviderThenModelThenControlPriority_BitsUT() {
        val provider = provider(
            body = listOf(
                """metadata = {source: "provider", keep: true}""",
                """priority = "provider"""",
            ),
        )
        val entry = entry(
            headers = listOf("""X-Source = {{ body.metadata.source }}"""),
            body = listOf(
                """metadata = {source: "model"}""",
                """priority = "model"""",
            ),
            controls = listOf(
                RequestBodyControl(
                    id = "control",
                    title = "Priority",
                    kind = RequestBodyControl.Kind.toggle,
                    defaultIsActive = true,
                    payloadExpressions = listOf("""body.priority = "control""""),
                ),
            ),
        )
        val body = JSONObject("""{"metadata":{"initial":true}}""")
        val headers = linkedMapOf<String, String>()

        RequestCustomization(provider, entry).apply(body, headers, "secret")

        assertEquals("provider", headers["X-Source"])
        assertEquals("control", body.getString("priority"))
        assertEquals(true, body.getJSONObject("metadata").getBoolean("initial"))
        assertEquals(true, body.getJSONObject("metadata").getBoolean("keep"))
        assertEquals("model", body.getJSONObject("metadata").getString("source"))
    }

    @Test
    fun testApply_withoutControlsKeepsProviderAndModelLayers_BitsUT() {
        val provider = provider(
            headers = listOf("""X-Provider = "provider""""),
            body = listOf("metadata.provider = true"),
        )
        val control = RequestBodyControl(
            id = "conversation-only",
            title = "Conversation Only",
            kind = RequestBodyControl.Kind.toggle,
            defaultIsActive = true,
            payloadExpressions = listOf(
                "body.control_applied = true",
                """headers.X-Control = "control"""",
            ),
        )
        val entry = entry(
            headers = listOf("""X-Model = "model""""),
            body = listOf("metadata.model = true"),
            controls = listOf(control),
        )
        val body = JSONObject()
        val headers = linkedMapOf<String, String>()

        RequestCustomization(provider, entry).apply(
            body,
            headers,
            "secret",
            includeControls = false,
        )

        assertEquals("provider", headers["X-Provider"])
        assertEquals("model", headers["X-Model"])
        assertFalse(headers.containsKey("X-Control"))
        assertTrue(body.getJSONObject("metadata").getBoolean("provider"))
        assertTrue(body.getJSONObject("metadata").getBoolean("model"))
        assertFalse(body.has("control_applied"))
    }

    @Test
    fun testApply_headerNamesAndReferencesAreCaseInsensitive_BitsUT() {
        val provider = provider(
            headers = listOf("""authorization = "custom-token""""),
        )
        val entry = entry(
            headers = listOf("""X-Auth-Copy = {{ headers.Authorization }}"""),
        )
        val headers = linkedMapOf("Authorization" to "default-token")

        RequestCustomization(provider, entry).apply(JSONObject(), headers, "secret")

        val matchingHeaders = headers.entries.filter {
            it.key.equals("authorization", ignoreCase = true)
        }
        assertEquals(1, matchingHeaders.size)
        assertEquals("custom-token", matchingHeaders.single().value)
        assertEquals("custom-token", headers["X-Auth-Copy"])
    }

    @Test
    fun testApply_headerDeleteRemovesValueAndInvalidLineIsSkipped_BitsUT() {
        val headers = linkedMapOf("X-Remove" to "old")
        RequestCustomization(
            provider(
                headers = listOf(
                    "x-remove = delete()",
                    "X-Null = null",
                    """X-After = "kept"""",
                ),
            ),
            entry(),
        ).apply(JSONObject(), headers, "secret")

        assertFalse(headers.containsKey("X-Remove"))
        assertFalse(headers.containsKey("X-Null"))
        assertEquals("kept", headers["X-After"])
    }

    @Test
    fun testDisablesBuiltInThinkingInjection_usesEnabledSemanticControlOnly_BitsUT() {
        val ordinary = RequestBodyControl(
            id = "ordinary",
            title = "Metadata",
            kind = RequestBodyControl.Kind.toggle,
            defaultIsActive = true,
            payloadExpressions = listOf("body.metadata.reasoning_note = true"),
        )
        val disabledThinking = RequestBodyControl(
            id = "thinking",
            title = "Thinking",
            kind = RequestBodyControl.Kind.optionGroup,
            semanticKind = RequestBodyControl.SemanticKind.thinkingBudget,
            isEnabled = false,
            options = listOf(
                RequestBodyControlOption(
                    id = "high",
                    thinkingDefinitionId = "high",
                    title = "High",
                ),
            ),
        )
        val enabledThinking = disabledThinking.copy(isEnabled = true)

        assertFalse(
            RequestCustomization(provider(), entry(controls = listOf(ordinary)))
                .disablesBuiltInThinkingInjection,
        )
        assertFalse(
            RequestCustomization(provider(), entry(controls = listOf(disabledThinking)))
                .disablesBuiltInThinkingInjection,
        )
        assertTrue(
            RequestCustomization(provider(), entry(controls = listOf(enabledThinking)))
                .disablesBuiltInThinkingInjection,
        )
    }

    @Test
    fun testThinkingTemplate_usesActualResponsesRouting_BitsUT() {
        fun highExpression(instance: ProviderInstance): String =
            RequestBodyControlDefaults.thinkingOptionGroup(instance)
                .options.first {
                    it.thinkingDefinitionId == "high"
                }.payloadExpressions.single()

        val explicitResponses = provider().copy(
            providerType = ProviderType.openAIResponses,
        )
        val toggledResponses = provider().copy(
            useResponsesAPI = true,
        )
        val codexOAuth = provider().copy(
            credentialType = ProviderCredential.oauth,
            customBaseURL = null,
        )
        val chatCompletions = provider().copy(
            customBaseURL = "https://example.com/v1",
        )

        for (instance in listOf(explicitResponses, toggledResponses, codexOAuth)) {
            assertEquals(
                """body.reasoning = {effort: "high", summary: "auto"}""",
                highExpression(instance),
            )
        }
        assertEquals(
            """body.reasoning_effort = "high"""",
            highExpression(chatCompletions),
        )
        assertEquals(
            """body.reasoning = {effort: "high", summary: "auto"}""",
            RequestBodyControlDefaults
                .thinkingExpressions(
                    codexOAuth,
                    ThinkingLevel.HIGH,
                ).single(),
        )
        assertTrue(
            RequestBodyControlDefaults.thinkingExpressions(
                codexOAuth,
                ThinkingLevelDefinition(
                    definitionId = "custom-extreme",
                    levelId = "extreme",
                    title = "Extreme",
                    rank = 100,
                ),
            ).isEmpty(),
        )
    }

    @Test
    fun testInternalTask_keepsNullThinkingSoControlDefaultWins_BitsUT() {
        val off = RequestBodyControlOption(
            id = "off-option",
            thinkingDefinitionId = "off",
            title = "Off",
            payloadExpressions =
                listOf("""body.effort = "off""""),
        )
        val high = RequestBodyControlOption(
            id = "high-option",
            thinkingDefinitionId = "high",
            title = "High",
            payloadExpressions =
                listOf("""body.effort = "high""""),
        )
        val control = RequestBodyControl(
            id = "thinking",
            title = "Thinking",
            kind = RequestBodyControl.Kind.optionGroup,
            semanticKind =
                RequestBodyControl.SemanticKind.thinkingBudget,
            defaultOptionID = high.id,
            options = listOf(off, high),
        )
        val customization = RequestCustomization(
            provider = provider(),
            modelEntry = entry(controls = listOf(control)),
            usesConversationRequestControlState = false,
        )
        val body = JSONObject()

        customization.thinkingDefinitionId =
            customization.thinkingDefinitionIdForRequest(
                explicitDefinitionId = null,
                thinkingLevel = ThinkingLevel.OFF,
            )
        customization.apply(body, linkedMapOf(), null)

        assertNull(customization.thinkingDefinitionId)
        assertEquals("high", body.getString("effort"))
    }

    @Test
    fun testApply_templatesResolveMultipleValuesAndSkipAnyMissingValue_BitsUT() {
        val provider = provider(
            headers = listOf(
                "X-Composite = {{ model.id }}-{{ session.id }}",
                "X-Missing = {{ model.id }}-{{ body.missing }}",
            ),
        )
        val headers = linkedMapOf<String, String>()

        RequestCustomization(
            provider = provider,
            modelEntry = entry(),
            sessionId = "session-123",
        ).apply(JSONObject(), headers, apiKey = null)

        assertEquals("test-model-session-123", headers["X-Composite"])
        assertFalse(headers.containsKey("X-Missing"))
    }

    @Test
    fun testApply_missingOptionalContextSkipsWholeExpression_BitsUT() {
        val provider = provider(
            headers = listOf("X-Optional = {{ provider.apiKey }}"),
            body = listOf("metadata.session = {{ session.id }}"),
        )
        val body = JSONObject()
        val headers = linkedMapOf<String, String>()

        RequestCustomization(provider, entry()).apply(body, headers, apiKey = null)

        assertFalse(headers.containsKey("X-Optional"))
        assertFalse(body.has("metadata"))
    }

    @Test
    fun testApply_sameLayerExpressionsCanReferenceEarlierLines_BitsUT() {
        val provider = provider(
            body = listOf(
                """metadata.source = "provider"""",
                """metadata.copy = {{ body.metadata.source }}""",
            ),
        )
        val body = JSONObject()

        RequestCustomization(provider, entry()).apply(body, linkedMapOf(), "secret")

        assertEquals("provider", body.getJSONObject("metadata").getString("copy"))
    }

    @Test
    fun testApply_appendAndConcatResolveBodyArraysAndNestedFunctions_BitsUT() {
        val provider = provider(
            body = listOf(
                """tools = append(body.tools, {type: "web_search"})""",
                """items = concat(body.items, body.moreItems, [4])""",
            ),
        )
        val body = JSONObject(
            """
            {
              "tools": [{"type": "function"}],
              "items": [1],
              "moreItems": [2, 3]
            }
            """.trimIndent(),
        )

        RequestCustomization(provider, entry()).apply(body, linkedMapOf(), "secret")

        val tools = body.getJSONArray("tools")
        assertEquals(2, tools.length())
        assertEquals("function", tools.getJSONObject(0).getString("type"))
        assertEquals("web_search", tools.getJSONObject(1).getString("type"))
        assertEquals(listOf(1, 2, 3, 4), body.getJSONArray("items").toIntList())
    }

    @Test
    fun testApply_arrayFunctionsHaveDistinctSemantics_BitsUT() {
        val provider = provider(
            body = listOf(
                "nested = append(body.numbers, [2, 3])",
                "flat = concat(body.numbers, [2, 3])",
                """updated = update(body.tools, {type: "function"}, {a: 2, b: {mode: "strict"}})""",
                """inserted = insert(body.tags, 1, "middle")""",
                """insertedLast = insert(body.tags, -1, "last")""",
                "removedAt = remove_at(body.tags, 1)",
                "removedLast = remove_at(body.tags, -1)",
            ),
        )
        val body = JSONObject(
            """
            {
              "numbers": [1],
              "tools": [
                {"type": "function", "a": 1},
                {"type": "web_search"}
              ],
              "tags": ["first", "second", "third"]
            }
            """.trimIndent(),
        )

        RequestCustomization(provider, entry()).apply(body, linkedMapOf(), "secret")

        val nested = body.getJSONArray("nested")
        assertEquals(1, nested.getInt(0))
        assertEquals(listOf(2, 3), nested.getJSONArray(1).toIntList())
        assertEquals(listOf(1, 2, 3), body.getJSONArray("flat").toIntList())
        val updated = body.getJSONArray("updated")
        assertEquals(2, updated.getJSONObject(0).getInt("a"))
        assertEquals(
            "strict",
            updated.getJSONObject(0).getJSONObject("b").getString("mode"),
        )
        assertFalse(updated.getJSONObject(1).has("a"))
        assertEquals(
            listOf("first", "middle", "second", "third"),
            body.getJSONArray("inserted").toStringList(),
        )
        assertEquals(
            listOf("first", "second", "third", "last"),
            body.getJSONArray("insertedLast").toStringList(),
        )
        assertEquals(
            listOf("first", "third"),
            body.getJSONArray("removedAt").toStringList(),
        )
        assertEquals(
            listOf("first", "second"),
            body.getJSONArray("removedLast").toStringList(),
        )
    }

    @Test
    fun testApply_removeFiltersScalarsAndMatchingObjects_BitsUT() {
        val provider = provider(
            body = listOf(
                """tools = remove(body.tools, {type: "web_search"})""",
                """tags = remove(body.tags, ["old", "unused"])""",
                """alternatives = remove(body.mixed, {type: "legacy"}, {disabled: true}, "obsolete")""",
                """allFields = remove(body.objects, {type: "legacy", disabled: true})""",
            ),
        )
        val body = JSONObject(
            """
            {
              "tools": [
                {"type": "function", "name": "existing"},
                {"type": "web_search", "scope": "wide"}
              ],
              "tags": ["keep", "old", "unused"],
              "mixed": [
                {"type": "legacy", "disabled": false},
                {"type": "current", "disabled": true},
                {"type": "current", "disabled": false},
                "obsolete",
                "keep"
              ],
              "objects": [
                {"type": "legacy", "disabled": false},
                {"type": "legacy", "disabled": true}
              ]
            }
            """.trimIndent(),
        )

        RequestCustomization(provider, entry()).apply(body, linkedMapOf(), "secret")

        val tools = body.getJSONArray("tools")
        assertEquals(1, tools.length())
        assertEquals("existing", tools.getJSONObject(0).getString("name"))
        assertEquals(listOf("keep"), body.getJSONArray("tags").toStringList())
        val alternatives = body.getJSONArray("alternatives")
        assertEquals(2, alternatives.length())
        assertEquals(
            "current",
            alternatives.getJSONObject(0).getString("type"),
        )
        assertEquals("keep", alternatives.getString(1))
        val allFields = body.getJSONArray("allFields")
        assertEquals(1, allFields.length())
        assertFalse(allFields.getJSONObject(0).getBoolean("disabled"))
    }

    @Test
    fun testApply_preservesNullAndDeleteRemovesFields_BitsUT() {
        val provider = provider(
            body = listOf(
                "metadata.remove = delete()",
                "metadata.todo = null",
                "items = insert(remove_at(body.items, 1), 1, null)",
            ),
        )
        val body = JSONObject(
            """{"metadata":{"keep":true,"remove":"old"},"items":[1,2,3]}""",
        )

        RequestCustomization(provider, entry()).apply(body, linkedMapOf(), "secret")

        assertEquals(true, body.getJSONObject("metadata").getBoolean("keep"))
        assertFalse(body.getJSONObject("metadata").has("remove"))
        assertTrue(body.getJSONObject("metadata").isNull("todo"))
        assertEquals(3, body.getJSONArray("items").length())
        assertEquals(1, body.getJSONArray("items").getInt(0))
        assertTrue(body.getJSONArray("items").isNull(1))
        assertEquals(3, body.getJSONArray("items").getInt(2))
    }

    @Test
    fun testApply_deleteInObjectPatchRemovesField_BitsUT() {
        val provider = provider(
            body = listOf(
                """updated = update(body.items, {id: 1}, {todo: delete(), nullable: null})""",
                """merged = deep_merge(body.config, {todo: delete(), nullable: null})""",
            ),
        )
        val body = JSONObject(
            """{"items":[{"id":1,"todo":"old"}],"config":{"todo":"old"}}""",
        )

        RequestCustomization(provider, entry()).apply(
            body,
            linkedMapOf(),
            "secret",
        )

        val updated = body.getJSONArray("updated").getJSONObject(0)
        assertFalse(updated.has("todo"))
        assertTrue(updated.isNull("nullable"))
        val merged = body.getJSONObject("merged")
        assertFalse(merged.has("todo"))
        assertTrue(merged.isNull("nullable"))
    }

    @Test
    fun testRequestCustomization_exposesStableThinkingDefinitionId_BitsUT() {
        val field = RequestCustomization::class.java.declaredFields.firstOrNull {
            it.name == "thinkingDefinitionId"
        }

        assertNotNull(
            "RequestCustomization must carry the current immutable thinking definition ID",
            field,
        )
    }

    @Test
    fun testExpressionValidator_acceptsSupportedSyntaxAndMissingValues_BitsUT() {
        val headerIssues = RequestExpressionValidator.validate(
            listOf(
                """User-Agent = "Minix/1.0"""",
                """Authorization = "Bearer {{ provider.apiKey }}"""",
                """X-Missing = "{{ body.not_present }}"""",
            ),
            RequestExpressionValidator.Target.HEADER,
        )
        val bodyIssues = RequestExpressionValidator.validate(
            listOf(
                """reasoning = {effort: "high", summary: "auto"}""",
                """tools = append(body.tools, {type: "web_search"})""",
                """filtered = remove(body.tools, {type: "web_search"})""",
                """updated = update(body.tools, {type: "function"}, {strict: true})""",
                """inserted = insert(body.tools, 0, {type: "web_search"})""",
                "removedAt = remove_at(body.tools, 0)",
                "removedLast = remove_at(body.tools, -1)",
                """metadata.id = "{{ uuid() }}"""",
                """metadata.model = "{{ upper(model.id) }}"""",
            ),
            RequestExpressionValidator.Target.BODY,
        )

        assertTrue(headerIssues.isEmpty())
        assertTrue(bodyIssues.isEmpty())
        val controlIssues = RequestExpressionValidator.validate(
            listOf(
                """headers["hha ok"] = "haha ha"""",
                "headers.X-Remove = delete()",
                "body.max_tokens = if(body.priority >= 5, max(body.max_tokens, 4096), min(body.max_tokens, 2048))",
            ),
            RequestExpressionValidator.Target.CONTROL,
        )
        assertTrue(controlIssues.isEmpty())
    }

    @Test
    fun testControlExpressions_writeHeadersBodyAndEvaluateConditions_BitsUT() {
        val control = RequestBodyControl(
            id = "mixed",
            title = "Mixed",
            kind = RequestBodyControl.Kind.toggle,
            defaultIsActive = true,
            payloadExpressions = listOf(
                """headers["hha ok"] = "haha ha"""",
                "headers.X-Remove = delete()",
                "body.max_tokens = if(body.priority >= 5, max(body.max_tokens, 4096), min(body.max_tokens, 2048))",
                "body.is_large = body.max_tokens == 4096",
            ),
        )
        val body = JSONObject(
            """{"priority":7,"max_tokens":1024}""",
        )
        val headers = linkedMapOf(
            "X-Remove" to "old",
        )

        RequestCustomization(
            provider(),
            entry(controls = listOf(control)),
        ).apply(body, headers, null)

        assertEquals("haha ha", headers["hha ok"])
        assertFalse(headers.containsKey("X-Remove"))
        assertEquals(4096, body.getInt("max_tokens"))
        assertTrue(body.getBoolean("is_large"))
    }

    @Test
    fun testControlExpressions_buildStableJSONHeaderWithLazyFallbackAndFiltering_BitsUT() {
        val control = RequestBodyControl(
            id = "extra",
            title = "Extra",
            kind = RequestBodyControl.Kind.toggle,
            defaultIsActive = true,
            payloadExpressions = listOf(
                """
                headers.extra = json({session_id: session.id ?? body.prompt_cache_key ?? md5(body.input.filter(message, message.role == "user")[0].content.filter(part, part.type == "input_text")[0].text)})
                """.trimIndent(),
            ),
        )
        val body = JSONObject(
            """
            {
              "input": [
                {
                  "role": "assistant",
                  "content": [{"type": "output_text", "text": "ignored"}]
                },
                {
                  "role": "user",
                  "content": [
                    {"type": "image", "url": "ignored"},
                    {"type": "input_text", "text": "hello"}
                  ]
                }
              ]
            }
            """.trimIndent(),
        )
        val headers = linkedMapOf<String, String>()

        RequestCustomization(
            provider(),
            entry(controls = listOf(control)),
            sessionId = null,
        ).apply(body, headers, null)

        assertEquals(
            """{"session_id":"5d41402abc4b2a76b9719d911017c592"}""",
            headers["extra"],
        )

        headers.clear()
        val sessionControl = control.copy(
            payloadExpressions = listOf(
                """
                headers.extra = json({session_id: session.id ?? body.prompt_cache_key ?? "fallback"})
                """.trimIndent(),
            ),
        )
        body.put("prompt_cache_key", "body-priority")
        RequestCustomization(
            provider(),
            entry(controls = listOf(sessionControl)),
            sessionId = "session-priority",
        ).apply(body, headers, null)

        assertEquals(
            """{"session_id":"session-priority"}""",
            headers["extra"],
        )

        headers.clear()
        RequestCustomization(
            provider(),
            entry(controls = listOf(sessionControl)),
            sessionId = null,
        ).apply(body, headers, null)
        assertEquals(
            """{"session_id":"body-priority"}""",
            headers["extra"],
        )
    }

    @Test
    fun testApply_filtersLastUserMessageAndClampsComputedLength_BitsUT() {
        val expression =
            """
            max_tokens = clamp(length(body.messages.filter(message, message.role == "user")[-1].content) * 2, 512, 8192)
            """.trimIndent()
        val longBody = JSONObject().put(
            "messages",
            JSONArray()
                .put(JSONObject().put("role", "user").put("content", "short"))
                .put(JSONObject().put("role", "assistant").put("content", "ignored"))
                .put(
                    JSONObject()
                        .put("role", "user")
                        .put("content", "a".repeat(5_000)),
                )
                .put(JSONObject().put("role", "assistant").put("content", "last")),
        )

        RequestCustomization(
            provider(body = listOf(expression)),
            entry(),
        ).apply(longBody, linkedMapOf(), null)
        assertEquals(8_192, longBody.getInt("max_tokens"))

        val shortBody = JSONObject().put(
            "messages",
            JSONArray().put(
                JSONObject().put("role", "user").put("content", "short"),
            ),
        )
        RequestCustomization(
            provider(body = listOf(expression)),
            entry(),
        ).apply(shortBody, linkedMapOf(), null)
        assertEquals(512, shortBody.getInt("max_tokens"))
    }

    @Test
    fun testApply_supportsBooleanArithmeticMapReduceAndAggregates_BitsUT() {
        val provider = provider(
            body = listOf(
                """
                selected = body.items.filter(item, item.enabled && item.value >= 2)
                """.trimIndent(),
                """
                doubled = body.items.filter(item, item.enabled).map(item, item.value * 2)
                """.trimIndent(),
                "total = body.items.map(item, item.value).sum()",
                "average = avg(body.items.map(item, item.value))",
                "reduced = body.items.reduce(acc, item, 0, acc + item.value)",
                "selected_count = body.items.filter(item, item.enabled).count()",
                "normalized = upper(lower(body.label))",
            ),
        )
        val body = JSONObject(
            """
            {
              "items": [
                {"enabled": true, "value": 1},
                {"enabled": false, "value": 2},
                {"enabled": true, "value": 3}
              ],
              "label": "MiNiX"
            }
            """.trimIndent(),
        )

        RequestCustomization(provider, entry())
            .apply(body, linkedMapOf(), null)

        assertEquals(1, body.getJSONArray("selected").length())
        assertEquals(
            listOf(2, 6),
            body.getJSONArray("doubled").toIntList(),
        )
        assertEquals(6, body.getInt("total"))
        assertEquals(2.0, body.getDouble("average"), 0.000_001)
        assertEquals(6, body.getInt("reduced"))
        assertEquals(2, body.getInt("selected_count"))
        assertEquals("MINIX", body.getString("normalized"))
    }

    @Test
    fun testApply_supportsParenthesizedPrecedenceAndURLCoding_BitsUT() {
        val provider = provider(
            body = listOf(
                "matched = body.c > 30 && (body.a > 10 || body.b <= 20)",
                """encoded = url_encode("a b+c/中文?")""",
                """decoded = url_decode("a%20b%2Bc%2F%E4%B8%AD%E6%96%87%3F")""",
                """roundtrip = url_decode(url_encode("x y+z"))""",
            ),
        )
        val body = JSONObject()
            .put("a", 11)
            .put("b", 99)
            .put("c", 31)

        RequestCustomization(provider, entry())
            .apply(body, linkedMapOf(), null)

        assertTrue(body.getBoolean("matched"))
        assertEquals(
            "a%20b%2Bc%2F%E4%B8%AD%E6%96%87%3F",
            body.getString("encoded"),
        )
        assertEquals("a b+c/中文?", body.getString("decoded"))
        assertEquals("x y+z", body.getString("roundtrip"))
    }

    @Test
    fun testApply_coversRemainingFunctionsAndLazyBranches_BitsUT() {
        val provider = provider(
            body = listOf(
                "string_object = string({b: 2, a: 1})",
                "string_null = string(null)",
                """sha = sha256("hello")""",
                "present = exists(body.present_value)",
                "absent = exists(body.absent_value)",
                """lazy_if = if(true, "selected", length(1))""",
                """lazy_conditional = true ? "selected" : length(1)""",
                """lazy_fallback = "selected" ?? length(1)""",
                "lazy_and = false && length(1) > 0",
                "lazy_or = true || length(1) > 0",
            ),
        )
        val body = JSONObject()
            .put("present_value", JSONObject.NULL)

        RequestCustomization(provider, entry())
            .apply(body, linkedMapOf(), null)

        assertEquals(
            """{"a":1,"b":2}""",
            body.getString("string_object"),
        )
        assertEquals("", body.getString("string_null"))
        assertEquals(
            "2cf24dba5fb0a30e26e83b2ac5b9e29e" +
                "1b161e5c1fa7425e73043362938b9824",
            body.getString("sha"),
        )
        assertTrue(body.getBoolean("present"))
        assertFalse(body.getBoolean("absent"))
        assertEquals("selected", body.getString("lazy_if"))
        assertEquals("selected", body.getString("lazy_conditional"))
        assertEquals("selected", body.getString("lazy_fallback"))
        assertFalse(body.getBoolean("lazy_and"))
        assertTrue(body.getBoolean("lazy_or"))
    }

    @Test
    fun testExpressionValidator_reportsExpressionResourceLimits_BitsUT() {
        val oversized = "value = \"" + "a".repeat(65_537) + "\""
        val tokenHeavy = "value = [" +
            List(1_100) { "1" }.joinToString(",") +
            "]"
        val nested = "value = " +
            "(".repeat(129) +
            "1" +
            ")".repeat(129)

        val issues = RequestExpressionValidator.validate(
            listOf(oversized, tokenHeavy, nested),
            RequestExpressionValidator.Target.BODY,
        )

        assertEquals(listOf(1, 2, 3), issues.map { it.line })
        assertEquals(
            listOf(
                "EVALUATION_LIMIT",
                "EVALUATION_LIMIT",
                "EVALUATION_LIMIT",
            ),
            issues.map { it.kind.name },
        )
    }

    @Test
    fun testApply_evaluationLimitSkipsOnlyFailingLine_BitsUT() {
        val provider = provider(
            body = listOf(
                "limited = body.items.map(item, item)",
                """after = "kept"""",
            ),
        )
        val body = JSONObject().put(
            "items",
            JSONArray((0 until 100_100).toList()),
        )

        RequestCustomization(provider, entry())
            .apply(body, linkedMapOf(), null)

        assertFalse(body.has("limited"))
        assertEquals("kept", body.getString("after"))
    }

    @Test
    fun testApply_supportsUnixTimestampsFormattingAndParsing_BitsUT() {
        val beforeMillis = System.currentTimeMillis()
        val provider = provider(
            body = listOf(
                "current_seconds = now()",
                """current_milliseconds = now("milliseconds")""",
                """utc = format_time(1704067200123, "YYYY-MM-DD HH:mm:ss.SSS", "milliseconds", "UTC")""",
                """shanghai = format_time(0, "YYYY-MM-DD HH:mm:ss", "seconds", "Asia/Shanghai")""",
                """parsed_seconds = parse_time("2024-01-01 00:00:00", "YYYY-MM-DD HH:mm:ss", "seconds", "UTC")""",
                """parsed_milliseconds = parse_time("2024-01-01 00:00:00.123", "YYYY-MM-DD HH:mm:ss.SSS", "milliseconds", "UTC")""",
                """short = format_time(1704067200, "YY-M-D H:m:s", "seconds", "UTC")""",
                """hour24 = format_time(1704112496, "HH", "seconds", "UTC")""",
                """hour12 = format_time(1704112496, "hh h a", "seconds", "UTC")""",
                """parsed_short = parse_time("24-1-2 3:4:5 PM", "YY-M-D h:m:s a", "seconds", "UTC")""",
            ),
        )
        val body = JSONObject()

        RequestCustomization(provider, entry())
            .apply(body, linkedMapOf(), null)

        val afterMillis = System.currentTimeMillis()
        assertTrue(
            body.getLong("current_seconds") in
                (beforeMillis / 1_000)..(afterMillis / 1_000),
        )
        assertTrue(
            body.getLong("current_milliseconds") in
                beforeMillis..afterMillis,
        )
        assertEquals(
            "2024-01-01 00:00:00.123",
            body.getString("utc"),
        )
        assertEquals(
            "1970-01-01 08:00:00",
            body.getString("shanghai"),
        )
        assertEquals(
            1_704_067_200L,
            body.getLong("parsed_seconds"),
        )
        assertEquals(
            1_704_067_200_123L,
            body.getLong("parsed_milliseconds"),
        )
        assertEquals("24-1-1 0:0:0", body.getString("short"))
        assertEquals("12", body.getString("hour24"))
        assertEquals("12 12 PM", body.getString("hour12"))
        assertEquals(
            1_704_207_845L,
            body.getLong("parsed_short"),
        )
    }

    @Test
    fun testApply_runtimeExpressionErrorsSkipOnlyFailingLines_BitsUT() {
        val invalidExtra =
            """headers.extra = json({session_id: session.id ?? body.prompt_cache_key ?? md5(body.input.filter(message, message.role == "user")[0].content.filter(part, part.type == "input_text")[0].text)})"""
        val control = RequestBodyControl(
            id = "mixed",
            title = "Mixed",
            kind = RequestBodyControl.Kind.toggle,
            defaultIsActive = true,
            payloadExpressions = listOf(
                invalidExtra,
                "body.bad_length = length(1)",
                """headers.X-Control = "kept"""",
                "body.control_value = 3",
            ),
        )
        val provider = provider(
            headers = listOf(
                """X-Before = "before"""",
                "X-Null = null",
                """X-After = "after"""",
            ),
            body = listOf(
                "before = 1",
                "bad = length(1)",
                "after = 2",
            ),
        )
        val body = JSONObject(
            """{"input":[{"role":"assistant","content":"text"}]}""",
        )
        val headers = linkedMapOf<String, String>()

        RequestCustomization(
            provider,
            entry(controls = listOf(control)),
        ).apply(body, headers, null)

        assertEquals("before", headers["X-Before"])
        assertEquals("after", headers["X-After"])
        assertFalse(headers.containsKey("X-Null"))
        assertFalse(headers.containsKey("extra"))
        assertEquals("kept", headers["X-Control"])
        assertEquals(1, body.getInt("before"))
        assertFalse(body.has("bad"))
        assertEquals(2, body.getInt("after"))
        assertFalse(body.has("bad_length"))
        assertEquals(3, body.getInt("control_value"))
    }

    @Test
    fun testExpressionValidator_reportsMalformedLineNumbers_BitsUT() {
        val issues = RequestExpressionValidator.validate(
            listOf(
                """valid = "value"""",
                "missing_assignment",
                """broken = {value: "unterminated"""",
                """unknown = "{{ mystery(model.id) }}"""",
                """template = "{{ session.id """",
                "function = apend(body.tools, [])",
                "arguments = update(body.tools, {})",
                "alias = request.body.tools",
                "legacy = remove_last(body.tools)",
            ),
            RequestExpressionValidator.Target.BODY,
        )

        assertEquals(listOf(2, 3, 4, 5, 6, 7, 8, 9), issues.map { it.line })
    }

    @Test
    fun testExpressionValidator_rejectsEqualsInsideObjectLiteral_BitsUT() {
        val issues = RequestExpressionValidator.validate(
            listOf("""config = {mode = "strict"}"""),
            RequestExpressionValidator.Target.BODY,
        )

        assertEquals(listOf(1), issues.map { it.line })
    }

    @Test
    fun testApply_optionGroupUsesFirstOptionWhenNoDefaultIsStored_BitsUT() {
        val control = RequestBodyControl(
            id = "temperature",
            title = "Temperature",
            kind = RequestBodyControl.Kind.optionGroup,
            options = listOf(
                RequestBodyControlOption(
                    id = "low",
                    title = "Low",
                    payloadExpressions = listOf("body.temperature = 0.2"),
                ),
                RequestBodyControlOption(
                    id = "high",
                    title = "High",
                    payloadExpressions = listOf("body.temperature = 1.0"),
                ),
            ),
        )
        val body = JSONObject()

        RequestCustomization(
            provider(),
            entry(controls = listOf(control)),
        ).apply(body, linkedMapOf(), null)

        assertEquals(0.2, body.getDouble("temperature"), 0.000_001)
    }

    @Test
    fun testApply_sliderUsesPersistedOptionID_BitsUT() {
        val context = InMemoryPreferencesContext()
        val control = RequestBodyControl(
            id = "quality",
            title = "Quality",
            kind = RequestBodyControl.Kind.optionGroup,
            isSliderEnabled = true,
            options = listOf(
                RequestBodyControlOption(
                    id = "low",
                    title = "Low",
                    payloadExpressions =
                        listOf("body.quality = \"low\""),
                ),
                RequestBodyControlOption(
                    id = "high",
                    title = "High",
                    payloadExpressions =
                        listOf("body.quality = \"high\""),
                ),
            ),
        )
        val entry = entry(controls = listOf(control))
        RequestBodyControlRuntimeStore.save(
            context = context,
            sessionKey = "session-slider",
            modelKey = entry.id,
            controls = listOf(control),
            state = RequestBodyControlState(
                selectedOptionIDsByControlID =
                    mapOf(control.id to "high"),
            ),
        )
        val body = JSONObject()

        RequestCustomization(
            provider = provider(),
            modelEntry = entry,
            sessionId = "session-slider",
            context = context,
            usesConversationRequestControlState = true,
        ).apply(body, linkedMapOf(), null)

        assertEquals("high", body.getString("quality"))
    }

    @Test
    fun testState_newConversationUsingSameModelStartsFromDefaults_BitsUT() {
        val context = InMemoryPreferencesContext()
        val control = RequestBodyControl(
            id = "toggle",
            title = "Toggle",
            kind = RequestBodyControl.Kind.toggle,
            defaultIsActive = false,
        )

        RequestBodyControlRuntimeStore.save(
            context = context,
            sessionKey = "session-a",
            modelKey = "same-model",
            controls = listOf(control),
            state = RequestBodyControlState(
                toggleValuesByControlID = mapOf(control.id to true),
            ),
        )

        val newConversationState =
            RequestBodyControlRuntimeStore.state(
                context = context,
                sessionKey = "session-b",
                modelKey = "same-model",
                controls = listOf(control),
            )
        val firstConversationState =
            RequestBodyControlRuntimeStore.state(
                context = context,
                sessionKey = "session-a",
                modelKey = "same-model",
                controls = listOf(control),
            )

        assertTrue(
            newConversationState.toggleValuesByControlID.isEmpty(),
        )
        assertEquals(
            true,
            firstConversationState
                .toggleValuesByControlID[control.id],
        )
    }

    @Test
    fun testState_withoutSessionUsesConfiguredDefaults_BitsUT() {
        val context = InMemoryPreferencesContext()
        val control = RequestBodyControl(
            id = "toggle",
            title = "Toggle",
            kind = RequestBodyControl.Kind.toggle,
            defaultIsActive = false,
        )
        RequestBodyControlRuntimeStore.save(
            context = context,
            sessionKey = "session-a",
            modelKey = "same-model",
            controls = listOf(control),
            state = RequestBodyControlState(
                toggleValuesByControlID =
                    mapOf(control.id to true),
            ),
        )

        val state = RequestBodyControlRuntimeStore.state(
            context = context,
            sessionKey = null,
            modelKey = "same-model",
            controls = listOf(control),
        )

        assertTrue(state.toggleValuesByControlID.isEmpty())
    }

    @Test
    fun testActivateModel_sameModelPreservesStateAcrossReload_BitsUT() {
        val context = InMemoryPreferencesContext()
        val control = RequestBodyControl(
            id = "toggle",
            title = "Toggle",
            kind = RequestBodyControl.Kind.toggle,
        )
        RequestBodyControlRuntimeStore.save(
            context = context,
            sessionKey = "session-a",
            modelKey = "model-a",
            controls = listOf(control),
            state = RequestBodyControlState(
                toggleValuesByControlID =
                    mapOf(control.id to true),
            ),
        )

        RequestBodyControlRuntimeStore.activateModel(
            context = context,
            sessionKey = "session-a",
            modelKey = "model-a",
        )

        assertEquals(
            true,
            RequestBodyControlRuntimeStore.state(
                context = context,
                sessionKey = "session-a",
                modelKey = "model-a",
                controls = listOf(control),
            ).toggleValuesByControlID[control.id],
        )
    }

    @Test
    fun testActivateModel_AtoBtoAUsesDefaultsEachSwitch_BitsUT() {
        val context = InMemoryPreferencesContext()
        val control = RequestBodyControl(
            id = "toggle",
            title = "Toggle",
            kind = RequestBodyControl.Kind.toggle,
        )
        val controls = listOf(control)
        RequestBodyControlRuntimeStore.save(
            context = context,
            sessionKey = "session-a",
            modelKey = "model-a",
            controls = controls,
            state = RequestBodyControlState(
                toggleValuesByControlID =
                    mapOf(control.id to true),
            ),
        )

        RequestBodyControlRuntimeStore.activateModel(
            context = context,
            sessionKey = "session-a",
            modelKey = "model-b",
        )

        assertTrue(
            RequestBodyControlRuntimeStore.state(
                context = context,
                sessionKey = "session-a",
                modelKey = "model-a",
                controls = controls,
            ).toggleValuesByControlID.isEmpty(),
        )
        RequestBodyControlRuntimeStore.save(
            context = context,
            sessionKey = "session-a",
            modelKey = "model-b",
            controls = controls,
            state = RequestBodyControlState(
                toggleValuesByControlID =
                    mapOf(control.id to false),
            ),
        )
        RequestBodyControlRuntimeStore.activateModel(
            context = context,
            sessionKey = "session-a",
            modelKey = "model-a",
        )

        assertTrue(
            RequestBodyControlRuntimeStore.state(
                context = context,
                sessionKey = "session-a",
                modelKey = "model-a",
                controls = controls,
            ).toggleValuesByControlID.isEmpty(),
        )
    }

    @Test
    fun testApply_usesCurrentSessionRuntimeState_BitsUT() {
        val context = InMemoryPreferencesContext()
        val control = RequestBodyControl(
            id = "web-search",
            title = "Web Search",
            kind = RequestBodyControl.Kind.toggle,
            defaultIsActive = false,
            payloadExpressions = listOf(
                """body.web_search = true""",
            ),
        )
        val entry = entry(controls = listOf(control))
        RequestBodyControlRuntimeStore.save(
            context = context,
            sessionKey = "session-a",
            modelKey = entry.id,
            controls = listOf(control),
            state = RequestBodyControlState(
                toggleValuesByControlID =
                    mapOf(control.id to true),
            ),
        )
        val firstBody = JSONObject()
        val secondBody = JSONObject()

        RequestCustomization(
            provider = provider(),
            modelEntry = entry,
            sessionId = "session-a",
            context = context,
            usesConversationRequestControlState = true,
        ).apply(firstBody, linkedMapOf(), null)
        RequestCustomization(
            provider = provider(),
            modelEntry = entry,
            sessionId = "session-b",
            context = context,
            usesConversationRequestControlState = true,
        ).apply(secondBody, linkedMapOf(), null)

        assertTrue(firstBody.getBoolean("web_search"))
        assertFalse(secondBody.has("web_search"))
    }

    @Test
    fun testApply_internalTaskGetsSessionButUsesConfiguredDefaults_BitsUT() {
        val context = InMemoryPreferencesContext()
        val control = RequestBodyControl(
            id = "web-search",
            title = "Web Search",
            kind = RequestBodyControl.Kind.toggle,
            defaultIsActive = false,
            payloadExpressions = listOf(
                """body.web_search = true""",
            ),
        )
        val entry = entry(
            body = listOf(
                "expression_session = session.id",
            ),
            controls = listOf(control),
        )
        RequestBodyControlRuntimeStore.save(
            context = context,
            sessionKey = "session-a",
            modelKey = entry.id,
            controls = listOf(control),
            state = RequestBodyControlState(
                toggleValuesByControlID =
                    mapOf(control.id to true),
            ),
        )
        val body = JSONObject()

        RequestCustomization(
            provider = provider(),
            modelEntry = entry,
            sessionId = "session-a",
            context = context,
            usesConversationRequestControlState = false,
        ).apply(body, linkedMapOf(), null)

        assertEquals(
            "session-a",
            body.getString("expression_session"),
        )
        assertFalse(body.has("web_search"))
    }

    @Test
    fun testMigrate_movesCurrentDraftSnapshot_BitsUT() {
        val context = InMemoryPreferencesContext()
        val control = RequestBodyControl(
            id = "toggle",
            title = "Toggle",
            kind = RequestBodyControl.Kind.toggle,
        )
        val controls = listOf(control)
        RequestBodyControlRuntimeStore.save(
            context = context,
            sessionKey = "__new__draft",
            modelKey = "model-a",
            controls = controls,
            state = RequestBodyControlState(
                toggleValuesByControlID =
                    mapOf(control.id to true),
            ),
        )

        RequestBodyControlRuntimeStore.migrate(
            context = context,
            fromSessionKey = "__new__draft",
            toSessionKey = "session-real",
        )

        assertTrue(
            RequestBodyControlRuntimeStore.state(
                context = context,
                sessionKey = "__new__draft",
                modelKey = "model-a",
                controls = controls,
            ).toggleValuesByControlID.isEmpty(),
        )
        assertEquals(
            true,
            RequestBodyControlRuntimeStore.state(
                context = context,
                sessionKey = "session-real",
                modelKey = "model-a",
                controls = controls,
            ).toggleValuesByControlID[control.id],
        )
        assertTrue(
            RequestBodyControlRuntimeStore.state(
                context = context,
                sessionKey = "session-real",
                modelKey = "model-b",
                controls = controls,
            ).toggleValuesByControlID.isEmpty(),
        )
    }

    @Test
    fun testNormalizedExpressionEditorText_removesBlankLinesAndKeepsOneEditingLine_BitsUT() {
        assertEquals("", normalizedExpressionEditorText(""))
        assertEquals("", normalizedExpressionEditorText("\n\n"))
        assertEquals(
            "temperature = 0.7\nmax_tokens = 4096",
            normalizedExpressionEditorText("temperature = 0.7\n\nmax_tokens = 4096"),
        )
        assertEquals(
            "temperature = 0.7\n",
            normalizedExpressionEditorText("temperature = 0.7\n\n\n"),
        )
        assertEquals(
            "temperature = 0.7",
            finalizedExpressionEditorText("temperature = 0.7\n\n\n"),
        )
    }

    @Test
    fun testApply_jsonTemplateProducesJSONText_BitsUT() {
        val customization = RequestCustomization(
            provider = provider(body = listOf("metadata.config = {{ json(body.config) }}")),
            modelEntry = entry(),
        )
        val body = JSONObject("""{"config":{"mode":"strict"}}""")

        customization.apply(body, linkedMapOf(), "secret")

        assertEquals("""{"mode":"strict"}""", body.getJSONObject("metadata").getString("config"))
    }

    private fun provider(
        headers: List<String> = emptyList(),
        body: List<String> = emptyList(),
    ): ProviderInstance = ProviderInstance(
        id = "provider",
        label = "Provider",
        providerType = ProviderType.openAI,
        credentialType = ProviderCredential.apiKey,
        customRequestHeaders = headers,
        customRequestBody = body,
    )

    private fun entry(
        headers: List<String> = emptyList(),
        body: List<String> = emptyList(),
        controls: List<RequestBodyControl> = emptyList(),
    ): ModelEntry = ModelEntry(
        providerInstanceId = "provider",
        baseModel = LLMModel(
            id = "test-model",
            displayName = "Test Model",
            provider = "OpenAI",
            supportsReasoning = true,
        ),
        overrides = ModelOverrides(
            customRequestHeaders = headers,
            customRequestBody = body,
            requestBodyControls = controls,
        ),
        uuid = "entry",
    )

    private fun JSONArray.toIntList(): List<Int> =
        (0 until length()).map { getInt(it) }

    private fun JSONArray.toStringList(): List<String> =
        (0 until length()).map { getString(it) }
}

private class InMemoryPreferencesContext :
    ContextWrapper(null) {
    private val preferences =
        InMemorySharedPreferences()

    override fun getSharedPreferences(
        name: String?,
        mode: Int,
    ): SharedPreferences = preferences
}

private class InMemorySharedPreferences :
    SharedPreferences {
    private val values =
        linkedMapOf<String, Any?>()
    private val listeners =
        linkedSetOf<
            SharedPreferences
                .OnSharedPreferenceChangeListener
            >()

    override fun getAll(): MutableMap<String, *> =
        values.toMutableMap()

    override fun getString(
        key: String?,
        defaultValue: String?,
    ): String? =
        values[key] as? String
            ?: defaultValue

    @Suppress("UNCHECKED_CAST")
    override fun getStringSet(
        key: String?,
        defaultValues: MutableSet<String>?,
    ): MutableSet<String>? =
        (values[key] as? Set<String>)
            ?.toMutableSet()
            ?: defaultValues

    override fun getInt(
        key: String?,
        defaultValue: Int,
    ): Int =
        values[key] as? Int
            ?: defaultValue

    override fun getLong(
        key: String?,
        defaultValue: Long,
    ): Long =
        values[key] as? Long
            ?: defaultValue

    override fun getFloat(
        key: String?,
        defaultValue: Float,
    ): Float =
        values[key] as? Float
            ?: defaultValue

    override fun getBoolean(
        key: String?,
        defaultValue: Boolean,
    ): Boolean =
        values[key] as? Boolean
            ?: defaultValue

    override fun contains(key: String?): Boolean =
        values.containsKey(key)

    override fun edit(): SharedPreferences.Editor =
        Editor()

    override fun registerOnSharedPreferenceChangeListener(
        listener:
            SharedPreferences
                .OnSharedPreferenceChangeListener?,
    ) {
        listener?.let(listeners::add)
    }

    override fun unregisterOnSharedPreferenceChangeListener(
        listener:
            SharedPreferences
                .OnSharedPreferenceChangeListener?,
    ) {
        listener?.let(listeners::remove)
    }

    private inner class Editor :
        SharedPreferences.Editor {
        private val changes =
            linkedMapOf<String, Any?>()
        private var clearRequested = false

        override fun putString(
            key: String?,
            value: String?,
        ): SharedPreferences.Editor =
            put(key, value)

        override fun putStringSet(
            key: String?,
            values: MutableSet<String>?,
        ): SharedPreferences.Editor =
            put(key, values?.toSet())

        override fun putInt(
            key: String?,
            value: Int,
        ): SharedPreferences.Editor =
            put(key, value)

        override fun putLong(
            key: String?,
            value: Long,
        ): SharedPreferences.Editor =
            put(key, value)

        override fun putFloat(
            key: String?,
            value: Float,
        ): SharedPreferences.Editor =
            put(key, value)

        override fun putBoolean(
            key: String?,
            value: Boolean,
        ): SharedPreferences.Editor =
            put(key, value)

        override fun remove(
            key: String?,
        ): SharedPreferences.Editor =
            put(key, Removed)

        override fun clear(): SharedPreferences.Editor {
            clearRequested = true
            return this
        }

        override fun commit(): Boolean {
            applyChanges()
            return true
        }

        override fun apply() {
            applyChanges()
        }

        private fun put(
            key: String?,
            value: Any?,
        ): SharedPreferences.Editor {
            if (key != null) {
                changes[key] = value
            }
            return this
        }

        private fun applyChanges() {
            val changedKeys =
                linkedSetOf<String>()
            if (clearRequested) {
                changedKeys += values.keys
                values.clear()
            }
            changes.forEach { (key, value) ->
                changedKeys += key
                if (value === Removed || value == null) {
                    values.remove(key)
                } else {
                    values[key] = value
                }
            }
            changedKeys.forEach { key ->
                listeners.forEach { listener ->
                    listener.onSharedPreferenceChanged(
                        this@InMemorySharedPreferences,
                        key,
                    )
                }
            }
        }
    }

    private object Removed
}
