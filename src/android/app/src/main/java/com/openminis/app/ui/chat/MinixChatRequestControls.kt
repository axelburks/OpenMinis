package com.openminis.app.ui.chat

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openminis.app.R
import com.openminis.app.data.model.REQUEST_CONTROL_DEFAULT_SLIDER_END_COLOR_HEX
import com.openminis.app.data.model.REQUEST_CONTROL_DEFAULT_SLIDER_START_COLOR_HEX
import com.openminis.app.data.model.RequestBodyControl
import com.openminis.app.data.model.RequestBodyControlOption
import com.openminis.app.data.model.RequestBodyControlState
import com.openminis.app.data.model.ThinkingLevel
import com.openminis.app.data.model.ThinkingLevelRegistry
import com.openminis.app.provider.RequestBodyControlRuntimeStore
import com.openminis.app.ui.components.RequestControlIcons
import com.openminis.app.ui.theme.ChatColors
import kotlin.math.round
import kotlin.math.roundToInt

@Composable
internal fun MinixChatRequestControlsPanel(
    providerName: String,
    modelName: String,
    currentLevel: ThinkingLevel,
    currentDefinitionId: String,
    availableLevels: List<ThinkingLevel>,
    controls: List<RequestBodyControl>,
    sessionKey: String?,
    modelKey: String,
    onSelect: (ThinkingLevel) -> Unit,
    onSelectDefinitionId: (String) -> Unit,
    onOpenModelPicker: () -> Unit,
    onOpenRequestCustomization: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val maximumPanelHeight = (
        LocalConfiguration.current.screenHeightDp * 0.36f
        ).coerceAtMost(300f).dp
    val rows = remember(availableLevels) { availableLevels }
    var controlState by remember(
        sessionKey,
        modelKey,
        controls,
    ) {
        mutableStateOf(
            RequestBodyControlRuntimeStore.state(
                context,
                sessionKey,
                modelKey,
                controls,
            ),
        )
    }
    val showBuiltInThinking =
        availableLevels.isNotEmpty() &&
            !controls.any { control ->
                control.isEnabled &&
                    control.semanticKind ==
                    RequestBodyControl.SemanticKind.thinkingBudget
            }
    val enabledControls = controls.filter { it.isEnabled }

    fun saveControlState(next: RequestBodyControlState) {
        controlState = next
        RequestBodyControlRuntimeStore.save(
            context,
            sessionKey,
            modelKey,
            controls,
            next,
        )
    }

    val panelShape = RoundedCornerShape(18.dp)
    Surface(
        modifier = modifier
            .shadow(
                elevation = 8.dp,
                shape = panelShape,
                clip = false,
            )
            .border(
                width = 0.5.dp,
                color = ChatColors.toolBorder,
                shape = panelShape,
            ),
        shape = panelShape,
        color = ChatColors.inputBg,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = maximumPanelHeight)
                .verticalScroll(rememberScrollState())
                .padding(12.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement =
                        Arrangement.spacedBy(4.dp),
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(8.dp))
                        .clickable(onClick = onOpenModelPicker)
                        .padding(
                            horizontal = 4.dp,
                            vertical = 6.dp,
                        ),
                ) {
                    Text(
                        text = providerName,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = ChatColors.secondaryText,
                        maxLines = 1,
                    )
                    Text(
                        text = "·",
                        fontSize = 15.sp,
                        color = ChatColors.tertiaryText,
                    )
                    Text(
                        text = modelName,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = ChatColors.primaryText,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    Icon(
                        imageVector = Icons.Default.ChevronRight,
                        contentDescription = null,
                        tint = ChatColors.tertiaryText,
                        modifier = Modifier.size(16.dp),
                    )
                }
                IconButton(onClick = onOpenRequestCustomization) {
                    Icon(
                        imageVector = Icons.Default.Settings,
                        contentDescription = stringResource(
                            R.string.request_customization_title,
                        ),
                        tint = ChatColors.secondaryText,
                    )
                }
            }
            Spacer(modifier = Modifier.height(10.dp))
            if (showBuiltInThinking) {
                MinixBuiltInThinkingControl(
                    rows = rows,
                    currentLevel = currentLevel,
                    onSelect = onSelect,
                )
                if (enabledControls.isNotEmpty()) {
                    HorizontalDivider(
                        color = MaterialTheme.colorScheme
                            .outlineVariant.copy(alpha = 0.65f),
                    )
                }
            }

            enabledControls.forEachIndexed { index, control ->
                when (control.kind) {
                    RequestBodyControl.Kind.toggle -> {
                        val checked =
                            controlState.toggleValuesByControlID[
                                control.id
                            ] ?: control.defaultIsActive
                        Row(
                            verticalAlignment =
                                Alignment.CenterVertically,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(
                                    horizontal = 4.dp,
                                    vertical = 10.dp,
                                ),
                        ) {
                            Icon(
                                imageVector =
                                    RequestControlIcons
                                        .resolve(control).image,
                                contentDescription = null,
                                tint = ChatColors.secondaryText,
                                modifier = Modifier.size(18.dp),
                            )
                            Spacer(modifier = Modifier.width(8.dp))
                            Text(
                                text = control.title,
                                fontSize = 15.sp,
                                color = ChatColors.primaryText,
                                modifier = Modifier.weight(1f),
                            )
                            Switch(
                                checked = checked,
                                onCheckedChange = { value ->
                                    saveControlState(
                                        controlState.copy(
                                            toggleValuesByControlID =
                                                controlState
                                                    .toggleValuesByControlID +
                                                (
                                                    control.id to
                                                        value
                                                    ),
                                        ),
                                    )
                                },
                            )
                        }
                    }

                    RequestBodyControl.Kind.optionGroup -> {
                        MinixOptionGroupControl(
                            control = control,
                            currentDefinitionId =
                                currentDefinitionId,
                            controlState = controlState,
                            onSave = ::saveControlState,
                            onSelectDefinitionId =
                                onSelectDefinitionId,
                        )
                    }
                }
                if (index < enabledControls.lastIndex) {
                    HorizontalDivider(
                        color = MaterialTheme.colorScheme
                            .outlineVariant.copy(alpha = 0.65f),
                    )
                }
            }

            if (!showBuiltInThinking && enabledControls.isEmpty()) {
                Text(
                    text = stringResource(
                        R.string.request_controls_empty,
                    ),
                    fontSize = 14.sp,
                    color = ChatColors.secondaryText,
                )
            }
        }
    }
}

