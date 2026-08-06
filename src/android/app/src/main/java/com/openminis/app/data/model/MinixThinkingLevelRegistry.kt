package com.openminis.app.data.model

import android.content.Context
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.util.UUID

// [Minix] App-level semantic thinking definitions and immutable references.

@Serializable
data class ThinkingLevelDefinition(
    val definitionId: String = UUID.randomUUID().toString(),
    val levelId: String,
    val title: String,
    val rank: Int,
    val isBuiltIn: Boolean = false,
)

object ThinkingLevelRegistry {
    private const val PREFS = "request_controls_thinking_levels"
    private const val DEFINITIONS = "definitions"
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    val offDefinitionId: String = ThinkingLevel.OFF.name.lowercase()
    private val builtInLevelOrder = listOf(
        ThinkingLevel.OFF,
        ThinkingLevel.MINIMAL,
        ThinkingLevel.LOW,
        ThinkingLevel.MEDIUM,
        ThinkingLevel.HIGH,
        ThinkingLevel.XHIGH,
        ThinkingLevel.MAX,
        ThinkingLevel.ULTRA,
    )

    val builtInDefinitions: List<ThinkingLevelDefinition> =
        builtInLevelOrder.mapIndexed { index, level ->
            ThinkingLevelDefinition(
                definitionId = level.name.lowercase(),
                levelId = level.name.lowercase(),
                title = level.displayName,
                rank = index,
                isBuiltIn = true,
            )
        }

    fun definitions(context: Context?): List<ThinkingLevelDefinition> {
        val encoded = context
            ?.applicationContext
            ?.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            ?.getString(DEFINITIONS, null)
            ?: return builtInDefinitions
        val stored = runCatching {
            json.decodeFromString(
                ListSerializer(ThinkingLevelDefinition.serializer()),
                encoded,
            )
        }.getOrDefault(emptyList())
        return completedDefinitions(stored)
    }

    fun saveDefinitions(
        context: Context,
        definitions: List<ThinkingLevelDefinition>,
    ) {
        val cleaned = cleanedDefinitions(definitions)
            .mapIndexed { index, definition ->
                definition.copy(rank = index)
            }
        val encoded = json.encodeToString(
            ListSerializer(ThinkingLevelDefinition.serializer()),
            cleaned,
        )
        context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(DEFINITIONS, encoded)
            .apply()
    }

    internal fun completedDefinitions(
        stored: List<ThinkingLevelDefinition>,
    ): List<ThinkingLevelDefinition> {
        val cleaned = cleanedDefinitions(stored)
            .sortedWith(
                compareBy<ThinkingLevelDefinition> { it.rank }
                    .thenBy { it.definitionId },
            )
        if (cleaned.isEmpty()) return builtInDefinitions

        val knownIds = cleaned.mapTo(mutableSetOf()) {
            it.definitionId
        }
        return (
            cleaned + builtInDefinitions.filter {
                it.definitionId !in knownIds
            }
            ).mapIndexed { index, definition ->
            definition.copy(rank = index)
        }
    }

    internal fun cleanedDefinitions(
        raw: List<ThinkingLevelDefinition>,
    ): List<ThinkingLevelDefinition> {
        val seenDefinitionIds = mutableSetOf<String>()
        val seenLevelIds = mutableSetOf<String>()
        return raw.mapNotNull { definition ->
            val definitionId = definition.definitionId.trim()
            val levelId = normalizedLevelId(definition.levelId)
            val builtIn = builtInDefinitions.firstOrNull {
                it.definitionId == definitionId
            }
            val resolvedLevelId = builtIn?.levelId ?: levelId
            if (
                definitionId.isEmpty() ||
                resolvedLevelId.isEmpty() ||
                (
                    builtIn == null &&
                        builtInDefinitions.any {
                            it.levelId == resolvedLevelId
                        }
                    ) ||
                !seenDefinitionIds.add(definitionId) ||
                !seenLevelIds.add(resolvedLevelId)
            ) {
                return@mapNotNull null
            }
            definition.copy(
                definitionId = definitionId,
                levelId = resolvedLevelId,
                title = builtIn?.title
                    ?: definition.title.trim()
                        .ifEmpty { resolvedLevelId },
                isBuiltIn = builtIn != null,
            )
        }
    }

