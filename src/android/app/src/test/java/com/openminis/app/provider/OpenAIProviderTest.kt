package com.openminis.app.provider

import com.openminis.app.data.model.LLMError
import com.openminis.app.data.model.LLMMessage
import com.openminis.app.data.model.LLMModel
import com.openminis.app.data.model.LLMStreamChunk
import com.openminis.app.data.model.ModelEntry
import com.openminis.app.data.model.ModelOverrides
import com.openminis.app.data.model.ProviderCredential
import com.openminis.app.data.model.ProviderInstance
import com.openminis.app.data.model.ProviderType
import com.openminis.app.data.model.RequestBodyControl
import com.openminis.app.provider.openai.OpenAIProvider
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class OpenAIProviderTest {
    private lateinit var server: MockWebServer
    private lateinit var provider: OpenAIProvider

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        provider = OpenAIProvider(
            apiKey = "test-key",
            model = LLMModel.gpt4oMini,
            basePath = server.url("/").toString().trimEnd('/'),
        )
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    private fun enqueueChatSse(
        content: String = "ok",
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        cachedTokens: Int? = null,
        finishReason: String? = "stop",
    ) {
        val usage = JSONObject()
            .put("prompt_tokens", promptTokens)
            .put("completion_tokens", completionTokens)
        cachedTokens?.let {
            usage.put(
                "prompt_tokens_details",
                JSONObject().put("cached_tokens", it),
            )
        }
        val events = buildString {
            if (content.isNotEmpty()) {
                appendLine(
                    "data: ${JSONObject().put(
                        "choices",
                        JSONArray().put(
                            JSONObject()
                                .put("delta", JSONObject().put("content", content))
                                .put("finish_reason", JSONObject.NULL),
                        ),
                    )}",
                )
                appendLine()
            }
            if (finishReason != null) {
                appendLine(
                    "data: ${JSONObject().put(
                        "choices",
                        JSONArray().put(
                            JSONObject()
                                .put("delta", JSONObject())
                                .put("finish_reason", finishReason),
                        ),
                    )}",
                )
                appendLine()
            }
            appendLine(
                "data: ${JSONObject()
                    .put("choices", JSONArray())
                    .put("usage", usage)}",
            )
            appendLine()
            appendLine("data: [DONE]")
            appendLine()
        }
        server.enqueue(
            MockResponse()
                .setHeader("Content-Type", "text/event-stream")
                .setBody(events),
        )
    }

    // -- sendMessage response parsing --

    @Test
    fun `sendMessage parses ChatCompletions response`() = runBlocking {
        enqueueChatSse(
            content = "Hello from GPT!",
            promptTokens = 10,
            completionTokens = 5,
        )

        val response = provider.sendMessage(
            listOf(LLMMessage(LLMMessage.Role.USER, "Hi")),
            null, 1024,
        )

        assertEquals("Hello from GPT!", response.text)
        assertEquals("stop", response.stopReason)
        assertEquals(10, response.usage?.inputTokens)
        assertEquals(5, response.usage?.outputTokens)
    }

    @Test
    fun `sendMessage parses cached tokens from prompt_tokens_details`() = runBlocking {
        enqueueChatSse(
            promptTokens = 100,
            completionTokens = 10,
            cachedTokens = 50,
        )
        val response = provider.sendMessage(listOf(LLMMessage(LLMMessage.Role.USER, "Hi")), null, 1024)

        assertEquals(50, response.usage?.inputTokens)
        assertEquals(10, response.usage?.outputTokens)
        assertEquals(50, response.usage?.cacheReadInputTokens)
        assertNull(response.usage?.cacheCreationInputTokens)
    }

    @Test
    fun `sendMessage returns null cacheReadInputTokens when zero`() = runBlocking {
        enqueueChatSse(
            promptTokens = 10,
            completionTokens = 5,
            cachedTokens = 0,
        )
        val response = provider.sendMessage(listOf(LLMMessage(LLMMessage.Role.USER, "Hi")), null, 1024)
        assertNull(response.usage?.cacheReadInputTokens)
    }

    @Test
    fun `sendMessage rejects silent empty completion`() = runBlocking {
        enqueueChatSse(content = "", promptTokens = 5, finishReason = null)

        val error = runCatching {
            provider.sendMessage(listOf(LLMMessage(LLMMessage.Role.USER, "Hi")), null, 1024)
        }.exceptionOrNull()
        assertTrue(error is LLMError.TransientError)
    }

    // -- Request construction --

    @Test
    fun `sendMessage includes Bearer auth header`() = runBlocking {
        enqueueChatSse()

        provider.sendMessage(listOf(LLMMessage(LLMMessage.Role.USER, "test")), null, 100)

        val request = server.takeRequest()
        assertEquals("Bearer test-key", request.getHeader("Authorization"))
        assertTrue(request.path!!.contains("/chat/completions"))
    }

    @Test
    fun testStreamMessage_customizationCanReadDefaultAuthorization_BitsUT() = runBlocking {
        val instance = ProviderInstance(
            id = "provider",
            label = "OpenAI",
            providerType = ProviderType.openAI,
            credentialType = ProviderCredential.apiKey,
            customRequestHeaders = listOf(
                "X-Auth-Copy = {{ headers.Authorization }}",
            ),
            customRequestBody = listOf(
                """metadata.provider = "custom"""",
            ),
        )
        val model = LLMModel(
            id = "test-model",
            displayName = "Test Model",
            provider = "OpenAI",
            supportsReasoning = true,
        )
        val entry = ModelEntry(
            providerInstanceId = instance.id,
            baseModel = model,
            overrides = ModelOverrides(
                customRequestBody = listOf("""metadata.model = "custom""""),
            ),
            uuid = "entry",
        )
        val customizedProvider = OpenAIProvider(
            apiKey = "test-key",
            model = model,
            basePath = server.url("/").toString().trimEnd('/'),
            requestCustomization = RequestCustomization(instance, entry),
        )
        server.enqueue(
            MockResponse()
                .setHeader("Content-Type", "text/event-stream")
                .setBody(
                    """
                    data: {"choices":[{"delta":{"content":"ok"},"finish_reason":null}]}

                    data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

                    data: [DONE]

                    """.trimIndent(),
                ),
        )

        customizedProvider.streamMessage(
            listOf(LLMMessage(LLMMessage.Role.USER, "Hi")),
            null,
            1024,
        ).toList()

        val request = server.takeRequest()
        assertEquals("Bearer test-key", request.getHeader("X-Auth-Copy"))
        val metadata = JSONObject(request.body.readUtf8()).getJSONObject("metadata")
        assertEquals("custom", metadata.getString("provider"))
        assertEquals("custom", metadata.getString("model"))
    }

    @Test
    fun testRawPassthrough_appliesPersistedRequestCustomization_BitsUT() =
        runBlocking {
            val instance = ProviderInstance(
                id = "provider",
                label = "OpenAI",
                providerType = ProviderType.openAI,
                credentialType = ProviderCredential.apiKey,
                customRequestHeaders = listOf(
                    """X-Persisted = "provider"""",
                ),
                customRequestBody = listOf(
                    """metadata.provider = "custom"""",
                ),
            )
            val model = LLMModel(
                id = "test-model",
                displayName = "Test Model",
                provider = "OpenAI",
            )
            val entry = ModelEntry(
                providerInstanceId = instance.id,
                baseModel = model,
                overrides = ModelOverrides(
                    customRequestBody = listOf(
                        """metadata.model = "custom"""",
                    ),
                ),
                uuid = "entry",
            )
            val customizedProvider = OpenAIProvider(
                apiKey = "test-key",
                model = model,
                basePath = server.url("/").toString().trimEnd('/'),
                requestCustomization = RequestCustomization(instance, entry),
            )
            server.enqueue(MockResponse().setBody("{}"))

            customizedProvider.rawPassthroughRequest(
                endpoint = "raw",
                method = "POST",
                headers = mapOf("X-Call" to "explicit"),
                bodyObject = JSONObject().put("seed", 7),
            )

            val request = server.takeRequest()
            assertEquals("provider", request.getHeader("X-Persisted"))
            assertEquals("explicit", request.getHeader("X-Call"))
            val body = JSONObject(request.body.readUtf8())
            assertEquals(7, body.getInt("seed"))
            val metadata = body.getJSONObject("metadata")
            assertEquals("custom", metadata.getString("provider"))
            assertEquals("custom", metadata.getString("model"))
        }

    @Test
    fun testImageGeneration_appliesPersistedRequestCustomization_BitsUT() =
        runBlocking {
            val instance = ProviderInstance(
                id = "provider",
                label = "OpenAI",
                providerType = ProviderType.openAI,
                credentialType = ProviderCredential.apiKey,
                customRequestHeaders = listOf(
                    """X-Image-Custom = "enabled"""",
                ),
                customRequestBody = listOf(
                    "watermark = false",
                ),
            )
            val model = LLMModel(
                id = "image-model",
                displayName = "Image Model",
                provider = "OpenAI",
            )
            val entry = ModelEntry(
                providerInstanceId = instance.id,
                baseModel = model,
                uuid = "entry",
            )
            val customizedProvider = OpenAIProvider(
                apiKey = "test-key",
                model = model,
                basePath = server.url("/").toString().trimEnd('/'),
                requestCustomization = RequestCustomization(instance, entry),
            )
            server.enqueue(MockResponse().setBody("""{"data":[]}"""))

            customizedProvider.generateImage(prompt = "test")

            val request = server.takeRequest()
            assertEquals("enabled", request.getHeader("X-Image-Custom"))
            val body = JSONObject(request.body.readUtf8())
            assertEquals(false, body.getBoolean("watermark"))
            assertEquals("image-model", body.getString("model"))
        }

    @Test
    fun testStreamMessage_thinkingControlInjectsReasoningEffortIntoRequestBody_BitsUT() =
        runBlocking {
            // The header+body customization paths are covered above; this proves a
            // Request Control (thinkingBudget) writes its payloadExpressions into
            // the real request body. Uses an explicit toggle payload (not
            // RequestBodyControlDefaults) so the assertion is self-contained.
            val instance = ProviderInstance(
                id = "provider",
                label = "OpenAI",
                providerType = ProviderType.openAI,
                credentialType = ProviderCredential.apiKey,
            )
            val model = LLMModel(
                id = "test-model",
                displayName = "Test Model",
                provider = "OpenAI",
                supportsReasoning = true,
            )
            val control = RequestBodyControl(
                id = "thinking",
                title = "Thinking",
                kind = RequestBodyControl.Kind.toggle,
                defaultIsActive = true,
                payloadExpressions = listOf("""body.reasoning_effort = "high""""),
            )
            val entry = ModelEntry(
                providerInstanceId = instance.id,
                baseModel = model,
                overrides = ModelOverrides(requestBodyControls = listOf(control)),
                uuid = "entry",
            )
            val customizedProvider = OpenAIProvider(
                apiKey = "test-key",
                model = model,
                basePath = server.url("/").toString().trimEnd('/'),
                requestCustomization = RequestCustomization(instance, entry),
            )
            server.enqueue(
                MockResponse()
                    .setHeader("Content-Type", "text/event-stream")
                    .setBody(
                        """
                        data: {"choices":[{"delta":{"content":"ok"},"finish_reason":null}]}

                        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

                        data: [DONE]

                        """.trimIndent(),
                    ),
            )

            customizedProvider.streamMessage(
                listOf(LLMMessage(LLMMessage.Role.USER, "Hi")),
                null,
                1024,
            ).toList()

            val body = JSONObject(server.takeRequest().body.readUtf8())
            assertEquals("high", body.getString("reasoning_effort"))
        }

    @Test
    fun `sendMessage includes system prompt as system message`() = runBlocking {
        enqueueChatSse()

        provider.sendMessage(
            listOf(LLMMessage(LLMMessage.Role.USER, "test")),
            "You are helpful", 100,
        )

        val request = server.takeRequest()
        val body = JSONObject(request.body.readUtf8())
        val messages = body.getJSONArray("messages")
        // System message should be first
        assertEquals("system", messages.getJSONObject(0).getString("role"))
        assertEquals("You are helpful", messages.getJSONObject(0).getString("content"))
        // User message follows
        assertEquals("user", messages.getJSONObject(1).getString("role"))
    }

    @Test
    fun `sendMessage omits system message when null`() = runBlocking {
        enqueueChatSse()

        provider.sendMessage(listOf(LLMMessage(LLMMessage.Role.USER, "test")), null, 100)

        val request = server.takeRequest()
        val body = JSONObject(request.body.readUtf8())
        val messages = body.getJSONArray("messages")
        assertEquals(1, messages.length())
        assertEquals("user", messages.getJSONObject(0).getString("role"))
    }

    @Test
    fun `sendMessage includes temperature when set`() = runBlocking {
        enqueueChatSse()

        provider.sendMessage(listOf(LLMMessage(LLMMessage.Role.USER, "test")), null, 100, temperature = 0.8)

        val request = server.takeRequest()
        val body = JSONObject(request.body.readUtf8())
        assertEquals(0.8, body.getDouble("temperature"), 0.001)
    }

    @Test
    fun `sendMessage omits temperature when null`() = runBlocking {
        enqueueChatSse()

        provider.sendMessage(listOf(LLMMessage(LLMMessage.Role.USER, "test")), null, 100, temperature = null)

        val request = server.takeRequest()
        val body = JSONObject(request.body.readUtf8())
        assertTrue(!body.has("temperature"))
    }

    @Test
    fun `sendMessage uses max_completion_tokens for OpenAI`() = runBlocking {
        enqueueChatSse()

        provider.sendMessage(listOf(LLMMessage(LLMMessage.Role.USER, "test")), null, 2048)

        val request = server.takeRequest()
        val body = JSONObject(request.body.readUtf8())
        assertEquals(2048, body.getInt("max_completion_tokens"))
        assertTrue(!body.has("max_tokens"))
    }

    @Test
    fun `sendMessage uses streaming transport internally`() = runBlocking {
        enqueueChatSse()

        provider.sendMessage(listOf(LLMMessage(LLMMessage.Role.USER, "test")), null, 100)

        val request = server.takeRequest()
        val body = JSONObject(request.body.readUtf8())
        assertTrue(body.getBoolean("stream"))
        assertTrue(body.getJSONObject("stream_options").getBoolean("include_usage"))
    }

    // -- Streaming --

    @Test
    fun `streamMessage parses SSE events with DONE`() = runBlocking {
        val sseBody = buildString {
            appendLine("data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}")
            appendLine()
            appendLine("data: {\"choices\":[{\"delta\":{\"content\":\" world\"}}]}")
            appendLine()
            appendLine("data: {\"choices\":[{\"delta\":{}}],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":2}}")
            appendLine()
            appendLine("data: [DONE]")
            appendLine()
        }

        server.enqueue(
            MockResponse()
                .setBody(sseBody)
                .setHeader("Content-Type", "text/event-stream")
        )

        val chunks = provider.streamMessage(
            listOf(LLMMessage(LLMMessage.Role.USER, "Hi")),
            null, 1024,
        ).toList()

        assertTrue(chunks.any { it is LLMStreamChunk.Started })
        val texts = chunks.filterIsInstance<LLMStreamChunk.Text>()
        assertEquals("Hello", texts[0].text)
        assertEquals(" world", texts[1].text)

        val usageChunks = chunks.filterIsInstance<LLMStreamChunk.Usage>()
        assertEquals(1, usageChunks.size)
        assertEquals(5, usageChunks[0].usage.inputTokens)
        assertEquals(2, usageChunks[0].usage.outputTokens)

        assertTrue(chunks.any { it is LLMStreamChunk.Finished })
    }

    @Test
    fun `streamMessage includes stream_options with include_usage`() = runBlocking {
        val sseBody = buildString {
            appendLine("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}")
            appendLine()
            appendLine("data: [DONE]")
            appendLine()
        }
        server.enqueue(MockResponse().setBody(sseBody).setHeader("Content-Type", "text/event-stream"))

        provider.streamMessage(listOf(LLMMessage(LLMMessage.Role.USER, "Hi")), null, 1024).toList()

        val request = server.takeRequest()
        val body = JSONObject(request.body.readUtf8())
        assertTrue(body.getBoolean("stream"))
        val streamOptions = body.getJSONObject("stream_options")
        assertTrue(streamOptions.getBoolean("include_usage"))
    }

    @Test
    fun `streamMessage includes temperature in request`() = runBlocking {
        val sseBody = buildString {
            appendLine("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}")
            appendLine()
            appendLine("data: [DONE]")
            appendLine()
        }
        server.enqueue(MockResponse().setBody(sseBody).setHeader("Content-Type", "text/event-stream"))

        provider.streamMessage(listOf(LLMMessage(LLMMessage.Role.USER, "Hi")), null, 1024, temperature = 1.0).toList()

        val request = server.takeRequest()
        val body = JSONObject(request.body.readUtf8())
        assertEquals(1.0, body.getDouble("temperature"), 0.001)
    }

    @Test
    fun `streamMessage parses cached tokens in usage`() = runBlocking {
        val sseBody = buildString {
            appendLine("""data: {"choices":[{"delta":{"content":"ok"}}]}""")
            appendLine()
            appendLine("""data: {"choices":[{"delta":{}}],"usage":{"prompt_tokens":100,"completion_tokens":10,"prompt_tokens_details":{"cached_tokens":50}}}""")
            appendLine()
            appendLine("data: [DONE]")
            appendLine()
        }

        server.enqueue(MockResponse().setBody(sseBody).setHeader("Content-Type", "text/event-stream"))

        val chunks = provider.streamMessage(listOf(LLMMessage(LLMMessage.Role.USER, "Hi")), null, 1024).toList()

        val usageChunks = chunks.filterIsInstance<LLMStreamChunk.Usage>()
        assertEquals(1, usageChunks.size)
        assertEquals(50, usageChunks[0].usage.cacheReadInputTokens)
    }

    // -- Error handling --

    @Test(expected = LLMError.InvalidApiKey::class)
    fun `sendMessage throws InvalidApiKey on 401`() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(401).setBody("Unauthorized"))
        provider.sendMessage(listOf(LLMMessage(LLMMessage.Role.USER, "test")), null, 100)
        Unit
    }

    @Test(expected = LLMError.InvalidApiKey::class)
    fun `sendMessage throws InvalidApiKey on 403`() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(403).setBody("Forbidden"))
        provider.sendMessage(listOf(LLMMessage(LLMMessage.Role.USER, "test")), null, 100)
        Unit
    }

    @Test(expected = LLMError.RateLimited::class)
    fun `sendMessage throws RateLimited on 429`() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(429).setBody("Rate limited"))
        provider.sendMessage(listOf(LLMMessage(LLMMessage.Role.USER, "test")), null, 100)
        Unit
    }

    @Test
    fun `sendMessage parses error body for ProviderError`() = runBlocking {
        val errorBody = """{"error":{"message":"The model does not exist","type":"invalid_request_error"}}"""
        server.enqueue(MockResponse().setResponseCode(400).setBody(errorBody))

        try {
            provider.sendMessage(listOf(LLMMessage(LLMMessage.Role.USER, "test")), null, 100)
        } catch (e: LLMError.ProviderError) {
            assertTrue(e.message!!.contains("400"))
            assertTrue(e.message!!.contains("The model does not exist"))
            return@runBlocking
        }
        throw AssertionError("Expected ProviderError")
    }

    // -- Provider metadata --

    @Test
    fun `provider name is OpenAI`() {
        assertEquals("OpenAI", provider.name)
    }

    @Test
    fun `provider model can be changed`() {
        provider.model = LLMModel.gpt4o
        assertEquals(LLMModel.gpt4o, provider.model)
    }
}