@Composable
private fun MinixBuiltInThinkingControl(
    rows: List<ThinkingLevel>,
    currentLevel: ThinkingLevel,
    onSelect: (ThinkingLevel) -> Unit,
) {
    val context = LocalContext.current
    val selectedIndex =
        rows.indexOf(currentLevel).takeIf { it >= 0 } ?: 0
    var liveThinkingIndex by remember(currentLevel, rows) {
        mutableStateOf(selectedIndex.toFloat())
    }
    val liveThinkingPosition =
        if (rows.size > 1) {
            liveThinkingIndex / rows.lastIndex.toFloat()
        } else {
            0f
        }
    val liveThinkingLevel = rows.getOrNull(
        liveThinkingIndex.roundToInt()
            .coerceIn(0, rows.lastIndex),
    ) ?: currentLevel
    val thinkingColor =
        minixRequestControlDefaultSliderColor(
            liveThinkingPosition,
        )

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 4.dp, vertical = 10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                imageVector = Icons.Default.Lightbulb,
                contentDescription = null,
                tint = thinkingColor.copy(
                    alpha =
                        if (currentLevel == ThinkingLevel.OFF) {
                            0.65f
                        } else {
                            1f
                        },
                ),
                modifier = Modifier.size(18.dp),
            )
            Spacer(modifier = Modifier.width(8.dp))
            Text(
                text = stringResource(
                    R.string.thinking_level_sheet_title,
                ),
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                color = ChatColors.primaryText,
                modifier = Modifier.weight(1f),
            )
            Text(
                text = liveThinkingLevel.localizedName(context),
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                color = thinkingColor,
            )
        }
        if (rows.size > 1) {
            Spacer(modifier = Modifier.height(8.dp))
            MinixGradientControlSlider(
                value = liveThinkingIndex,
                onValueChange = { liveThinkingIndex = it },
                onValueChangeFinished = {
                    val index = liveThinkingIndex.roundToInt()
                        .coerceIn(0, rows.lastIndex)
                    if (rows[index] != currentLevel) {
                        onSelect(rows[index])
                    }
                },
                valueRange = 0f..rows.lastIndex.toFloat(),
                steps = (rows.size - 2).coerceAtLeast(0),
                anchorCount = rows.size,
            )
        }
    }
}