    fun mergedDefinitions(
        local: List<ThinkingLevelDefinition>,
        incoming: List<ThinkingLevelDefinition>,
    ): List<ThinkingLevelDefinition> {
        val result = local
            .sortedWith(compareBy<ThinkingLevelDefinition> { it.rank }.thenBy { it.definitionId })
            .toMutableList()
        val knownIds = result.mapTo(mutableSetOf()) { it.definitionId }
        val incomingOrdered = incoming
            .sortedWith(compareBy<ThinkingLevelDefinition> { it.rank }.thenBy { it.definitionId })

        incomingOrdered.forEachIndexed { index, definition ->
            if (definition.definitionId in knownIds) return@forEachIndexed
            val semanticMatch = result.firstOrNull {
                it.levelId == definition.levelId
            }
            if (semanticMatch != null) {
                return@forEachIndexed
            }
            val nextKnownId = incomingOrdered
                .drop(index + 1)
                .firstOrNull { it.definitionId in knownIds }
                ?.definitionId
            val insertionIndex = nextKnownId
                ?.let { id ->
                    result.indexOfFirst {
                        it.definitionId == id
                    }
                }
                ?.takeIf { it >= 0 }
                ?: result.size
            result.add(insertionIndex, definition.copy(isBuiltIn = false))
            knownIds += definition.definitionId
        }

        return result.mapIndexed { index, definition -> definition.copy(rank = index) }
    }

    fun resolvedDefinitionId(
        requestedDefinitionId: String,
        availableDefinitionIds: List<String>,
    ): String? = resolvedDefinitionId(
        requestedDefinitionId,
        availableDefinitionIds,
        null,
    )

    fun resolvedDefinitionId(
        requestedDefinitionId: String,
        availableDefinitionIds: List<String>,
        context: Context?,
    ): String? {
        if (requestedDefinitionId in availableDefinitionIds) {
            return requestedDefinitionId
        }
        val allDefinitions = definitions(context)
        val requestedRank = allDefinitions.firstOrNull {
            it.definitionId == requestedDefinitionId
        }?.rank ?: return if (
            offDefinitionId in
            availableDefinitionIds
        ) {
            offDefinitionId
        } else {
            availableDefinitionIds.firstOrNull()
        }
        val available = availableDefinitionIds.toSet()
        return allDefinitions
            .asSequence()
            .filter {
                it.definitionId in available &&
                    it.rank <= requestedRank
            }
            .maxByOrNull { it.rank }
            ?.definitionId
            ?: if (
                offDefinitionId in
                available
            ) {
                offDefinitionId
            } else {
                availableDefinitionIds.firstOrNull()
            }
    }

    fun nativeLevel(
        definitionId: String?,
        context: Context? = null,
    ): ThinkingLevel {
        val allDefinitions = definitions(context)
        val definition = allDefinitions
            .firstOrNull {
                it.definitionId == definitionId
            } ?: return ThinkingLevel.OFF
        if (definition.isBuiltIn) {
            ThinkingLevel.entries.firstOrNull {
                it.name.equals(
                    definition.levelId,
                    ignoreCase = true,
                )
            }?.let { return it }
        }
        val requestedRank = definition.rank
        return allDefinitions
            .filter {
                it.isBuiltIn &&
                    it.rank <= requestedRank
            }
            .maxByOrNull { it.rank }
            ?.levelId
            ?.let { levelId ->
                ThinkingLevel.entries.firstOrNull {
                    it.name.equals(
                        levelId,
                        ignoreCase = true,
                    )
                }
            }
            ?: ThinkingLevel.OFF
    }

    fun normalizedLevelId(raw: String): String =
        raw.trim()
            .lowercase()
            .replace(Regex("[^a-z0-9_]"), "_")

    fun definition(
        definitionId: String?,
        context: Context? = null,
    ): ThinkingLevelDefinition? =
        definitions(context).firstOrNull {
            it.definitionId == definitionId
        }

    fun definitionForLevelId(
        rawLevelId: String?,
        context: Context? = null,
    ): ThinkingLevelDefinition? {
        val levelId = rawLevelId?.let(::normalizedLevelId)
            ?: return null
        return definitions(context).firstOrNull {
            it.levelId == levelId
        }
    }

    fun rank(
        definitionId: String?,
        context: Context? = null,
    ): Int =
        definition(definitionId, context)?.rank
            ?: Int.MAX_VALUE

    fun title(
        definitionId: String?,
        context: Context? = null,
    ): String? =
        definition(definitionId, context)?.title

    fun sortedThinkingOptions(options: List<RequestBodyControlOption>, context: Context? = null): List<RequestBodyControlOption> =
        options.sortedWith(
            compareBy<RequestBodyControlOption> {
                rank(it.thinkingDefinitionId, context)
            }
                .thenBy { it.title },
        )
}

fun ProviderConfig.thinkingDefinitionReferenceCount(
    definitionId: String,
): Int {
    val modelReferences = modelEntries.sumOf { entry ->
        entry.overrides.requestBodyControls.sumOf { control ->
            control.options.count {
                it.thinkingDefinitionId == definitionId
            }
        }
    }
    val groupReferences = modelGroups.count {
        it.defaultThinkingDefinitionId == definitionId
    }
    return modelReferences + groupReferences
}
