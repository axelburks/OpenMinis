package com.openminis.app.data.model

import kotlinx.serialization.Serializable
import java.util.UUID

// [Minix] Persisted request-control models.

const val REQUEST_CONTROL_DEFAULT_SLIDER_START_COLOR_HEX = "#439DF0"
const val REQUEST_CONTROL_DEFAULT_SLIDER_END_COLOR_HEX = "#F043CA"

@Serializable
data class RequestBodyControlOption(
    val id: String = UUID.randomUUID().toString(),
    var thinkingDefinitionId: String? = null,
    var title: String,
    var payloadExpressions: List<String> = emptyList(),
)

@Serializable
data class RequestBodyControl(
    val id: String = UUID.randomUUID().toString(),
    var title: String,
    var iconName: String? = null,
    var kind: Kind,
    var semanticKind: SemanticKind? = null,
    var isEnabled: Boolean = true,
    var defaultIsActive: Boolean = false,
    var defaultOptionID: String? = null,
    var isSliderEnabled: Boolean = false,
    var sliderStartColorHex: String? = null,
    var sliderEndColorHex: String? = null,
    var payloadExpressions: List<String> = emptyList(),
    var options: List<RequestBodyControlOption> = emptyList(),
) {
    @Serializable
    enum class Kind { toggle, optionGroup }

    @Serializable
    enum class SemanticKind { thinkingBudget }
}

@Serializable
data class RequestBodyControlState(
    var toggleValuesByControlID: Map<String, Boolean> = emptyMap(),
    var selectedOptionIDsByControlID: Map<String, String> = emptyMap(),
)

@Serializable
data class RequestBodyControlRuntimeSnapshot(
    val activeModelKey: String,
    val state: RequestBodyControlState,
)