@Composable
private fun MinixOptionGroupControl(
    control: RequestBodyControl,
    currentDefinitionId: String,
    controlState: RequestBodyControlState,
    onSave: (RequestBodyControlState) -> Unit,
    onSelectDefinitionId: (String) -> Unit,
) {
    val context = LocalContext.current
    val options = minixDisplayControlOptions(control, context)
    val isThinkingControl =
        control.semanticKind ==
            RequestBodyControl.SemanticKind.thinkingBudget
    val currentOptionId =
        if (isThinkingControl) {
            options.firstOrNull {
                it.thinkingDefinitionId ==
                    currentDefinitionId
            }?.id
        } else {
            minixSelectedControlOptionId(
                control,
                controlState,
                context,
            )
        }
    val currentOption =
        options.firstOrNull { it.id == currentOptionId }
            ?: options.firstOrNull()
    val semanticPosition = options
        .indexOfFirst {
            it.thinkingDefinitionId ==
                currentDefinitionId
        }
        .takeIf { it >= 0 }
        ?.toDouble()
        ?.div((options.size - 1).coerceAtLeast(1).toDouble())
    val sliderValue = (
        semanticPosition
            ?: minixSliderPosition(
                control,
                controlState,
                context,
            )
        ).toFloat()
    var liveSliderValue by remember(
        control.id,
        currentDefinitionId,
        currentOptionId,
    ) {
        mutableStateOf(sliderValue)
    }
    val displayedOption = minixOptionForSlider(
        control,
        liveSliderValue.toDouble(),
        context,
    )
    val sliderStartColor =
        minixRequestControlColor(control.sliderStartColorHex)
            ?: minixRequestControlDefaultSliderColor(0f)
    val sliderEndColor =
        minixRequestControlColor(control.sliderEndColorHex)
            ?: minixRequestControlDefaultSliderColor(1f)
    val sliderColor = lerp(
        sliderStartColor,
        sliderEndColor,
        liveSliderValue.coerceIn(0f, 1f),
    )
    var showOptions by remember(control.id) {
        mutableStateOf(false)
    }

    fun optionTitle(
        option: RequestBodyControlOption?,
    ): String {
        if (option == null) return ""
        if (!isThinkingControl) return option.title
        val definition = ThinkingLevelRegistry
            .definitions(context)
            .firstOrNull {
                it.definitionId ==
                    option.thinkingDefinitionId
            }
        return if (definition?.isBuiltIn == true) {
            ThinkingLevelRegistry
                .nativeLevel(definition.definitionId)
                .localizedName(context)
        } else {
            definition?.title ?: option.title
        }
    }

    fun selectOption(option: RequestBodyControlOption) {
        val definitionId = option.thinkingDefinitionId
        if (isThinkingControl && definitionId != null) {
            onSelectDefinitionId(definitionId)
            return
        }
        onSave(
            controlState.copy(
                selectedOptionIDsByControlID =
                    controlState
                        .selectedOptionIDsByControlID +
                    (control.id to option.id),
            ),
        )
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 4.dp, vertical = 10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                imageVector =
                    RequestControlIcons.resolve(control).image,
                contentDescription = null,
                tint =
                    if (control.isSliderEnabled) {
                        sliderColor
                    } else {
                        ChatColors.secondaryText
                    },
                modifier = Modifier.size(18.dp),
            )
            Spacer(modifier = Modifier.width(8.dp))
            Text(
                text =
                    if (isThinkingControl) {
                        stringResource(
                            R.string.thinking_level_sheet_title,
                        )
                    } else {
                        control.title
                    },
                fontSize = 15.sp,
                fontWeight = FontWeight.Medium,
                color = ChatColors.primaryText,
                modifier = Modifier.weight(1f),
            )
            if (control.isSliderEnabled) {
                Text(
                    text = optionTitle(displayedOption),
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = sliderColor,
                )
            }
        }
        if (control.isSliderEnabled && options.size > 1) {
            Spacer(Modifier.height(6.dp))
            MinixGradientControlSlider(
                value = liveSliderValue,
                onValueChange = {
                    liveSliderValue = it.coerceIn(0f, 1f)
                },
                onValueChangeFinished = {
                    minixOptionForSlider(
                        control,
                        liveSliderValue.toDouble(),
                        context,
                    )?.let(::selectOption)
                },
                startColor = sliderStartColor,
                endColor = sliderEndColor,
                anchorCount = options.size,
            )
        } else if (options.isNotEmpty()) {
            Spacer(Modifier.height(6.dp))
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .background(ChatColors.inputIconBg),
            ) {
                Row(
                    verticalAlignment =
                        Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable {
                            showOptions = !showOptions
                        }
                        .padding(
                            horizontal = 10.dp,
                            vertical = 8.dp,
                        ),
                ) {
                    Text(
                        text = optionTitle(currentOption),
                        color = ChatColors.primaryText,
                        modifier = Modifier.weight(1f),
                    )
                    Icon(
                        Icons.Default.ArrowDropDown,
                        contentDescription = null,
                        tint = ChatColors.secondaryText,
                    )
                }
                if (showOptions) {
                    HorizontalDivider(
                        color = MaterialTheme.colorScheme
                            .outlineVariant.copy(alpha = 0.55f),
                    )
                    options.forEach { option ->
                        val isSelected =
                            option.id == currentOption?.id
                        Row(
                            verticalAlignment =
                                Alignment.CenterVertically,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable {
                                    showOptions = false
                                    selectOption(option)
                                }
                                .padding(
                                    horizontal = 10.dp,
                                    vertical = 9.dp,
                                ),
                        ) {
                            Text(
                                text = optionTitle(option),
                                color = ChatColors.primaryText,
                                modifier = Modifier.weight(1f),
                            )
                            if (isSelected) {
                                Icon(
                                    imageVector =
                                        Icons.Default.Check,
                                    contentDescription = null,
                                    tint =
                                        MaterialTheme.colorScheme
                                            .primary,
                                    modifier = Modifier.size(18.dp),
                                )
                            }
                        }
                        if (option != options.last()) {
                            HorizontalDivider(
                                modifier = Modifier.padding(
                                    start = 10.dp,
                                ),
                                color = MaterialTheme.colorScheme
                                    .outlineVariant.copy(
                                        alpha = 0.38f,
                                    ),
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun MinixGradientControlSlider(
    value: Float,
    onValueChange: (Float) -> Unit,
    onValueChangeFinished: () -> Unit = {},
    valueRange: ClosedFloatingPointRange<Float> = 0f..1f,
    steps: Int = 0,
    anchorCount: Int = 0,
    startColor: Color =
        minixRequestControlDefaultSliderColor(0f),
    endColor: Color =
        minixRequestControlDefaultSliderColor(1f),
) {
    val range = valueRange.endInclusive - valueRange.start
    val normalized = if (range > 0f) {
        ((value - valueRange.start) / range).coerceIn(0f, 1f)
    } else {
        0f
    }
    val thumbColor = lerp(startColor, endColor, normalized)
    val transparentSliderColors = SliderDefaults.colors(
        thumbColor = Color.Transparent,
        activeTrackColor = Color.Transparent,
        inactiveTrackColor = Color.Transparent,
        activeTickColor = Color.Transparent,
        inactiveTickColor = Color.Transparent,
    )

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxWidth()
            .height(40.dp),
    ) {
        val thumbDiameter = 24.dp
        val trackHeight = 8.dp
        val thumbTravelWidth =
            (maxWidth - thumbDiameter).coerceAtLeast(1.dp)
        val trackInset = 8.dp
        val visualTrackWidth =
            (maxWidth - trackInset * 2).coerceAtLeast(1.dp)

        Box(
            modifier = Modifier
                .align(Alignment.CenterStart)
                .offset(x = trackInset)
                .width(visualTrackWidth)
                .height(trackHeight)
                .clip(RoundedCornerShape(50))
                .background(ChatColors.secondaryText.copy(alpha = 0.18f)),
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth(normalized)
                    .height(trackHeight)
                    .background(
                        Brush.horizontalGradient(
                            listOf(
                                startColor.copy(alpha = 0.78f),
                                endColor.copy(alpha = 0.92f),
                            ),
                        ),
                    ),
            )
        }

        if (anchorCount > 1) {
            repeat(anchorCount) { index ->
                val anchorPosition =
                    index.toFloat() / (anchorCount - 1).toFloat()
                Box(
                    modifier = Modifier
                        .align(Alignment.CenterStart)
                        .offset(
                            x = thumbDiameter / 2 +
                                thumbTravelWidth *
                                anchorPosition -
                                2.dp,
                        )
                        .size(4.dp)
                        .background(
                            if (anchorPosition <= normalized) {
                                Color.White.copy(alpha = 0.82f)
                            } else {
                                ChatColors.secondaryText.copy(
                                    alpha = 0.48f,
                                )
                            },
                            CircleShape,
                        ),
                )
            }
        }

        Slider(
            value = value,
            onValueChange = onValueChange,
            onValueChangeFinished = onValueChangeFinished,
            valueRange = valueRange,
            steps = steps,
            colors = transparentSliderColors,
            modifier = Modifier
                .fillMaxWidth()
                .align(Alignment.Center),
        )

        Box(
            modifier = Modifier
                .align(Alignment.CenterStart)
                .offset(x = thumbTravelWidth * normalized)
                .size(thumbDiameter)
                .shadow(
                    elevation = 4.dp,
                    shape = CircleShape,
                    clip = false,
                )
                .background(ChatColors.inputBg, CircleShape)
                .background(
                    thumbColor.copy(alpha = 0.16f),
                    CircleShape,
                )
                .border(
                    width = 1.dp,
                    color = thumbColor.copy(alpha = 0.62f),
                    shape = CircleShape,
                ),
        )
    }
}

private fun minixRequestControlDefaultSliderColor(
    position: Float,
): Color {
    return lerp(
        minixRequestControlColor(
            REQUEST_CONTROL_DEFAULT_SLIDER_START_COLOR_HEX,
        )!!,
        minixRequestControlColor(
            REQUEST_CONTROL_DEFAULT_SLIDER_END_COLOR_HEX,
        )!!,
        position.coerceIn(0f, 1f),
    )
}

private fun minixRequestControlColor(
    hex: String?,
): Color? {
    val value = hex?.trim()?.takeIf { it.isNotEmpty() }
        ?: return null
    return runCatching {
        Color(android.graphics.Color.parseColor(value))
    }.getOrNull()
}

private fun minixSelectedControlOptionId(
    control: RequestBodyControl,
    state: RequestBodyControlState,
    context: Context?,
): String? {
    val options = minixDisplayControlOptions(
        control,
        context,
    )
    return state.selectedOptionIDsByControlID[control.id]
        ?: control.defaultOptionID
        ?: options.firstOrNull()?.id
}

private fun minixSliderPosition(
    control: RequestBodyControl,
    state: RequestBodyControlState,
    context: Context?,
): Double {
    val options = minixDisplayControlOptions(
        control,
        context,
    )
    val selected =
        state.selectedOptionIDsByControlID[control.id]
            ?: control.defaultOptionID
    val index = options.indexOfFirst { it.id == selected }
    return if (options.size > 1 && index >= 0) {
        index.toDouble() / (options.size - 1).toDouble()
    } else {
        0.0
    }
}

private fun minixOptionForSlider(
    control: RequestBodyControl,
    value: Double,
    context: Context?,
): RequestBodyControlOption? {
    val options = minixDisplayControlOptions(
        control,
        context,
    )
    if (options.isEmpty()) return null
    val index = round(
        value.coerceIn(0.0, 1.0) *
            (options.size - 1),
    )
        .toInt()
        .coerceIn(0, options.lastIndex)
    return options[index]
}

private fun minixDisplayControlOptions(
    control: RequestBodyControl,
    context: Context?,
): List<RequestBodyControlOption> =
    if (
        control.semanticKind ==
        RequestBodyControl.SemanticKind.thinkingBudget
    ) {
        ThinkingLevelRegistry.sortedThinkingOptions(
            control.options.filter {
                ThinkingLevelRegistry.definition(
                    it.thinkingDefinitionId,
                    context,
                ) != null
            },
            context,
        )
    } else {
        control.options
    }
