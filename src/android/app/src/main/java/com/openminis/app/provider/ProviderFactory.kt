package com.openminis.app.provider

import android.content.Context
import com.openminis.app.auth.OpenAIOAuthManager
import com.openminis.app.data.model.LLMModel
import com.openminis.app.data.model.ModelEntry
import com.openminis.app.data.model.ProviderCredential
import com.openminis.app.data.model.ProviderInstance
import com.openminis.app.data.model.ProviderType
import com.openminis.app.provider.anthropic.AnthropicProvider
import com.openminis.app.provider.gemini.GeminiProvider
import com.openminis.app.provider.openai.OpenAIProvider

object ProviderFactory {
    /**
     * Create a provider, optionally with OAuth support.
     * [context] is needed for OpenAI OAuth to access encrypted storage for token refresh.
     */
    fun create(instance: ProviderInstance, apiKey: String, model: LLMModel, context: Context? = null, entry: ModelEntry? = null): LLMProvider {
        // T174: route through ProviderInstance.effectiveBaseURL instead of
        // re-implementing the trim-+-endsWith dance inline. The previous
        // version did `url.endsWith("/v1")` on the raw, untrimmed string,
        // so a customBaseURL of "https://api.deepseek.com/v1/" (trailing
        // slash) failed the check and the code appended a second "/v1",
        // producing requests to "/v1//v1/chat/completions" → HTTP 404.
        // Likewise "https://api.deepseek.com/" was concatenated as-is to
        // ".../" + "/v1/chat/completions" = ".//v1/chat/completions",
        // which DeepSeek tolerated only by accident. effectiveBaseURL
        // trimEnd('/')'s the input first, so all four customBaseURL
        // shapes (no slash, trailing slash, /v1, /v1/) now collapse to
        // the same canonical "https://host/v1" string. The /chat/
        // completions endpoint suffix at OpenAIProvider.kt:710 then
        // produces a single-slash join.
        val basePath = instance.effectiveBaseURL
        val requestCustomization =
            RequestCustomization(
                instance,
                entry,
                context = context,
            )
        return when (instance.providerType) {
            ProviderType.anthropic -> {
                val isOAuth = instance.credentialType == ProviderCredential.oauth
                if (basePath != null) AnthropicProvider(apiKey, model, basePath, isOAuth = isOAuth, requestCustomization = requestCustomization)
                else AnthropicProvider(apiKey, model, isOAuth = isOAuth, requestCustomization = requestCustomization)
            }
            ProviderType.gemini -> {
                if (basePath != null) GeminiProvider(apiKey, model, basePath, requestCustomization = requestCustomization)
                else GeminiProvider(apiKey, model, requestCustomization = requestCustomization)
            }
            ProviderType.openAI -> {
                // Manual bearer token (set via Manual Bearer Token UI / imported
                // from JSON) bypasses the Codex OAuth flow entirely and is sent
                // verbatim as `Authorization: Bearer …` against api.openai.com
                // (or the user's custom base URL). Mirrors iOS LLMProviderFactory:
                // a manual token routes through the API-key constructor, not the
                // OAuth (Codex Responses) constructor — so requests go to the
                // standard Chat Completions endpoint instead of chatgpt.com's
                // codex backend (which only accepts real ChatGPT session tokens).
                val manualBearer = if (context != null &&
                    instance.credentialType == ProviderCredential.oauth) {
                    com.openminis.app.auth.OAuthManager.forInstance(context, instance)?.loadManualBearerToken()
                } else null

                if (instance.credentialType == ProviderCredential.oauth && manualBearer.isNullOrEmpty()
                    && basePath == null && context != null) {
                    // Codex OAuth mode — Responses API with refresh-aware token provider
                    val oauthManager = OpenAIOAuthManager(context, instance.id)
                    OpenAIProvider(
                        oauthTokenProvider = { oauthManager.validAccessToken() ?: throw com.openminis.app.data.model.LLMError.InvalidApiKey() },
                        model = model,
                        codexAccountId = oauthManager.accountId,
                        requestCustomization = requestCustomization,
                    )
                } else {
                    // API key, or manual OAuth bearer (with or without custom
                    // base URL). The user can flip `useResponsesAPI` on a
                    // per-instance basis when the backend only speaks
                    // /v1/responses.
                    val base = basePath ?: "https://api.openai.com/v1"
                    val effectiveKey = if (!manualBearer.isNullOrEmpty()) manualBearer else apiKey
                    OpenAIProvider(
                        apiKey = effectiveKey,
                        model = model,
                        basePath = base,
                        useResponsesAPI = instance.useResponsesAPI,
                        requestCustomization = requestCustomization,
                        // [T-android-azure-openai] Azure auths with api-key +
                        // deployments-path URL. Pass the RAW customBaseURL (not
                        // the /v1-appended, query-stripped effectiveBaseURL) so
                        // azureUrl() can preserve the ?api-version query.
                        isAzure = instance.azureMode,
                        azureBase = instance.customBaseURL,
                    )
                }
            }
            ProviderType.openRouter -> {
                // OpenRouter uses OpenAI-compatible API with custom base URL and headers
                OpenAIProvider(
                    apiKey = apiKey,
                    model = model,
                    basePath = "https://openrouter.ai/api/v1",
                    extraHeaders = mapOf(
                        "HTTP-Referer" to "https://github.com/OpenMinis/OpenMinis",
                        "X-Title" to "Minis App",
                    ),
                    requestCustomization = requestCustomization,
                )
            }
            ProviderType.xAI -> {
                // xAI exposes an OpenAI-compatible /v1/chat/completions
                // endpoint at api.x.ai/v1. Two credential modes:
                //   - OAuth (SuperGrok / X Premium+): bearer fetched via
                //     XAIOAuthManager.validAccessToken() — refresh-aware.
                //   - Manual API key: passed through verbatim. Some users
                //     prefer this when their tier doesn't expose OAuth API
                //     access (the spec's known-issue 403 case).
                val base = basePath ?: "https://api.x.ai/v1"
                val manualBearer = if (context != null &&
                    instance.credentialType == ProviderCredential.oauth) {
                    com.openminis.app.auth.OAuthManager.forInstance(context, instance)?.loadManualBearerToken()
                } else null
                if (instance.credentialType == ProviderCredential.oauth && manualBearer.isNullOrEmpty()
                    && context != null) {
                    val oauthManager = com.openminis.app.auth.XAIOAuthManager(context, instance.id)
                    OpenAIProvider.oauthOpenAICompat(
                        oauthTokenProvider = {
                            oauthManager.validAccessToken()
                                ?: throw com.openminis.app.data.model.LLMError.InvalidApiKey()
                        },
                        model = model,
                        basePath = base,
                        requestCustomization = requestCustomization,
                    )
                } else {
                    val effectiveKey = if (!manualBearer.isNullOrEmpty()) manualBearer else apiKey
                    OpenAIProvider(
                        apiKey = effectiveKey,
                        model = model,
                        basePath = base,
                        requestCustomization = requestCustomization,
                    )
                }
            }
            ProviderType.kimiCode -> {
                // [T-kimi-oauth] Kimi Coding Plan — OpenAI-compatible upstream.
                // ⚠️ The `/v1` is load-bearing: /coding/chat/completions 404s;
                // only /coding/v1/chat/completions works (verified live on iOS).
                // Custom bases go through effectiveBaseURL's /v1-append logic.
                val base = basePath ?: "${com.openminis.app.auth.KimiDeviceFlow.CODING_API_BASE}/v1"
                val manualBearer = if (context != null &&
                    instance.credentialType == ProviderCredential.oauth) {
                    com.openminis.app.auth.OAuthManager.forInstance(context, instance)?.loadManualBearerToken()
                } else null
                if (instance.credentialType == ProviderCredential.oauth && manualBearer.isNullOrEmpty()
                    && context != null) {
                    val oauthManager = com.openminis.app.auth.KimiOAuthManager(context, instance.id)
                    // Same path as xAI OAuth: Bearer token provider +
                    // forceChatCompletions so the Codex Responses backend
                    // shaping never applies.
                    OpenAIProvider.oauthOpenAICompat(
                        oauthTokenProvider = {
                            oauthManager.validAccessToken()
                                ?: throw com.openminis.app.data.model.LLMError.InvalidApiKey()
                        },
                        model = model,
                        basePath = base,
                        requestCustomization = requestCustomization,
                    )
                } else {
                    // Manual Moonshot API key (or manual bearer) path.
                    val effectiveKey = if (!manualBearer.isNullOrEmpty()) manualBearer else apiKey
                    OpenAIProvider(
                        apiKey = effectiveKey,
                        model = model,
                        basePath = base,
                        requestCustomization = requestCustomization,
                    )
                }
            }
        }
    }
}
