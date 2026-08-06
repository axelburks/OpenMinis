package com.openminis.app.data.model

import com.openminis.app.provider.catalogMaxThinkingLevel
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.util.UUID

@Serializable
enum class ProviderType(val displayName: String) {
    anthropic("Anthropic"),
    gemini("Google Gemini"),
    openAI("OpenAI"),
    openRouter("OpenRouter"),
    xAI("xAI (Grok)"),
    // [T-kimi-oauth] Kimi Code (Coding Plan) — RFC 8628 device-code OAuth,
    // OpenAI-compatible upstream at api.kimi.com/coding/v1. DB round-trip is
    // name-based (ProviderCredential.valueOf), so appending is migration-safe.
    kimiCode("Kimi Code");

    val builtInModels: List<LLMModel>
        get() = when (this) {
            anthropic -> LLMModel.allAnthropic
            gemini -> LLMModel.allGemini
            openAI -> LLMModel.allOpenAI
            openRouter -> LLMModel.allOpenRouter
            xAI -> LLMModel.allXAI
            kimiCode -> LLMModel.allKimi
        }
}

@Serializable
enum class ProviderCredential {
    apiKey,
    oauth,
}

@Serializable
enum class ThinkingLevel {
    OFF, MINIMAL, LOW, MEDIUM, HIGH, XHIGH, MAX, ULTRA;

    val isEnabled: Boolean get() = this != OFF

    val displayName: String
        get() = when (this) {
            OFF -> "Off"
            MINIMAL -> "Minimal"
            LOW -> "Low"
            MEDIUM -> "Medium"
            HIGH -> "High"
            XHIGH -> "XHigh"
            MAX -> "Max"
            ULTRA -> "Ultra"
        }

    /** Intensity ordinal used for intersection / clamp comparisons —
     *  follows the enum declaration order. */
    val rank: Int get() = ordinal

    companion object {
        fun availableLevels(model: LLMModel): List<ThinkingLevel> {
            if (model.supportsReasoning == false) return emptyList()
            val maxLevel = model.catalogMaxThinkingLevel
            return entries.filter { level ->
                level == OFF || level.rank <= maxLevel.rank
            }
        }
    }
}

@Serializable
enum class RoutingStrategy {
    fallback,
    loadBalance,
}

/**
 * [T-android-image-endpoint-mode] How an OpenAI-compatible provider routes
 * image-generation requests. Mirrors iOS `ImageEndpointMode`
 * (ProviderInstance.swift). Wire values (`images_generations` /
 * `chat_completions`) match iOS so JSON export/import interops cross-platform.
 *
 * - [auto]: try `/v1/images/generations` first; on a route-missing 4xx fall
 *   back to `/v1/chat/completions` and cache the working endpoint in
 *   `imageEndpointResolved` so the next call skips the probe.
 * - [imagesGenerations]: always `/v1/images/generations`.
 * - [chatCompletions]: always `/v1/chat/completions` (multimodal output) —
 *   i.e. the normal chat path, no special handling.
 */
@Serializable
enum class ImageEndpointMode {
    auto,
    @SerialName("images_generations") imagesGenerations,
    @SerialName("chat_completions") chatCompletions,
}

/**
 * Controls when fallback to the next model in the group is triggered.
 * - default: only on rate limiting (429) or server errors (5xx)
 * - always: on any error, including network errors, auth failures, etc.
 */
@Serializable
enum class FallbackStrategy {
    default,
    always,
}

@Serializable
data class ModelGroup(
    val id: String = UUID.randomUUID().toString(),
    var name: String,
    val memberEntryIds: MutableList<String> = mutableListOf(),
    var strategy: RoutingStrategy = RoutingStrategy.fallback,
    var fallbackStrategy: FallbackStrategy = FallbackStrategy.default,
    // Immutable definition ID so levelId/title edits never require migration.
    var defaultThinkingDefinitionId: String? = null,
    var contextLimitTokens: Int? = null,
    // T-ctxslider 54ab8e93: persisted memory of the last user-selected context
    // limit, so toggling the "Limit Context Window" switch OFF→leave→ON
    // restores the previous value instead of snapping back to 128K. Default
    // null lets old JSON deserialize cleanly (kotlinx.serialization).
    var lastContextLimitTokens: Int? = null,
)

