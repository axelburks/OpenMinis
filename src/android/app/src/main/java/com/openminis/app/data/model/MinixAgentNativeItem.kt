package com.openminis.app.data.model

import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/**
 * [Minix] Provider-native Responses output item persisted and replayed verbatim.
 *
 * [rawJSON] is the source of truth. [prettyJSON] is only for user-facing display.
 */
@Serializable
data class AgentNativeItem(
    val type: String,
    val id: String? = null,
    val status: String? = null,
    val rawJSON: String,
) {
    val prettyJSON: String
        get() = runCatching {
            val parsed = compactJson.parseToJsonElement(rawJSON)
            prettyJson.encodeToString(JsonElement.serializer(), parsed.sortedKeys())
        }.getOrDefault(rawJSON)

    private fun JsonElement.sortedKeys(): JsonElement = when (this) {
        is JsonObject -> JsonObject(
            entries.sortedBy { it.key }.associate { (key, value) ->
                key to value.sortedKeys()
            },
        )
        is JsonArray -> JsonArray(map { it.sortedKeys() })
        else -> this
    }

    private companion object {
        val compactJson = Json { ignoreUnknownKeys = true }
        val prettyJson = Json { prettyPrint = true }
    }
}
