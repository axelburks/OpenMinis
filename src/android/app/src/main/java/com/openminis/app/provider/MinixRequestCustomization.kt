package com.openminis.app.provider

import android.content.Context
import com.openminis.app.data.model.LLMModel
import com.openminis.app.data.model.ModelEntry
import com.openminis.app.data.model.ProviderCredential
import com.openminis.app.data.model.ProviderInstance
import com.openminis.app.data.model.ProviderType
import com.openminis.app.data.model.RequestBodyControl
import com.openminis.app.data.model.RequestBodyControlOption
import com.openminis.app.data.model.RequestBodyControlRuntimeSnapshot
import com.openminis.app.data.model.RequestBodyControlState
import com.openminis.app.data.model.ThinkingLevel
import com.openminis.app.data.model.ThinkingLevelRegistry
import kotlinx.serialization.json.Json
import org.json.JSONObject

data class RequestCustomizationContext(
    val provider: ProviderInstance,
    val model: LLMModel,
    val apiKey: String?,
    val sessionId: String?,
    val headers: Map<String, String>,
    val body: JSONObject,
)

object RequestExpressionValidator {
    enum class Target { HEADER, BODY, CONTROL }

    enum class ErrorKind {
        MISSING_ASSIGNMENT,
        EMPTY_VALUE,
        UNBALANCED_DELIMITER,
        INVALID_PATH,
        UNKNOWN_FUNCTION,
        INVALID_FUNCTION_ARGUMENTS,
        EVALUATION_LIMIT,
        UNKNOWN_TEMPLATE_REFERENCE,
    }

    data class Issue(
        val line: Int,
        val kind: ErrorKind,
    )

    fun validate(lines: List<String>, target: Target): List<Issue> {
        val minixTarget = when (target) {
            Target.HEADER -> MinixRequestExpression.Target.HEADER
            Target.BODY -> MinixRequestExpression.Target.BODY
            Target.CONTROL -> MinixRequestExpression.Target.CONTROL
        }
        return MinixRequestExpression
            .validate(lines, minixTarget)
            .map { Issue(it.line, it.kind) }
    }
}