@Serializable
data class ProviderInstance(
    val id: String,
    var label: String,
    val providerType: ProviderType,
    val credentialType: ProviderCredential,
    var isEnabled: Boolean = true,
    val createdAt: Long = System.currentTimeMillis(),
    var customBaseURL: String? = null,
    var appendV1Suffix: Boolean = true,
    var customRequestHeaders: List<String> = emptyList(),
    var customRequestBody: List<String> = emptyList(),
    // OpenAI-only: when true, traffic goes through /v1/responses instead of
    // /v1/chat/completions. Mirrors iOS `ProviderType.openAIResponses` flag,
    // but modeled here as a switch on the instance so an existing OpenAI
    // provider can be re-pointed without changing its type.
    var useResponsesAPI: Boolean = false,
    // [T-android-image-endpoint-mode] User-selected image-generation routing
    // for OpenAI-compatible providers (see ImageEndpointMode). Defaults keep
    // old persisted JSON (which lacks both keys) round-tripping cleanly:
    // kotlinx.serialization fills them with these declared defaults.
    var imageEndpointMode: ImageEndpointMode = ImageEndpointMode.auto,
    // Cached probe result for `auto` mode: the endpoint that last worked, so
    // subsequent calls skip the /images/generations probe. Cleared whenever
    // the user forces a mode. null = not yet probed.
    var imageEndpointResolved: ImageEndpointMode? = null,
    // [T-android-azure-openai] Azure OpenAI mode. When true, OpenAIProvider
    // auths with the `api-key:` header (not `Authorization: Bearer`) and treats
    // the custom base URL as an Azure endpoint (the user pastes the full Azure
    // URL including `?api-version=…`; the request routes as
    // {endpoint}/openai/deployments/{model}/{path}). Orthogonal to the
    // Chat/Responses API-format choice — both work under Azure. Defaults false
    // so existing OpenAI instances are completely unaffected. Field name
    // matches iOS for cross-platform export/import interop.
    var azureMode: Boolean = false,
) {
    /** Returns the effective API base URL, applying v1 suffix if configured. */
    val effectiveBaseURL: String?
        get() {
            val base = customBaseURL?.trimEnd('/') ?: return null
            return if (appendV1Suffix && !base.endsWith("/v1")) "$base/v1" else base
        }

    /**
     * [T-android-image-endpoint-mode] Whether the "Image Generation" endpoint
     * picker is surfaced for this instance. Mirrors iOS
     * `supportsImageEndpointSetting`. Android has no `openAIResponses` provider
     * type — an OpenAI instance carries the `useResponsesAPI` flag instead, so
     * the gate is just the three OpenAI-compatible types.
     */
    val supportsImageEndpointSetting: Boolean
        get() = providerType == ProviderType.openAI ||
            providerType == ProviderType.openRouter ||
            providerType == ProviderType.xAI

    /**
     * [T-android-azure-openai] Whether the Azure toggle applies to this
     * instance — only OpenAI instances using an API key (Azure auths with an
     * api-key header). Covers both Chat-Completions and Responses formats since
     * Android models Responses as the `useResponsesAPI` flag on an openAI
     * instance rather than a separate provider type. Mirrors iOS
     * supportsAzureMode.
     */
    val supportsAzureMode: Boolean
        get() = providerType == ProviderType.openAI && credentialType == ProviderCredential.apiKey
}

