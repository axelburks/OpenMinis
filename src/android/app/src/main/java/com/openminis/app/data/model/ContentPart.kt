package com.openminis.app.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonContentPolymorphicSerializer
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

@Serializable
data class MediaRef(
    val id: String,
    val relativePath: String,
    val mimeType: String,
    val originalFileName: String? = null,
)

@Serializable
data class ToolUse(
    val toolUseId: String,
    val name: String,
    val input: String,
    val description: String? = null,
)

@Serializable
data class ToolResult(
    val toolUseId: String,
    val output: String,
    val success: Boolean,
    val mediaRef: MediaRef? = null,
)

@Serializable(with = ContentPartSerializer::class)
sealed class ContentPart {
    @Serializable
    @SerialName("text")
    data class Text(val value: String) : ContentPart()

    @Serializable
    @SerialName("mediaRef")
    data class Media(val value: MediaRef) : ContentPart()

    @Serializable
    @SerialName("toolUse")
    data class Tool(val value: ToolUse) : ContentPart()

    @Serializable
    @SerialName("toolResult")
    data class Result(val value: ToolResult) : ContentPart()

    /** [Minix] Opaque provider-native Responses output item. */
    @Serializable
    @SerialName("nativeItem")
    data class NativeItem(val value: AgentNativeItem) : ContentPart()
}

object ContentPartSerializer : JsonContentPolymorphicSerializer<ContentPart>(ContentPart::class) {
    override fun selectDeserializer(element: JsonElement) =
        when (element.jsonObject["type"]?.jsonPrimitive?.content) {
            "text" -> ContentPart.Text.serializer()
            "mediaRef" -> ContentPart.Media.serializer()
            "toolUse" -> ContentPart.Tool.serializer()
            "toolResult" -> ContentPart.Result.serializer()
            "nativeItem" -> ContentPart.NativeItem.serializer() // [Minix]
            else -> ContentPart.Text.serializer()
        }
}

val contentPartJson = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
}