data class RequestCustomization(
    val provider: ProviderInstance,
    val modelEntry: ModelEntry?,
    var sessionId: String? = null,
    val context: Context? = null,
    var thinkingDefinitionId: String? = null,
    var usesConversationRequestControlState: Boolean = false,
) {
    companion object {
        fun providerHeadersForModelList(
            provider: ProviderInstance,
            apiKey: String?,
            initialHeaders: Map<String, String>,
        ): Map<String, String> {
            val headers = initialHeaders.toMutableMap()
            val requestContext = RequestCustomizationContext(
                provider = provider,
                model = LLMModel(id = "", displayName = "", provider = provider.providerType.name),
                apiKey = apiKey,
                sessionId = null,
                headers = headers,
                body = JSONObject(),
            )
            applyHeaderExpressions(
                provider.customRequestHeaders,
                headers,
                requestContext,
            )
            return headers
        }
    }

    val modelControls: List<RequestBodyControl>
        get() = modelEntry?.overrides?.requestBodyControls ?: emptyList()

    val disablesBuiltInThinkingInjection: Boolean
        get() = modelControls.any { control ->
            control.isEnabled &&
                control.semanticKind == RequestBodyControl.SemanticKind.thinkingBudget
        }

    fun resolvedThinkingDefinitionId(
        requestedDefinitionId: String,
    ): String? {
        val thinkingControl = modelControls.firstOrNull {
            it.isEnabled &&
                it.semanticKind == RequestBodyControl.SemanticKind.thinkingBudget
        }
        val availableIds = if (thinkingControl != null) {
            ThinkingLevelRegistry
                .sortedThinkingOptions(thinkingControl.options, context)
                .mapNotNull { option ->
                    option.thinkingDefinitionId
                        ?.takeIf {
                            ThinkingLevelRegistry
                                .definition(
                                    it,
                                    context,
                                ) != null
                        }
                }
        } else {
            com.openminis.app.data.model.ThinkingLevel
                .availableLevels(modelEntry?.model ?: return null)
                .mapNotNull {
                    ThinkingLevelRegistry
                        .definitionForLevelId(
                            it.name.lowercase(),
                            context,
                        )?.definitionId
                }
        }
        return ThinkingLevelRegistry.resolvedDefinitionId(
            requestedDefinitionId,
            availableIds,
            context,
        )
    }

    fun thinkingDefinitionIdForRequest(
        explicitDefinitionId: String?,
        thinkingLevel: ThinkingLevel,
    ): String? {
        if (explicitDefinitionId != null) return explicitDefinitionId
        if (!usesConversationRequestControlState) return null
        return ThinkingLevelRegistry
            .definitionForLevelId(
                thinkingLevel.name.lowercase(),
                context,
            )?.definitionId
    }

    fun apply(
        body: JSONObject,
        headers: MutableMap<String, String>,
        apiKey: String?,
        includeControls: Boolean = true,
    ) {
        val model = modelEntry?.model ?: LLMModel(id = "", displayName = "", provider = "")
        var requestContext = RequestCustomizationContext(provider, model, apiKey, sessionId, headers, body)
        applyHeaderExpressions(
            provider.customRequestHeaders,
            headers,
            requestContext,
        )
        requestContext = RequestCustomizationContext(provider, model, apiKey, sessionId, headers, body)
        mergeInto(body, parseBodyExpressions(provider.customRequestBody, requestContext))
        requestContext = RequestCustomizationContext(provider, model, apiKey, sessionId, headers, body)
        applyHeaderExpressions(
            modelEntry?.overrides?.customRequestHeaders ?: emptyList(),
            headers,
            requestContext,
        )
        requestContext = RequestCustomizationContext(provider, model, apiKey, sessionId, headers, body)
        mergeInto(body, parseBodyExpressions(modelEntry?.overrides?.customRequestBody ?: emptyList(), requestContext))
        if (!includeControls) return
        val state = RequestBodyControlRuntimeStore.state(
            context = context,
            sessionKey = sessionId,
            modelKey = modelEntry?.id ?: model.id,
            controls = modelControls,
            useConversationState =
                usesConversationRequestControlState,
        )
        for (control in modelControls.filter { it.isEnabled }) {
            val lines = when (control.kind) {
                RequestBodyControl.Kind.toggle -> {
                    val enabled = state.toggleValuesByControlID[control.id] ?: control.defaultIsActive
                    if (enabled) control.payloadExpressions else emptyList()
                }
                RequestBodyControl.Kind.optionGroup -> selectedOption(control, state)?.payloadExpressions ?: emptyList()
            }
            requestContext = RequestCustomizationContext(provider, model, apiKey, sessionId, headers, body)
            applyControlExpressions(
                lines,
                body,
                headers,
                requestContext,
            )
        }
    }

    private fun selectedOption(control: RequestBodyControl, state: RequestBodyControlState): RequestBodyControlOption? {
        val options = if (control.semanticKind == RequestBodyControl.SemanticKind.thinkingBudget) {
            ThinkingLevelRegistry.sortedThinkingOptions(control.options, context)
        } else {
            control.options
        }
        if (options.isEmpty()) return null
        if (control.semanticKind == RequestBodyControl.SemanticKind.thinkingBudget) {
            val requestedDefinitionId =
                thinkingDefinitionId
            if (requestedDefinitionId != null) {
                val resolvedDefinitionId =
                    ThinkingLevelRegistry.resolvedDefinitionId(
                    requestedDefinitionId,
                    options.mapNotNull { option ->
                        option.thinkingDefinitionId
                            ?.takeIf {
                                ThinkingLevelRegistry
                                    .definition(
                                        it,
                                        context,
                                    ) != null
                            }
                    },
                    context,
                )
                return options.firstOrNull {
                    it.thinkingDefinitionId ==
                        resolvedDefinitionId
                } ?: options.firstOrNull {
                    it.thinkingDefinitionId ==
                        requestedDefinitionId
                }
            }
        }
        val optionId =
            state.selectedOptionIDsByControlID[control.id]
                ?: control.defaultOptionID
        return options.firstOrNull { it.id == optionId } ?: options.first()
    }
}

