package com.openminis.app.data

import com.openminis.app.data.model.ModelGroup
import com.openminis.app.data.model.ModelEntry
import com.openminis.app.data.model.ModelOverrides
import com.openminis.app.data.model.LLMModel
import com.openminis.app.data.model.ProviderConfig
import com.openminis.app.data.model.RequestBodyControl
import com.openminis.app.data.model.RequestBodyControlOption
import com.openminis.app.data.model.ThinkingLevel
import com.openminis.app.data.model.ThinkingLevelDefinition
import com.openminis.app.data.model.ThinkingLevelRegistry
import com.openminis.app.data.model.thinkingDefinitionReferenceCount
import com.openminis.app.ui.components.RequestControlIcons
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ThinkingLevelTest {

    @Test
    fun rank_followsDeclarationOrder() {
        assertEquals(0, ThinkingLevel.OFF.rank)
        assertEquals(1, ThinkingLevel.MINIMAL.rank)
        assertEquals(5, ThinkingLevel.XHIGH.rank)
        assertEquals(6, ThinkingLevel.MAX.rank)
        assertEquals(7, ThinkingLevel.ULTRA.rank)
        // Sanity: intersection/clamp via rank works as expected.
        assertEquals(
            ThinkingLevel.HIGH,
            minOf(ThinkingLevel.ULTRA, ThinkingLevel.HIGH, compareBy { it.rank }),
        )
    }

    @Test
    fun builtInDefinitions_startWithOffForDefaultUIOrder() {
        assertEquals(
            "off",
            ThinkingLevelRegistry.builtInDefinitions
                .first()
                .definitionId,
        )
    }

    @Test
    fun completedDefinitions_preservesStoredBuiltInOrderAndAppendsMissingDefinitions() {
        val stored = listOf(
            ThinkingLevelRegistry.builtInDefinitions[0].copy(
                rank = 0,
                title = "Ignored",
                isBuiltIn = false,
            ),
            ThinkingLevelDefinition(
                definitionId = "custom-uuid",
                levelId = "custom_level",
                title = "Custom",
                rank = 1,
            ),
            ThinkingLevelRegistry.builtInDefinitions[3].copy(
                rank = 2,
            ),
            ThinkingLevelRegistry.builtInDefinitions[1].copy(
                rank = 3,
            ),
        )

        val completed =
            ThinkingLevelRegistry.completedDefinitions(stored)

        assertEquals(
            listOf(
                "off",
                "custom-uuid",
                "medium",
                "minimal",
                "low",
                "high",
                "xhigh",
                "max",
                "ultra",
            ),
            completed.map { it.definitionId },
        )
        assertEquals(
            completed.indices.toList(),
            completed.map { it.rank },
        )
        assertEquals(
            ThinkingLevel.OFF.displayName,
            completed.first().title,
        )
        assertTrue(completed.first().isBuiltIn)
    }

    @Test
    fun cleanedDefinitions_rejectsDuplicateAndBuiltInSemanticAliases() {
        val cleaned = ThinkingLevelRegistry.cleanedDefinitions(
            listOf(
                ThinkingLevelDefinition(
                    definitionId = " custom-uuid ",
                    levelId = " Custom-Level ",
                    title = " Custom ",
                    rank = 0,
                ),
                ThinkingLevelDefinition(
                    definitionId = "custom-uuid",
                    levelId = "duplicate_id",
                    title = "Duplicate",
                    rank = 1,
                ),
                ThinkingLevelDefinition(
                    definitionId = "other-uuid",
                    levelId = "custom_level",
                    title = "Duplicate Alias",
                    rank = 2,
                ),
                ThinkingLevelDefinition(
                    definitionId = "fake-off",
                    levelId = "off",
                    title = "Fake Off",
                    rank = 3,
                ),
            ),
        )

        assertEquals(1, cleaned.size)
        assertEquals("custom-uuid", cleaned.single().definitionId)
        assertEquals("custom_level", cleaned.single().levelId)
        assertEquals("Custom", cleaned.single().title)
    }

    @Test
    fun modelReasoningOverride_canForceBothDirections() {
        val baseOff = LLMModel(
            id = "base-off",
            displayName = "Base Off",
            provider = "Test",
            supportsReasoning = false,
        )
        val baseOn = baseOff.copy(
            id = "base-on",
            displayName = "Base On",
            supportsReasoning = true,
        )

        assertEquals(
            true,
            ModelEntry(
                providerInstanceId = "provider",
                baseModel = baseOff,
                overrides = ModelOverrides(
                    supportsReasoning = true,
                ),
            ).model.supportsReasoning,
        )
        assertEquals(
            false,
            ModelEntry(
                providerInstanceId = "provider",
                baseModel = baseOn,
                overrides = ModelOverrides(
                    supportsReasoning = false,
                ),
            ).model.supportsReasoning,
        )
    }

    /**
     * The repository's Json instance uses coerceInputValues so an unknown enum
     * value in a persisted blob falls back to the property default instead of
     * throwing SerializationException. This is what stops a newer-build config
     * from wiping the UI when read by an older build.
     */
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        coerceInputValues = true
    }

    @Test
    fun modelGroup_customThinkingDefinitionId_roundTrips() {
        val wire = """{"id":"g1","name":"G","memberEntryIds":[],"defaultThinkingDefinitionId":"custom-uuid"}"""
        val group = json.decodeFromString(ModelGroup.serializer(), wire)
        val encoded = json.encodeToString(ModelGroup.serializer(), group)

        assertTrue(encoded.contains(""""defaultThinkingDefinitionId":"custom-uuid""""))
        assertEquals("G", group.name)
    }

    @Test
    fun requestControl_iconName_roundTripsAndLevelIdUsesRestrictedAlphabet() {
        val overrides = ModelOverrides(
            requestBodyControls = listOf(
                RequestBodyControl(
                    title = "Web Search",
                    iconName = "globe",
                    kind = RequestBodyControl.Kind.toggle,
                    sliderStartColorHex = "#123456",
                    sliderEndColorHex = "#ABCDEF",
                ),
            ),
        )
        val encoded = json.encodeToString(ModelOverrides.serializer(), overrides)
        val decoded = json.decodeFromString(ModelOverrides.serializer(), encoded)

        assertEquals("globe", decoded.requestBodyControls.single().iconName)
        assertEquals(
            "#123456",
            decoded.requestBodyControls.single().sliderStartColorHex,
        )
        assertEquals(
            "#ABCDEF",
            decoded.requestBodyControls.single().sliderEndColorHex,
        )
        assertEquals(
            "custom_level_1",
            ThinkingLevelRegistry.normalizedLevelId(" Custom-Level.1 "),
        )
    }

    @Test
    fun immutableDefinitionId_survivesAliasRenameWithoutReferenceMigration() {
        val definitionId = "custom-definition-uuid"
        val optionID = "stable-option-id"
        val control = RequestBodyControl(
            id = "thinking-control",
            title = "Thinking",
            kind = RequestBodyControl.Kind.optionGroup,
            semanticKind =
                RequestBodyControl.SemanticKind.thinkingBudget,
            options = listOf(
                RequestBodyControlOption(
                    id = optionID,
                    thinkingDefinitionId = definitionId,
                    title = "Custom",
                ),
                RequestBodyControlOption(
                    id = "high-option",
                    thinkingDefinitionId = "high",
                    title = "High",
                ),
            ),
        )
        val config = ProviderConfig(
            modelEntries = mutableListOf(
                ModelEntry(
                    providerInstanceId = "provider",
                    baseModel = LLMModel(
                        id = "model",
                        displayName = "Model",
                        provider = "Test",
                        supportsReasoning = true,
                    ),
                    overrides = ModelOverrides(
                        requestBodyControls =
                            listOf(control),
                    ),
                ),
            ),
            modelGroups = mutableListOf(
                ModelGroup(
                    name = "Group",
                    defaultThinkingDefinitionId =
                        definitionId,
                ),
            ),
        )

        val original = ThinkingLevelDefinition(
            definitionId = definitionId,
            levelId = "custom_old",
            title = "Custom",
            rank = 4,
        )
        val renamed = original.copy(
            levelId = "custom_new",
        )

        assertEquals(definitionId, renamed.definitionId)
        val options =
            config.modelEntries.single()
                .overrides.requestBodyControls
                .single().options
        assertEquals(optionID, options[0].id)
        assertEquals(
            definitionId,
            options[0].thinkingDefinitionId,
        )
        assertEquals(
            "high",
            options[1].thinkingDefinitionId,
        )
        assertEquals(
            definitionId,
            config.modelGroups.single()
                .defaultThinkingDefinitionId,
        )
        assertEquals(
            2,
            config.thinkingDefinitionReferenceCount(
                definitionId,
            ),
        )
    }

    @Test
    fun requestControl_materialIconCatalogIsCompleteAndUnknownNameFallsBack() {
        assertTrue(RequestControlIcons.choices.size > 2_000)

        val control = RequestBodyControl(
            title = "Toggle",
            iconName = "not.a.real.icon",
            kind = RequestBodyControl.Kind.toggle,
        )
        assertEquals(
            RequestControlIcons.TOGGLE,
            RequestControlIcons.resolve(control).id,
        )
    }

    @Test
    fun testThinkingLevelRegistry_resolvesExactThenClampsByRank_BitsUT() {
        assertEquals(
            "max",
            ThinkingLevelRegistry.resolvedDefinitionId(
                "max",
                listOf("low", "max", "medium"),
            ),
        )
        assertEquals(
            "high",
            ThinkingLevelRegistry.resolvedDefinitionId(
                "max",
                listOf("off", "low", "high"),
            ),
        )
        assertEquals(
            "off",
            ThinkingLevelRegistry.resolvedDefinitionId(
                "missing-definition",
                listOf("off", "low", "high"),
            ),
        )
    }

    @Test
    fun testThinkingLevelRegistry_mergesCustomLevelAtImportedRank_BitsUT() {
        val method = ThinkingLevelRegistry::class.java.declaredMethods.firstOrNull {
            it.name == "mergedDefinitions" && it.parameterCount == 2
        }
        assertNotNull(
            "ThinkingLevelRegistry must merge imported semantic definitions by rank",
            method,
        )
        val incoming = ThinkingLevelRegistry.builtInDefinitions.toMutableList().apply {
            add(
                3,
                ThinkingLevelDefinition(
                    definitionId = "between-uuid",
                    levelId = "between_low_medium",
                    title = "Between",
                    rank = 3,
                ),
            )
        }.mapIndexed { index, definition -> definition.copy(rank = index) }

        method!!.isAccessible = true
        @Suppress("UNCHECKED_CAST")
        val merged = method.invoke(
            ThinkingLevelRegistry,
            ThinkingLevelRegistry.builtInDefinitions,
            incoming,
        ) as List<ThinkingLevelDefinition>

        assertEquals(
            listOf(
                "off",
                "minimal",
                "low",
                "between-uuid",
                "medium",
                "high",
            ),
            merged.take(6).map { it.definitionId },
        )
        assertEquals(merged.indices.toList(), merged.map { it.rank })
    }

    @Test
    fun testThinkingLevelRegistry_preservesLocalOrderAndTitleForExistingIDs_BitsUT() {
        val local = ThinkingLevelRegistry.builtInDefinitions.toMutableList().apply {
            val item = removeAt(3)
            add(4, item)
            add(
                5,
                ThinkingLevelDefinition(
                    definitionId = "shared-uuid",
                    levelId = "shared_custom",
                    title = "Local Name",
                    rank = 5,
                ),
            )
        }.mapIndexed { index, definition -> definition.copy(rank = index) }
        val incoming = ThinkingLevelRegistry.builtInDefinitions.toMutableList().apply {
            add(
                2,
                ThinkingLevelDefinition(
                    definitionId = "shared-uuid",
                    levelId = "shared_custom",
                    title = "Imported Name",
                    rank = 2,
                ),
            )
        }

        val merged = ThinkingLevelRegistry.mergedDefinitions(local, incoming)

        assertEquals(
            local.map { it.definitionId },
            merged.map { it.definitionId },
        )
        assertEquals(
            "Local Name",
            merged.first {
                it.definitionId == "shared-uuid"
            }.title,
        )
    }
}
