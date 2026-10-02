package com.openminis.app.backup

import com.openminis.app.ProductionSources
import com.openminis.app.data.model.ModelGroup
import com.openminis.app.data.model.ProviderConfig
import com.openminis.app.data.model.ThinkingLevel
import com.openminis.app.data.model.ThinkingLevelRegistry
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [T-android-restore-thinking-level] A group restored from a backup keeps its
 * immutable thinking definition ID, and per-model ceilings and sub-agent
 * overrides remain cross-platform compatible.
 *
 * iOS writes enum levels as lowercase raw values (`"high"`) while Android's
 * enum serializer writes names (`"HIGH"`). Definition IDs are already strings
 * and must remain unchanged.
 */
class BackupThinkingLevelRestoreTest {

    /** provider_config.json as iOS writes it: lowercase raw values. */
    private val iosProviderConfig = """
        {
          "instances": [],
          "modelEntries": [{
            "providerInstanceId": "p1",
            "model": {"id": "gemini-3-pro", "displayName": "Gemini 3 Pro", "provider": "antigravity"},
            "overrides": {"maxThinkingLevel": "max"},
            "uuid": "e1"
          }],
          "modelGroups": [{
            "id": "g1", "name": "Group", "memberEntryIds": ["e1"],
            "strategy": "fallback", "fallbackStrategy": "default",
            "defaultThinkingDefinitionId": "high"
          }],
          "subAgents": [{
            "id": "a1", "name": "researcher", "description": "d",
            "thinkingLevelOverride": "low"
          }]
        }
    """.trimIndent()

    @Test
    fun iosLowercaseLevels_surviveProviderConfigRestore() {
        val config = BackupImporter.parseProviderConfigLeniently(iosProviderConfig).config
        assertEquals("high", config.modelGroups.single().defaultThinkingDefinitionId)
        assertEquals(ThinkingLevel.MAX, config.modelEntries.single().overrides.maxThinkingLevel)
        assertEquals(ThinkingLevel.LOW, config.subAgents.single().thinkingLevelOverride)
    }

    @Test
    fun androidBackup_roundTripsItsOwnLevels() {
        val group = ModelGroup(id = "g1", name = "G", defaultThinkingDefinitionId = "ultra")
        val text = BackupFormat.json.encodeToString(
            ProviderConfig.serializer(), ProviderConfig(modelGroups = mutableListOf(group)),
        )
        val back = BackupImporter.parseProviderConfigLeniently(text).config
        assertEquals("ultra", back.modelGroups.single().defaultThinkingDefinitionId)
    }

    @Test
    fun androidEncoding_preservesDefinitionId() {
        // Group defaults persist immutable definition IDs rather than mutable
        // display names or enum ordinals.
        val text = BackupFormat.json.encodeToString(
            ModelGroup.serializer(),
            ModelGroup(id = "g1", name = "G", defaultThinkingDefinitionId = "high"),
        )
        assertTrue(text, text.contains("\"defaultThinkingDefinitionId\":\"high\""))
    }

    @Test
    fun absentLevel_staysNull() {
        val wire = """{"id":"g1","name":"G","memberEntryIds":[]}"""
        assertNull(BackupFormat.json.decodeFromString(ModelGroup.serializer(), wire).defaultThinkingDefinitionId)
    }

    /**
     * Every raw value of the Swift enum must decode to the level of the same
     * name, so either platform adding or respelling a level breaks here rather
     * than silently in a user's restore.
     */
    @Test
    fun everyIosRawValue_decodesToTheSameLevel() {
        val iosCases = swiftThinkingLevelCases()
        assertEquals(
            "iOS and Android must define the same levels",
            ThinkingLevel.entries.map { it.name.lowercase() },
            iosCases,
        )
        for (raw in iosCases) {
            val group = BackupFormat.json.decodeFromString(
                ModelGroup.serializer(),
                """{"id":"g","name":"G","memberEntryIds":[],"defaultThinkingDefinitionId":"$raw"}""",
            )
            assertEquals(raw, group.defaultThinkingDefinitionId)
            assertEquals(raw, ThinkingLevelRegistry.nativeLevel(raw).name.lowercase())
        }
    }

    private fun swiftThinkingLevelCases(): List<String> {
        var dir: File? = ProductionSources.mainRoot()
        while (dir != null && !File(dir, "src/ios").isDirectory) dir = dir.parentFile
        val source = File(requireNotNull(dir), "src/ios/Providers/LLMTypes.swift").readText()
        val start = source.indexOf("enum ThinkingLevel: String")
        require(start >= 0) { "enum ThinkingLevel not found in LLMTypes.swift" }
        val body = source.substring(source.indexOf('{', start) + 1, source.indexOf("static func", start))
        return Regex("""^\s*case (\w+)\s*$""", RegexOption.MULTILINE)
            .findAll(body).map { it.groupValues[1] }.toList()
    }
}