object RequestBodyControlDefaults {
    fun thinkingOptionGroup(instance: ProviderInstance?): RequestBodyControl {
        val levels = latestTemplateLevels(instance?.providerType)
        return RequestBodyControl(
            title = "Thinking Intensity",
            iconName = "lightbulb",
            kind = RequestBodyControl.Kind.optionGroup,
            semanticKind = RequestBodyControl.SemanticKind.thinkingBudget,
            defaultOptionID = null,
            isSliderEnabled = true,
            options = levels.map { level ->
                val definition =
                    ThinkingLevelRegistry
                        .definitionForLevelId(
                            level.name.lowercase(),
                        )
                RequestBodyControlOption(
                    id = definition?.definitionId
                        ?: level.name.lowercase(),
                    thinkingDefinitionId =
                        definition?.definitionId,
                    title = level.displayName,
                    payloadExpressions = thinkingExpressions(
                        instance,
                        level,
                    ),
                )
            },
        )
    }

    private fun latestTemplateLevels(
        providerType: ProviderType?,
    ): List<ThinkingLevel> {
        return when (providerType) {
            ProviderType.openAI, ProviderType.openAIResponses,
            ProviderType.kimiCode, ProviderType.openRouter,
            ProviderType.githubCopilot ->
                listOf(ThinkingLevel.OFF, ThinkingLevel.MINIMAL, ThinkingLevel.LOW, ThinkingLevel.MEDIUM, ThinkingLevel.HIGH, ThinkingLevel.XHIGH, ThinkingLevel.MAX)
            ProviderType.xAI ->
                listOf(ThinkingLevel.OFF, ThinkingLevel.LOW, ThinkingLevel.MEDIUM, ThinkingLevel.HIGH)
            ProviderType.anthropic ->
                listOf(ThinkingLevel.OFF, ThinkingLevel.LOW, ThinkingLevel.MEDIUM, ThinkingLevel.HIGH, ThinkingLevel.XHIGH, ThinkingLevel.MAX)
            ProviderType.gemini, ProviderType.antigravity ->
                listOf(ThinkingLevel.MINIMAL, ThinkingLevel.LOW, ThinkingLevel.MEDIUM, ThinkingLevel.HIGH)
            ProviderType.unsupported, null ->
                listOf(ThinkingLevel.OFF, ThinkingLevel.LOW, ThinkingLevel.MEDIUM, ThinkingLevel.HIGH, ThinkingLevel.XHIGH)
        }
    }

    internal fun thinkingExpressions(
        instance: ProviderInstance?,
        level: ThinkingLevel,
    ): List<String> {
        // [Minix] Match ProviderFactory routing, not only the optional toggle:
        // the dedicated type and first-party Codex OAuth also force Responses.
        val responses = when {
            instance == null -> false
            instance.providerType == ProviderType.openAIResponses -> true
            instance.providerType != ProviderType.openAI -> false
            instance.useResponsesAPI -> true
            instance.credentialType == ProviderCredential.oauth &&
                instance.customBaseURL.isNullOrBlank() -> true
            else -> false
        }
        val providerType = instance?.providerType
        return when {
            responses -> listOf("body.reasoning = {effort: \"${reasoningEffort(level)}\", summary: \"auto\"}")
            providerType == ProviderType.anthropic && level == com.openminis.app.data.model.ThinkingLevel.OFF ->
                listOf("body.thinking = {type: \"disabled\"}")
            providerType == ProviderType.anthropic ->
                listOf(
                    "body.thinking = {type: \"adaptive\", display: \"summarized\"}",
                    "body.output_config.effort = \"${anthropicEffort(level)}\"",
                )
            providerType == ProviderType.gemini ||
                providerType == ProviderType.antigravity ->
                listOf("body.generationConfig.thinkingConfig = {thinkingLevel: \"${geminiEffort(level)}\", includeThoughts: true}")
            else -> listOf("body.reasoning_effort = \"${reasoningEffort(level)}\"")
        }
    }