@Serializable
data class ModelOverrides(
    val displayName: String? = null,
    val maxOutputTokens: Int? = null,
    // Override the baseModel's context window (custom models only on iOS, but
    // we allow it on any entry here — mirrors iOS LLMModel.contextWindowTokens
    // being writable on custom entries).
    val contextWindow: Int? = null,
    // Override reasoning support flag (custom entries only, per iOS behavior).
    val supportsReasoning: Boolean? = null,
    // Modality overrides — mirror iOS ModelModality flags. Non-null means the
    // user explicitly flipped this dimension; null means "inherit baseModel".
    val inputModalities: List<String>? = null,
    val outputModalities: List<String>? = null,
    val customRequestHeaders: List<String> = emptyList(),
    val customRequestBody: List<String> = emptyList(),
    val requestBodyControls: List<RequestBodyControl> = emptyList(),
) {
    val isEmpty: Boolean
        get() = displayName == null
            && maxOutputTokens == null
            && contextWindow == null
            && supportsReasoning == null
            && inputModalities == null
            && outputModalities == null
            && customRequestHeaders.isEmpty()
            && customRequestBody.isEmpty()
            && requestBodyControls.isEmpty()
}

@Serializable
data class ModelEntry(
    val providerInstanceId: String,
    @SerialName("model")
    val baseModel: LLMModel,
    val overrides: ModelOverrides = ModelOverrides(),
    val isCustom: Boolean = false,
    val isHidden: Boolean = false,
    val uuid: String = UUID.randomUUID().toString(),
    val userModifiedAt: Long? = null,
) {
    val id: String get() = uuid

    /** Effective model as seen by the rest of the app: baseModel with overrides applied. */
    val model: LLMModel
        get() = if (overrides.isEmpty) baseModel else baseModel.copy(
            displayName = overrides.displayName ?: baseModel.displayName,
            maxOutputTokens = overrides.maxOutputTokens ?: baseModel.maxOutputTokens,
            contextWindow = overrides.contextWindow ?: baseModel.contextWindow,
            supportsReasoning = overrides.supportsReasoning ?: baseModel.supportsReasoning,
            inputModalities = overrides.inputModalities ?: baseModel.inputModalities,
            outputModalities = overrides.outputModalities ?: baseModel.outputModalities,
        )

    /** True when this entry carries user intent beyond API-reported defaults. */
    val isUserModified: Boolean
        get() = isCustom || isHidden || !overrides.isEmpty
}

@Serializable
data class ProviderConfig(
    val instances: MutableList<ProviderInstance> = mutableListOf(),
    val modelEntries: MutableList<ModelEntry> = mutableListOf(),
    val modelGroups: MutableList<ModelGroup> = mutableListOf(),
    var defaultPrimaryGroupId: String? = null,
    var defaultSubGroupId: String? = null,
    // [T-android-provider-voice] Voice Input / Voice Output group bindings —
    // mirrors iOS ProviderConfig.voiceInputGroupId / voiceOutputGroupId
    // (per-device, provider_local_kv on iOS; meta KV rows here). Old persisted
    // JSON lacks the keys and deserializes to null (ignoreUnknownKeys +
    // declared defaults), so adding them is downgrade/round-trip safe.
    var voiceInputGroupId: String? = null,
    var voiceOutputGroupId: String? = null,
    // Models and groups exposed to the agent loop (minis-model-use terminal
    // command) — mirrors iOS agentLoopModelEntryIds / agentLoopGroupIds.
    val agentLoopModelEntryIds: MutableList<String> = mutableListOf(),
    val agentLoopGroupIds: MutableList<String> = mutableListOf(),
    // T273: bumped by ProviderRepository.saveConfig on every mutation so
    // data-class structural equals returns false even when callers mutate
    // inner MutableLists in place. Without this, MutableStateFlow's
    // distinct-until-changed (uses equals, not ===) suppresses emission
    // and ProviderDetailScreen / ModelGroupDetailScreen miss refreshes.
    // @Transient: revision is in-memory only, never persisted to prefs
    // or iCloud sync.
    @kotlinx.serialization.Transient var revision: Long = 0L,
)