    internal fun thinkingExpressions(
        instance: ProviderInstance?,
        definition: com.openminis.app.data.model.ThinkingLevelDefinition,
    ): List<String> =
        ThinkingLevel.parseOrNull(definition.levelId)
            ?.let { thinkingExpressions(instance, it) }
            ?: emptyList()

    private fun reasoningEffort(level: com.openminis.app.data.model.ThinkingLevel): String =
        if (level == com.openminis.app.data.model.ThinkingLevel.OFF) "none" else level.name.lowercase()

    private fun anthropicEffort(level: com.openminis.app.data.model.ThinkingLevel): String = when (level) {
        com.openminis.app.data.model.ThinkingLevel.OFF,
        com.openminis.app.data.model.ThinkingLevel.MINIMAL,
        com.openminis.app.data.model.ThinkingLevel.LOW -> "low"
        com.openminis.app.data.model.ThinkingLevel.MEDIUM -> "medium"
        com.openminis.app.data.model.ThinkingLevel.HIGH -> "high"
        com.openminis.app.data.model.ThinkingLevel.XHIGH,
        com.openminis.app.data.model.ThinkingLevel.MAX,
        com.openminis.app.data.model.ThinkingLevel.ULTRA -> "max"
    }

    private fun geminiEffort(level: com.openminis.app.data.model.ThinkingLevel): String = when (level) {
        com.openminis.app.data.model.ThinkingLevel.OFF,
        com.openminis.app.data.model.ThinkingLevel.MINIMAL -> "minimal"
        com.openminis.app.data.model.ThinkingLevel.LOW -> "low"
        com.openminis.app.data.model.ThinkingLevel.MEDIUM -> "medium"
        com.openminis.app.data.model.ThinkingLevel.HIGH,
        com.openminis.app.data.model.ThinkingLevel.XHIGH,
        com.openminis.app.data.model.ThinkingLevel.MAX,
        com.openminis.app.data.model.ThinkingLevel.ULTRA -> "high"
    }
}

object RequestBodyControlRuntimeStore {
    private const val PREFS = "request_body_control_state"
    private const val PREFIX = "session."
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    fun state(
        context: Context?,
        sessionKey: String?,
        modelKey: String,
        controls: List<RequestBodyControl>,
        useConversationState: Boolean = true,
    ): RequestBodyControlState {
        if (
            !useConversationState ||
            sessionKey.isNullOrEmpty()
        ) {
            return RequestBodyControlState()
        }
        val encoded = context
            ?.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            ?.getString(
                storageKey(sessionKey),
                null,
            )
        val snapshot = encoded?.let {
            runCatching {
                json.decodeFromString<
                    RequestBodyControlRuntimeSnapshot
                    >(it)
            }.getOrNull()
        } ?: return RequestBodyControlState()
        if (snapshot.activeModelKey != modelKey) {
            return RequestBodyControlState()
        }
        return normalized(snapshot.state, controls)
    }

    fun save(
        context: Context,
        sessionKey: String?,
        modelKey: String,
        controls: List<RequestBodyControl>,
        state: RequestBodyControlState,
    ) {
        if (sessionKey.isNullOrEmpty()) return
        val snapshot = RequestBodyControlRuntimeSnapshot(
            activeModelKey = modelKey,
            state = normalized(state, controls),
        )
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(
                storageKey(sessionKey),
                json.encodeToString(
                    RequestBodyControlRuntimeSnapshot
                        .serializer(),
                    snapshot,
                ),
            )
            .apply()
    }

    fun activateModel(
        context: Context,
        sessionKey: String?,
        modelKey: String,
    ) {
        if (sessionKey.isNullOrEmpty()) return
        val preferences =
            context.getSharedPreferences(
                PREFS,
                Context.MODE_PRIVATE,
            )
        val key = storageKey(sessionKey)
        val existing = preferences.getString(key, null)
            ?.let {
                runCatching {
                    json.decodeFromString<
                        RequestBodyControlRuntimeSnapshot
                        >(it)
                }.getOrNull()
            }
        if (existing?.activeModelKey == modelKey) {
            return
        }
        preferences.edit()
            .putString(
                key,
                json.encodeToString(
                    RequestBodyControlRuntimeSnapshot
                        .serializer(),
                    RequestBodyControlRuntimeSnapshot(
                        activeModelKey = modelKey,
                        state = RequestBodyControlState(),
                    ),
                ),
            )
            .apply()
    }

    fun migrate(
        context: Context,
        fromSessionKey: String,
        toSessionKey: String,
    ) {
        if (
            fromSessionKey.isEmpty() ||
            toSessionKey.isEmpty() ||
            fromSessionKey == toSessionKey
        ) {
            return
        }
        val preferences =
            context.getSharedPreferences(
                PREFS,
                Context.MODE_PRIVATE,
            )
        val sourceKey = storageKey(fromSessionKey)
        val destinationKey = storageKey(toSessionKey)
        val editor = preferences.edit()
        if (!preferences.contains(destinationKey)) {
            preferences.getString(sourceKey, null)
                ?.let {
                    editor.putString(destinationKey, it)
                }
        }
        editor.remove(sourceKey)
        editor.apply()
    }

    internal fun storageKey(
        sessionKey: String,
    ): String =
        PREFIX + sessionKey

    private fun normalized(state: RequestBodyControlState, controls: List<RequestBodyControl>): RequestBodyControlState {
        val toggleIds = controls.filter { it.kind == RequestBodyControl.Kind.toggle }.map { it.id }.toSet()
        val optionIds = controls
            .filter { it.kind == RequestBodyControl.Kind.optionGroup }
            .associate { it.id to it.options.map { option -> option.id }.toSet() }
        return RequestBodyControlState(
            toggleValuesByControlID = state.toggleValuesByControlID.filterKeys { it in toggleIds },
            selectedOptionIDsByControlID = state.selectedOptionIDsByControlID.filter { (controlId, optionId) ->
                optionIds[controlId]?.contains(optionId) == true
            },
        )
    }
}

private fun applyHeaderExpressions(
    lines: List<String>,
    headers: MutableMap<String, String>,
    context: RequestCustomizationContext,
) {
    MinixRequestExpression.applyHeaders(lines, headers, context)
}

private fun parseBodyExpressions(
    lines: List<String>,
    context: RequestCustomizationContext,
): JSONObject = MinixRequestExpression.parseBody(lines, context)

private fun applyControlExpressions(
    lines: List<String>,
    body: JSONObject,
    headers: MutableMap<String, String>,
    context: RequestCustomizationContext,
) {
    MinixRequestExpression.applyControls(
        lines,
        body,
        headers,
        context,
    )
}

private fun mergeInto(base: JSONObject, overlay: JSONObject) {
    overlay.keys().forEach { key ->
        val value = overlay.opt(key)
        val existing = base.opt(key)
        when {
            value === MinixDeleteMarker -> base.remove(key)
            existing is JSONObject && value is JSONObject ->
                mergeInto(existing, value)
            value is JSONObject ->
                base.put(key, JSONObject().also {
                    mergeInto(it, value)
                })
            else -> base.put(key, value)
        }
    }
}
