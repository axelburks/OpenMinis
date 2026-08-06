package com.openminis.app.ui.settings

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.DragHandle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.openminis.app.R
import com.openminis.app.data.model.ModelEntry
import com.openminis.app.data.model.ProviderInstance
import com.openminis.app.data.model.REQUEST_CONTROL_DEFAULT_SLIDER_END_COLOR_HEX
import com.openminis.app.data.model.REQUEST_CONTROL_DEFAULT_SLIDER_START_COLOR_HEX
import com.openminis.app.data.model.RequestBodyControl
import com.openminis.app.data.model.RequestBodyControlOption
import com.openminis.app.data.model.ThinkingLevelRegistry
import com.openminis.app.data.repository.ProviderRepository
import com.openminis.app.provider.RequestBodyControlDefaults
import com.openminis.app.provider.RequestExpressionValidator
import com.openminis.app.ui.components.MinisAlertDialog
import com.openminis.app.ui.components.MinisButton
import com.openminis.app.ui.components.MinisTextButton
import com.openminis.app.ui.components.RequestControlIconPickerScreen
import com.openminis.app.ui.components.RequestControlIcons
import com.openminis.app.ui.components.RowLabel
import com.openminis.app.ui.components.SectionTextField
import java.util.Locale
import sh.calvin.reorderable.ReorderableItem
import sh.calvin.reorderable.rememberReorderableLazyListState

// [Minix] Model request customization UI kept out of the upstream model editor.

@Composable
internal fun ModelRequestCustomizationScreen(
    instanceId: String,
    entryId: String,
    providerRepository: ProviderRepository,
    onBack: () -> Unit,
) {
    val config by providerRepository.config.collectAsState()
    val entry = config.modelEntries.find {
        it.id == entryId && it.providerInstanceId == instanceId
    }
    if (entry == null) {
        LaunchedEffect(entryId) { onBack() }
        return
    }
    val instance = config.instances.find { it.id == instanceId }
    val initialHeaders = remember(entryId) {
        entry.overrides.customRequestHeaders
    }
    val initialBody = remember(entryId) {
        entry.overrides.customRequestBody
    }
    val initialControls = remember(entryId) {
        entry.overrides.requestBodyControls
    }
    var customHeaders by remember(entryId) {
        mutableStateOf(initialHeaders.joinToString("\n"))
    }
    var customBody by remember(entryId) {
        mutableStateOf(initialBody.joinToString("\n"))
    }
    var controls by remember(entryId) {
        mutableStateOf(initialControls)
    }
    var editingControlId by remember { mutableStateOf<String?>(null) }
    var showUnsavedChangesDialog by remember {
        mutableStateOf(false)
    }

    val editingControl = editingControlId?.let { id ->
        controls.firstOrNull { it.id == id }
    }
    if (editingControl != null) {
        MinixRequestControlDetailScreen(
            control = editingControl,
            onChange = { next ->
                val index = controls.indexOfFirst {
                    it.id == editingControl.id
                }
                updateControl(controls, index, next)
                    ?.let { controls = it }
            },
            onDelete = {
                controls = controls.filterNot {
                    it.id == editingControl.id
                }
                editingControlId = null
            },
            onBack = { editingControlId = null },
        )
        return
    }

    val hasInvalidExpressions = hasInvalidRequestCustomization(
        customHeaders,
        customBody,
        controls,
    )
    val hasUnsavedChanges =
        requestExpressionLines(customHeaders) != initialHeaders ||
            requestExpressionLines(customBody) != initialBody ||
            controls != initialControls

    fun saveAndClose() {
        if (hasInvalidExpressions) return
        providerRepository.updateEntry(
            entry.copy(
                overrides = entry.overrides.copy(
                    customRequestHeaders =
                        requestExpressionLines(customHeaders),
                    customRequestBody =
                        requestExpressionLines(customBody),
                    requestBodyControls = controls,
                ),
            ),
        )
        onBack()
    }

    val requestClose = {
        if (hasUnsavedChanges) {
            showUnsavedChangesDialog = true
        } else {
            onBack()
        }
    }
    BackHandler(onBack = requestClose)

    if (showUnsavedChangesDialog) {
        AlertDialog(
            onDismissRequest = {
                showUnsavedChangesDialog = false
            },
            title = {
                Text(stringResource(R.string.request_unsaved_title))
            },
            text = {
                Text(stringResource(R.string.request_unsaved_message))
            },
            confirmButton = {
                TextButton(
                    onClick = ::saveAndClose,
                    enabled = !hasInvalidExpressions,
                ) {
                    Text(stringResource(R.string.common_save))
                }
            },
            dismissButton = {
                Column {
                    TextButton(onClick = onBack) {
                        Text(
                            stringResource(
                                R.string.request_unsaved_discard,
                            ),
                        )
                    }
                    TextButton(
                        onClick = {
                            showUnsavedChangesDialog = false
                        },
                    ) {
                        Text(
                            stringResource(
                                R.string.request_unsaved_continue,
                            ),
                        )
                    }
                }
            },
        )
    }

    SettingsScaffold(
        title = stringResource(R.string.request_customization_title),
        onBack = null,
        centerTitle = true,
        scrollable = false,
        navigation = {
            MinisTextButton(
                onClick = requestClose,
                modifier = Modifier.padding(start = 8.dp),
                colors = ButtonDefaults.textButtonColors(
                    contentColor =
                        MaterialTheme.colorScheme.onSurfaceVariant,
                ),
            ) {
                Text(stringResource(R.string.common_cancel))
            }
        },
        actions = {
            MinisButton(
                onClick = ::saveAndClose,
                enabled = !hasInvalidExpressions,
                modifier = Modifier.padding(end = 8.dp),
            ) {
                Text(stringResource(R.string.common_save))
            }
        },
    ) {
        MinixModelRequestCustomizationEditor(
            instance = instance,
            entryId = entryId,
            modelEntries = config.modelEntries,
            providerRepository = providerRepository,
            customHeaders = customHeaders,
            onCustomHeadersChange = { customHeaders = it },
            customBody = customBody,
            onCustomBodyChange = { customBody = it },
            controls = controls,
            onControlsChange = { controls = it },
            onEditControl = { editingControlId = it },
        )
    }
}

@Composable
private fun MinixModelRequestCustomizationEditor(
    instance: ProviderInstance?,
    entryId: String,
    modelEntries: List<ModelEntry>,
    providerRepository: ProviderRepository,
    customHeaders: String,
    onCustomHeadersChange: (String) -> Unit,
    customBody: String,
    onCustomBodyChange: (String) -> Unit,
    controls: List<RequestBodyControl>,
    onControlsChange: (List<RequestBodyControl>) -> Unit,
    onEditControl: (String) -> Unit,
) {
    val context = LocalContext.current
    var showHelp by remember { mutableStateOf(false) }
    var showCopy by remember { mutableStateOf(false) }
    var showThinkingLevels by remember { mutableStateOf(false) }
    var showAddControlMenu by remember {
        mutableStateOf(false)
    }
    val copyableEntries = remember(modelEntries, entryId) {
        modelEntries
            .filter { candidate ->
                candidate.id != entryId &&
                    (candidate.overrides.customRequestHeaders.isNotEmpty() ||
                        candidate.overrides.customRequestBody.isNotEmpty() ||
                        candidate.overrides.requestBodyControls.isNotEmpty())
            }
            .sortedBy { it.model.displayName }
    }
    val lazyListState = rememberLazyListState()
    val reorderState = rememberReorderableLazyListState(
        lazyListState,
    ) { from, to ->
        val prefix = "request-control:"
        val fromId = (from.key as? String)
            ?.takeIf { it.startsWith(prefix) }
            ?.removePrefix(prefix)
            ?: return@rememberReorderableLazyListState
        val toId = (to.key as? String)
            ?.takeIf { it.startsWith(prefix) }
            ?.removePrefix(prefix)
            ?: return@rememberReorderableLazyListState
        val fromIndex = controls.indexOfFirst { it.id == fromId }
        val toIndex = controls.indexOfFirst { it.id == toId }
        if (fromIndex < 0 || toIndex < 0) {
            return@rememberReorderableLazyListState
        }
        onControlsChange(
            controls.toMutableList().apply {
                add(toIndex, removeAt(fromIndex))
            },
        )
    }

    if (showHelp) {
        RequestExpressionHelpDialog(
            onDismiss = { showHelp = false },
        )
    }
    if (showCopy) {
        MinixSelectionDialog(
            title = stringResource(
                R.string.request_copy_model_title,
            ),
            items = copyableEntries.map { source ->
                MinixSelectionItem(
                    id = source.id,
                    title = source.model.displayName,
                    subtitle = stringResource(
                        R.string.request_copy_model_summary,
                        source.overrides.customRequestHeaders.size,
                        source.overrides.customRequestBody.size,
                        source.overrides.requestBodyControls.size,
                    ),
                )
            },
            emptyMessage = stringResource(
                R.string.request_copy_model_empty,
            ),
            onSelect = { sourceId ->
                val source = copyableEntries.firstOrNull {
                    it.id == sourceId
                } ?: return@MinixSelectionDialog
                onCustomHeadersChange(
                    source.overrides.customRequestHeaders
                        .joinToString("\n"),
                )
                onCustomBodyChange(
                    source.overrides.customRequestBody
                        .joinToString("\n"),
                )
                onControlsChange(
                    source.overrides.requestBodyControls,
                )
                showCopy = false
            },
            onDismiss = { showCopy = false },
        )
    }
    if (showThinkingLevels) {
        ThinkingLevelsManagerScreen(
            providerRepository = providerRepository,
            onDismiss = { showThinkingLevels = false },
        )
    }

    LazyColumn(
        state = lazyListState,
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(bottom = 24.dp),
    ) {
        item("request-expressions") {
            SettingsSection(
                header = stringResource(
                    R.string.request_customization_title,
                ),
                footer = stringResource(
                    R.string.request_customization_footer,
                ),
            ) {
                SettingsCardBlock {
                    MinixRequestExpressionFields(
                        headers = customHeaders,
                        onHeadersChange = onCustomHeadersChange,
                        body = customBody,
                        onBodyChange = onCustomBodyChange,
                        headerTitle = stringResource(
                            R.string.request_headers_title,
                        ),
                        bodyTitle = stringResource(
                            R.string.request_body_title,
                        ),
                        headerPlaceholder = stringResource(
                            R.string.request_headers_placeholder,
                        ),
                        bodyPlaceholder = stringResource(
                            R.string.request_body_placeholder,
                        ),
                        onHelp = { showHelp = true },
                    )
                }
            }
        }

        item("request-controls-header") {
            Text(
                text = stringResource(
                    R.string.request_controls_title,
                ).uppercase(),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                fontWeight = FontWeight.Medium,
                modifier = Modifier.padding(
                    start = 32.dp,
                    end = 32.dp,
                    top = 24.dp,
                    bottom = 8.dp,
                ),
            )
        }

        if (controls.isEmpty()) {
            item("request-controls-empty") {
                SettingsSection {
                    SettingsValueRow(
                        title = stringResource(
                            R.string.request_controls_none,
                        ),
                        value = stringResource(
                            R.string.request_controls_add_preset,
                        ),
                        showDivider = false,
                    )
                }
            }
        } else {
            items(
                items = controls,
                key = { "request-control:${it.id}" },
            ) { control ->
                val key = "request-control:${control.id}"
                ReorderableItem(
                    state = reorderState,
                    key = key,
                ) { isDragging ->
                    SwipeToDeleteRequestRow(
                        onDelete = {
                            onControlsChange(
                                controls.filterNot {
                                    it.id == control.id
                                },
                            )
                        },
                        backgroundModifier = Modifier.padding(
                            horizontal = 16.dp,
                            vertical = 4.dp,
                        ),
                        modifier = Modifier.alpha(
                            if (isDragging) 0.72f else 1f,
                        ),
                    ) {
                        RequestControlSummaryRow(
                            control = control,
                            onClick = {
                                onEditControl(control.id)
                            },
                            dragHandleModifier =
                                Modifier.draggableHandle(),
                        )
                    }
                }
            }
        }

        item("request-controls-footer") {
            Text(
                text = stringResource(
                    R.string.request_controls_footer,
                ),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(
                    start = 32.dp,
                    end = 32.dp,
                    top = 8.dp,
                    bottom = 4.dp,
                ),
            )
        }

        item("request-controls-actions") {
            SettingsSection {
                Box(modifier = Modifier.fillMaxWidth()) {
                    SettingsRow(
                        title = stringResource(
                            R.string.request_control_add,
                        ),
                        icon = Icons.Default.Add,
                        titleColor = MaterialTheme.colorScheme.primary,
                        showChevron = false,
                        showDivider = false,
                        onClick = { showAddControlMenu = true },
                    )
                    DropdownMenu(
                        expanded = showAddControlMenu,
                        onDismissRequest = {
                            showAddControlMenu = false
                        },
                    ) {
                        if (controls.none {
                                it.semanticKind ==
                                    RequestBodyControl
                                        .SemanticKind
                                        .thinkingBudget
                            }
                        ) {
                            DropdownMenuItem(
                                text = {
                                    Text(
                                        stringResource(
                                            R.string
                                                .request_control_add_thinking,
                                        ),
                                    )
                                },
                                onClick = {
                                    showAddControlMenu = false
                                    onControlsChange(
                                        controls +
                                            RequestBodyControlDefaults
                                                .thinkingOptionGroup(
                                                    instance,
                                                ),
                                    )
                                },
                            )
                        }
                        DropdownMenuItem(
                            text = {
                                Text(
                                    stringResource(
                                        R.string
                                            .request_control_add_toggle,
                                    ),
                                )
                            },
                            onClick = {
                                showAddControlMenu = false
                                onControlsChange(
                                    controls + RequestBodyControl(
                                        title = context.getString(
                                            R.string
                                                .request_control_custom_toggle,
                                        ),
                                        iconName =
                                            RequestControlIcons.TOGGLE,
                                        kind =
                                            RequestBodyControl.Kind.toggle,
                                        defaultIsActive = false,
                                    ),
                                )
                            },
                        )
                        DropdownMenuItem(
                            text = {
                                Text(
                                    stringResource(
                                        R.string
                                            .request_control_add_group,
                                    ),
                                )
                            },
                            onClick = {
                                showAddControlMenu = false
                                onControlsChange(
                                    controls + RequestBodyControl(
                                        title = context.getString(
                                            R.string
                                                .request_control_custom_group,
                                        ),
                                        iconName =
                                            RequestControlIcons
                                                .OPTION_GROUP,
                                        kind =
                                            RequestBodyControl.Kind
                                                .optionGroup,
                                    ),
                                )
                            },
                        )
                    }
                }
            }
        }

        item("request-controls-management") {
            SettingsSection {
                SettingsRow(
                    title = stringResource(
                        R.string.request_copy_model,
                    ),
                    onClick = { showCopy = true },
                )
                SettingsRow(
                    title = stringResource(
                        R.string.thinking_levels_manage,
                    ),
                    showDivider = false,
                    onClick = { showThinkingLevels = true },
                )
            }
        }
    }
}

@Composable
private fun RequestControlSummaryRow(
    control: RequestBodyControl,
    onClick: () -> Unit,
    dragHandleModifier: Modifier,
    modifier: Modifier = Modifier,
) {
    val icon = RequestControlIcons.resolve(control)
    val displayTitle = requestControlDisplayTitle(control)
    val summary = when (control.kind) {
        RequestBodyControl.Kind.toggle -> stringResource(
            R.string.request_control_summary_toggle,
            control.payloadExpressions.size,
        )
        RequestBodyControl.Kind.optionGroup -> {
            val resource = if (
                control.semanticKind ==
                RequestBodyControl.SemanticKind.thinkingBudget
            ) {
                R.string.request_control_summary_thinking
            } else {
                R.string.request_control_summary_group
            }
            stringResource(
                resource,
                control.options.size,
                if (control.isSliderEnabled) {
                    stringResource(
                        R.string.request_control_summary_slider,
                    )
                } else {
                    ""
                },
            )
        }
    }
    Row(
        modifier = modifier
            .padding(horizontal = 16.dp, vertical = 4.dp)
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(
                MaterialTheme.colorScheme.surfaceContainerLow,
            )
            .clickable(onClick = onClick)
            .padding(horizontal = 8.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(
            onClick = {},
            modifier = dragHandleModifier.size(40.dp),
        ) {
            Icon(
                imageVector = Icons.Default.DragHandle,
                contentDescription = stringResource(
                    R.string.request_control_drag_to_reorder,
                ),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Icon(
            imageVector = icon.image,
            contentDescription = null,
            tint = if (control.isEnabled) {
                MaterialTheme.colorScheme.primary
            } else {
                MaterialTheme.colorScheme.onSurfaceVariant
            },
            modifier = Modifier.size(22.dp),
        )
        Spacer(Modifier.width(12.dp))
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                text = displayTitle,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = summary,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Icon(
            imageVector =
                Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant
                .copy(alpha = 0.5f),
            modifier = Modifier.size(20.dp),
        )
    }
}

@Composable
private fun requestControlDisplayTitle(
    control: RequestBodyControl,
): String =
    if (
        control.semanticKind ==
            RequestBodyControl.SemanticKind.thinkingBudget &&
        (
            control.title.isBlank() ||
                control.title == "Thinking Intensity"
            )
    ) {
        stringResource(R.string.thinking_level_sheet_title)
    } else {
        control.title
    }

@Composable
private fun MinixRequestControlDetailScreen(
    control: RequestBodyControl,
    onChange: (RequestBodyControl) -> Unit,
    onDelete: () -> Unit,
    onBack: () -> Unit,
) {
    val displayTitle = requestControlDisplayTitle(control)
    var showHelp by remember { mutableStateOf(false) }
    var showIconPicker by remember { mutableStateOf(false) }
    var editingOptionId by remember {
        mutableStateOf<String?>(null)
    }
    var showSliderColors by remember {
        mutableStateOf(false)
    }

    val editingOption = editingOptionId?.let { optionId ->
        control.options.firstOrNull { it.id == optionId }
    }
    if (editingOption != null) {
        MinixRequestControlOptionDetailScreen(
            option = editingOption,
            isThinkingBudget =
                control.semanticKind ==
                    RequestBodyControl.SemanticKind.thinkingBudget,
            existingThinkingDefinitionIds =
                control.options.mapNotNull { candidate ->
                    if (candidate.id == editingOption.id) {
                        null
                    } else {
                        candidate.thinkingDefinitionId
                    }
                }.toSet(),
            onChange = { next ->
                val index = control.options.indexOfFirst {
                    it.id == editingOption.id
                }
                updateOption(control, index, next)
                    ?.let(onChange)
            },
            onDelete = {
                val index = control.options.indexOfFirst {
                    it.id == editingOption.id
                }
                removeOption(control, index)?.let(onChange)
                editingOptionId = null
            },
            onBack = { editingOptionId = null },
        )
        return
    }
    if (showSliderColors) {
        MinixSliderColorSettingsScreen(
            control = control,
            onChange = onChange,
            onBack = { showSliderColors = false },
        )
        return
    }
    if (showIconPicker) {
        RequestControlIconPickerScreen(
            control = control,
            onSelect = { iconName ->
                onChange(control.copy(iconName = iconName))
            },
            onBack = { showIconPicker = false },
        )
        return
    }

    BackHandler(onBack = onBack)

    if (showHelp) {
        RequestExpressionHelpDialog(
            onDismiss = { showHelp = false },
        )
    }
    SettingsScaffold(
        title = displayTitle.ifBlank {
            stringResource(R.string.request_control_details)
        },
        onBack = onBack,
    ) {
        SettingsSection(
            header = stringResource(
                R.string.request_control_details,
            ),
        ) {
            SettingsCardBlock {
                RowLabel(
                    text = stringResource(
                        R.string.request_control_title,
                    ),
                )
                SectionTextField(
                    value = displayTitle,
                    onValueChange = {
                        onChange(control.copy(title = it))
                    },
                    singleLine = true,
                )
            }
            HorizontalDivider(
                modifier = Modifier.padding(
                    start = 14.dp,
                    end = 14.dp,
                ),
                color = MaterialTheme.colorScheme.outlineVariant
                    .copy(alpha = 0.5f),
            )
            SettingsSwitchRow(
                title = stringResource(
                    R.string.request_control_enabled,
                ),
                checked = control.isEnabled,
                onCheckedChange = {
                    onChange(control.copy(isEnabled = it))
                },
            )
            val icon = RequestControlIcons.resolve(control)
            SettingsRow(
                title = stringResource(
                    R.string.request_control_icon,
                ),
                subtitle = icon.id,
                icon = icon.image,
                onClick = { showIconPicker = true },
                showDivider = false,
            )
        }

        when (control.kind) {
            RequestBodyControl.Kind.toggle -> {
                ToggleControlEditor(
                    control = control,
                    onChange = onChange,
                    onHelp = { showHelp = true },
                )
            }
            RequestBodyControl.Kind.optionGroup -> {
                OptionGroupControlEditor(
                    control = control,
                    onChange = onChange,
                    onEditOption = {
                        editingOptionId = it
                    },
                    onEditSliderColors = {
                        showSliderColors = true
                    },
                )
            }
        }

        SettingsSection {
            SettingsRow(
                title = stringResource(
                    R.string.request_control_delete,
                ),
                titleColor = MaterialTheme.colorScheme.error,
                showChevron = false,
                showDivider = false,
                onClick = onDelete,
            )
        }
    }
}

@Composable
private fun ToggleControlEditor(
    control: RequestBodyControl,
    onChange: (RequestBodyControl) -> Unit,
    onHelp: () -> Unit,
) {
    val issues = RequestExpressionValidator.validate(
        control.payloadExpressions,
        RequestExpressionValidator.Target.CONTROL,
    )
    SettingsSection(
        header = stringResource(
            R.string.request_control_payload_on,
        ),
        footer = stringResource(
            R.string.request_control_toggle_footer,
        ),
    ) {
        SettingsSwitchRow(
            title = stringResource(
                R.string.request_control_default_on,
            ),
            checked = control.defaultIsActive,
            onCheckedChange = {
                onChange(control.copy(defaultIsActive = it))
            },
        )
        SettingsCardBlock {
            ExpressionFieldLabel(
                text = stringResource(
                    R.string.request_control_payload,
                ),
                onHelp = onHelp,
            )
            SectionTextField(
                value = control.payloadExpressions
                    .joinToString("\n"),
                onValueChange = {
                    onChange(
                        control.copy(
                            payloadExpressions =
                                requestExpressionLines(it),
                        ),
                    )
                },
                singleLine = false,
                maxLines = 5,
                placeholder = stringResource(
                    R.string.request_control_toggle_placeholder,
                ),
                isError = issues.isNotEmpty(),
                textStyle = MaterialTheme.typography.bodyMedium
                    .copy(fontFamily = FontFamily.Monospace),
            )
            ExpressionValidationIssues(issues)
        }
    }
}

@Composable
private fun OptionGroupControlEditor(
    control: RequestBodyControl,
    onChange: (RequestBodyControl) -> Unit,
    onEditOption: (String) -> Unit,
    onEditSliderColors: () -> Unit,
) {
    val context = LocalContext.current
    var showDefaultOptions by remember {
        mutableStateOf(false)
    }
    var showThinkingDefinitions by remember {
        mutableStateOf(false)
    }
    val isThinkingBudget =
        control.semanticKind ==
            RequestBodyControl.SemanticKind.thinkingBudget
    val options = if (isThinkingBudget) {
        ThinkingLevelRegistry.sortedThinkingOptions(
            control.options,
            context,
        )
    } else {
        control.options
    }
    val existingDefinitionIds =
        control.options.mapNotNull {
            it.thinkingDefinitionId
        }.toSet()
    val availableDefinitions =
        if (isThinkingBudget) {
            ThinkingLevelRegistry.definitions(context)
                .filter {
                    it.definitionId !in existingDefinitionIds
                }
        } else {
            emptyList()
        }

    SettingsSection(
        header = stringResource(
            R.string.request_control_presentation,
        ),
    ) {
        val hasDefaultOption =
            !isThinkingBudget && options.isNotEmpty()
        SettingsSwitchRow(
            title = stringResource(
                R.string.request_control_slider,
            ),
            checked = control.isSliderEnabled,
            onCheckedChange = {
                onChange(control.copy(isSliderEnabled = it))
            },
            showDivider =
                hasDefaultOption || control.isSliderEnabled,
        )
        if (control.isSliderEnabled) {
            SettingsRow(
                title = stringResource(
                    R.string.request_control_slider_colors,
                ),
                onClick = onEditSliderColors,
                showDivider = hasDefaultOption,
            )
        }
        if (hasDefaultOption) {
            val defaultOption = options.firstOrNull {
                it.id == control.defaultOptionID
            } ?: options.first()
            SettingsValueRow(
                title = stringResource(
                    R.string.request_control_default_option,
                ),
                value = defaultOption.title,
                showDivider = false,
                onClick = { showDefaultOptions = true },
            )
        }
    }

    SettingsSection(
        header = stringResource(
            R.string.request_control_options,
        ),
        footer = stringResource(
            if (isThinkingBudget) {
                R.string.request_control_thinking_options_footer
            } else {
                R.string.request_control_custom_options_footer
            },
        ),
    ) {
        if (options.isEmpty()) {
            SettingsRow(
                title = stringResource(
                    R.string.request_control_no_options,
                ),
                titleColor = MaterialTheme.colorScheme
                    .onSurfaceVariant,
                showChevron = false,
                showDivider =
                    !isThinkingBudget ||
                        availableDefinitions.isNotEmpty(),
            )
        } else if (isThinkingBudget) {
            options.forEach { option ->
                val definition = ThinkingLevelRegistry.definition(
                    option.thinkingDefinitionId,
                    context,
                )
                SwipeToDeleteRequestRow(
                    onDelete = {
                        val index = control.options.indexOfFirst {
                            it.id == option.id
                        }
                        removeOption(control, index)?.let(onChange)
                    },
                    backgroundModifier = Modifier.padding(
                        horizontal = 16.dp,
                        vertical = 4.dp,
                    ),
                ) {
                    RequestControlOptionSummaryRow(
                        title = option.title,
                        subtitle = definition?.levelId
                            ?: stringResource(
                                R.string
                                    .request_control_level_id_unknown,
                            ),
                        onClick = { onEditOption(option.id) },
                    )
                }
            }
        } else {
            ReorderableRequestControlOptions(
                control = control,
                onChange = onChange,
                onEditOption = onEditOption,
            )
        }

        if (
            isThinkingBudget &&
            availableDefinitions.isNotEmpty()
        ) {
            SettingsRow(
                title = stringResource(
                    R.string.request_control_add_level,
                ),
                icon = Icons.Default.Add,
                titleColor = MaterialTheme.colorScheme.primary,
                showChevron = false,
                showDivider = false,
                onClick = {
                    showThinkingDefinitions = true
                },
            )
        } else if (!isThinkingBudget) {
            SettingsRow(
                title = stringResource(
                    R.string.request_control_add_option,
                ),
                icon = Icons.Default.Add,
                titleColor = MaterialTheme.colorScheme.primary,
                showChevron = false,
                showDivider = false,
                onClick = {
                    val option = RequestBodyControlOption(
                        title = context.getString(
                            R.string.request_control_default_option,
                        ),
                    )
                    onChange(
                        control.copy(
                            options = control.options + option,
                            defaultOptionID =
                                control.defaultOptionID
                                    ?: option.id,
                        ),
                    )
                },
            )
        }
    }

    if (showDefaultOptions) {
        MinixSelectionDialog(
            title = stringResource(
                R.string.request_control_default_option,
            ),
            items = options.map { option ->
                MinixSelectionItem(
                    id = option.id,
                    title = option.title,
                )
            },
            selectedId = control.defaultOptionID,
            onSelect = { optionId ->
                onChange(
                    control.copy(
                        defaultOptionID = optionId,
                    ),
                )
                showDefaultOptions = false
            },
            onDismiss = { showDefaultOptions = false },
        )
    }

    if (showThinkingDefinitions) {
        MinixSelectionDialog(
            title = stringResource(
                R.string.request_control_add_level,
            ),
            items = availableDefinitions.map { definition ->
                MinixSelectionItem(
                    id = definition.definitionId,
                    title = definition.title,
                    subtitle = definition.levelId,
                )
            },
            onSelect = { definitionId ->
                val definition =
                    availableDefinitions.firstOrNull {
                        it.definitionId == definitionId
                    } ?: return@MinixSelectionDialog
                val option = RequestBodyControlOption(
                    id = definition.definitionId,
                    thinkingDefinitionId =
                        definition.definitionId,
                    title = definition.title,
                )
                onChange(
                    control.copy(
                        options = control.options + option,
                        defaultOptionID =
                            control.defaultOptionID ?: option.id,
                    ),
                )
                showThinkingDefinitions = false
            },
            onDismiss = {
                showThinkingDefinitions = false
            },
        )
    }
}

@Composable
private fun ReorderableRequestControlOptions(
    control: RequestBodyControl,
    onChange: (RequestBodyControl) -> Unit,
    onEditOption: (String) -> Unit,
) {
    val lazyListState = rememberLazyListState()
    val reorderState = rememberReorderableLazyListState(
        lazyListState,
    ) { from, to ->
        val prefix = "request-control-option:"
        val fromId = (from.key as? String)
            ?.removePrefix(prefix)
            ?: return@rememberReorderableLazyListState
        val toId = (to.key as? String)
            ?.removePrefix(prefix)
            ?: return@rememberReorderableLazyListState
        val fromIndex = control.options.indexOfFirst {
            it.id == fromId
        }
        val toIndex = control.options.indexOfFirst {
            it.id == toId
        }
        if (fromIndex < 0 || toIndex < 0) {
            return@rememberReorderableLazyListState
        }
        val reordered = control.options.toMutableList().apply {
            add(toIndex, removeAt(fromIndex))
        }
        onChange(control.copy(options = reordered))
    }
    val visibleRows = control.options.size.coerceAtMost(6)

    LazyColumn(
        state = lazyListState,
        modifier = Modifier
            .fillMaxWidth()
            .height((visibleRows * 64).dp),
    ) {
        items(
            items = control.options,
            key = { "request-control-option:${it.id}" },
        ) { option ->
            val key = "request-control-option:${option.id}"
            ReorderableItem(
                state = reorderState,
                key = key,
            ) { isDragging ->
                val optionIndex = control.options.indexOfFirst {
                    it.id == option.id
                }
                SwipeToDeleteRequestRow(
                    onDelete = {
                        removeOption(
                            control,
                            optionIndex,
                        )?.let(onChange)
                    },
                    backgroundModifier = Modifier.padding(
                        horizontal = 16.dp,
                        vertical = 4.dp,
                    ),
                    modifier = Modifier.alpha(
                        if (isDragging) 0.72f else 1f,
                    ),
                ) {
                    RequestControlOptionSummaryRow(
                        title = option.title,
                        subtitle = stringResource(
                            R.string
                                .request_control_option_expression_count,
                            option.payloadExpressions.size,
                        ),
                        onClick = {
                            onEditOption(option.id)
                        },
                        dragHandleModifier =
                            Modifier.draggableHandle(),
                    )
                }
            }
        }
    }
}

@Composable
private fun RequestControlOptionSummaryRow(
    title: String,
    subtitle: String,
    onClick: () -> Unit,
    dragHandleModifier: Modifier? = null,
) {
    Row(
        modifier = Modifier
            .padding(horizontal = 16.dp, vertical = 4.dp)
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(
                MaterialTheme.colorScheme.surfaceContainerLow,
            )
            .clickable(onClick = onClick)
            .padding(horizontal = 8.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (dragHandleModifier != null) {
            IconButton(
                onClick = {},
                modifier = dragHandleModifier.size(40.dp),
            ) {
                Icon(
                    imageVector = Icons.Default.DragHandle,
                    contentDescription = stringResource(
                        R.string.request_control_drag_to_reorder,
                    ),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        } else {
            Spacer(Modifier.width(12.dp))
        }
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Icon(
            imageVector =
                Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant
                .copy(alpha = 0.5f),
            modifier = Modifier.size(20.dp),
        )
    }
}

@Composable
private fun MinixRequestControlOptionDetailScreen(
    option: RequestBodyControlOption,
    isThinkingBudget: Boolean,
    existingThinkingDefinitionIds: Set<String>,
    onChange: (RequestBodyControlOption) -> Unit,
    onDelete: () -> Unit,
    onBack: () -> Unit,
) {
    val context = LocalContext.current
    var showHelp by remember { mutableStateOf(false) }
    var showThinkingDefinitions by remember {
        mutableStateOf(false)
    }
    if (showThinkingDefinitions) {
        val definitions =
            ThinkingLevelRegistry.definitions(context)
                .filter {
                    it.definitionId ==
                        option.thinkingDefinitionId ||
                        it.definitionId !in
                        existingThinkingDefinitionIds
                }
        MinixSelectionScreen(
            title = stringResource(
                R.string.request_control_thinking_level,
            ),
            items = definitions.map { definition ->
                MinixSelectionItem(
                    id = definition.definitionId,
                    title = definition.title,
                    subtitle = definition.levelId,
                )
            },
            selectedId = option.thinkingDefinitionId,
            onSelect = { definitionId ->
                onChange(
                    option.copy(
                        thinkingDefinitionId = definitionId,
                    ),
                )
                showThinkingDefinitions = false
            },
            onBack = { showThinkingDefinitions = false },
        )
        return
    }
    BackHandler(onBack = onBack)
    if (showHelp) {
        RequestExpressionHelpDialog(
            onDismiss = { showHelp = false },
        )
    }
    val definition = ThinkingLevelRegistry.definition(
        option.thinkingDefinitionId,
        context,
    )

    SettingsScaffold(
        title = option.title.ifBlank {
            stringResource(R.string.request_control_default_option)
        },
        onBack = onBack,
    ) {
        SettingsSection(
            header = stringResource(
                R.string.request_control_option_details,
            ),
        ) {
            SettingsCardBlock {
                RowLabel(
                    text = stringResource(
                        R.string.model_entry_display_name,
                    ),
                )
                SectionTextField(
                    value = option.title,
                    onValueChange = {
                        onChange(option.copy(title = it))
                    },
                    singleLine = true,
                )
            }
            if (isThinkingBudget) {
                HorizontalDivider(
                    modifier = Modifier.padding(
                        start = 14.dp,
                        end = 14.dp,
                    ),
                    color = MaterialTheme.colorScheme
                        .outlineVariant.copy(alpha = 0.5f),
                )
                SettingsValueRow(
                    title = stringResource(
                        R.string.request_control_thinking_level,
                    ),
                    value = definition?.title
                        ?: stringResource(
                            R.string.request_control_level_id_unknown,
                        ),
                    subtitle = definition?.levelId,
                    onClick = {
                        showThinkingDefinitions = true
                    },
                    showDivider = false,
                )
            }
        }

        SettingsSection(
            header = stringResource(
                R.string.request_control_payload,
            ),
            footer = stringResource(
                R.string.request_control_option_payload_footer,
            ),
        ) {
            SettingsCardBlock {
                ExpressionFieldLabel(
                    text = stringResource(
                        R.string.request_control_payload,
                    ),
                    onHelp = { showHelp = true },
                )
                val issues = RequestExpressionValidator.validate(
                    option.payloadExpressions,
                    RequestExpressionValidator.Target.CONTROL,
                )
                SectionTextField(
                    value = option.payloadExpressions
                        .joinToString("\n"),
                    onValueChange = {
                        onChange(
                            option.copy(
                                payloadExpressions =
                                    requestExpressionLines(it),
                            ),
                        )
                    },
                    singleLine = false,
                    maxLines = 8,
                    placeholder = stringResource(
                        R.string.request_control_option_placeholder,
                    ),
                    isError = issues.isNotEmpty(),
                    textStyle = MaterialTheme.typography.bodyMedium
                        .copy(fontFamily = FontFamily.Monospace),
                )
                ExpressionValidationIssues(issues)
            }
        }

        SettingsSection {
            SettingsRow(
                title = stringResource(
                    R.string.request_control_delete_option,
                ),
                titleColor = MaterialTheme.colorScheme.error,
                showChevron = false,
                showDivider = false,
                onClick = onDelete,
            )
        }
    }
}

@Composable
private fun MinixSliderColorSettingsScreen(
    control: RequestBodyControl,
    onChange: (RequestBodyControl) -> Unit,
    onBack: () -> Unit,
) {
    var editingEndpoint by remember(control.id) {
        mutableStateOf<RequestControlColorEndpoint?>(null)
    }
    var startDraft by remember(control.id) {
        mutableStateOf(
            control.sliderStartColorHex
                ?: REQUEST_CONTROL_DEFAULT_SLIDER_START_COLOR_HEX,
        )
    }
    var endDraft by remember(control.id) {
        mutableStateOf(
            control.sliderEndColorHex
                ?: REQUEST_CONTROL_DEFAULT_SLIDER_END_COLOR_HEX,
        )
    }
    BackHandler(onBack = onBack)

    fun updateStart(raw: String) {
        startDraft = raw
        onChange(control.copy(sliderStartColorHex = raw))
    }

    fun updateEnd(raw: String) {
        endDraft = raw
        onChange(control.copy(sliderEndColorHex = raw))
    }

    val endpoint = editingEndpoint
    if (endpoint != null) {
        val isStart =
            endpoint == RequestControlColorEndpoint.START
        MinixRequestControlColorPickerScreen(
            title = stringResource(
                if (isStart) {
                    R.string.request_control_slider_low_color
                } else {
                    R.string.request_control_slider_high_color
                },
            ),
            initialHex = if (isStart) {
                startDraft
            } else {
                endDraft
            },
            onColorChange = if (isStart) {
                ::updateStart
            } else {
                ::updateEnd
            },
            onBack = { editingEndpoint = null },
        )
        return
    }

    SettingsScaffold(
        title = stringResource(
            R.string.request_control_slider_colors,
        ),
        onBack = onBack,
    ) {
        SettingsSection(
            header = stringResource(
                R.string.request_control_slider_preview,
            ),
        ) {
            SettingsCardBlock {
                MinixSliderGradientPreview(
                    control.copy(
                        sliderStartColorHex = startDraft,
                        sliderEndColorHex = endDraft,
                    ),
                )
            }
        }

        SettingsSection(
            footer = stringResource(
                R.string.request_control_slider_colors_footer,
            ),
        ) {
            RequestControlColorValueRow(
                title = stringResource(
                    R.string.request_control_slider_low_color,
                ),
                hex = startDraft,
                onClick = {
                    editingEndpoint =
                        RequestControlColorEndpoint.START
                },
            )
            RequestControlColorValueRow(
                title = stringResource(
                    R.string.request_control_slider_high_color,
                ),
                hex = endDraft,
                showDivider = false,
                onClick = {
                    editingEndpoint =
                        RequestControlColorEndpoint.END
                },
            )
        }

        SettingsSection {
            SettingsRow(
                title = stringResource(
                    R.string.model_entry_reset_to_default,
                ),
                showChevron = false,
                showDivider = false,
                onClick = {
                    startDraft =
                        REQUEST_CONTROL_DEFAULT_SLIDER_START_COLOR_HEX
                    endDraft =
                        REQUEST_CONTROL_DEFAULT_SLIDER_END_COLOR_HEX
                    onChange(
                        control.copy(
                            sliderStartColorHex = null,
                            sliderEndColorHex = null,
                        ),
                    )
                },
            )
        }
    }
}

private enum class RequestControlColorEndpoint {
    START,
    END,
}

@Composable
private fun RequestControlColorValueRow(
    title: String,
    hex: String,
    onClick: () -> Unit,
    showDivider: Boolean = true,
) {
    SettingsRow(
        title = title,
        subtitle = hex,
        onClick = onClick,
        showDivider = showDivider,
        trailing = {
            Box(
                modifier = Modifier
                    .size(28.dp)
                    .background(
                        requestControlColorFromHex(hex)
                            ?: Color.Transparent,
                        CircleShape,
                    )
                    .border(
                        1.dp,
                        MaterialTheme.colorScheme.outlineVariant,
                        CircleShape,
                    ),
            )
        },
    )
}

@Composable
private fun MinixRequestControlColorPickerScreen(
    title: String,
    initialHex: String,
    onColorChange: (String) -> Unit,
    onBack: () -> Unit,
) {
    val initial = remember(title) {
        requestControlHsvFromHex(initialHex)
    }
    var hue by remember(title) {
        mutableStateOf(initial[0])
    }
    var saturation by remember(title) {
        mutableStateOf(initial[1])
    }
    var brightness by remember(title) {
        mutableStateOf(initial[2])
    }
    val selectedColor =
        requestControlColorFromHsv(
            hue,
            saturation,
            brightness,
        )
    val selectedHex =
        requestControlHexFromHsv(
            hue,
            saturation,
            brightness,
        )

    fun updateColor(
        nextHue: Float = hue,
        nextSaturation: Float = saturation,
        nextBrightness: Float = brightness,
    ) {
        onColorChange(
            requestControlHexFromHsv(
                nextHue,
                nextSaturation,
                nextBrightness,
            ),
        )
    }

    BackHandler(onBack = onBack)
    SettingsScaffold(
        title = title,
        onBack = onBack,
    ) {
        SettingsSection(
            header = stringResource(
                R.string.request_control_slider_preview,
            ),
        ) {
            SettingsCardBlock {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(88.dp)
                        .background(
                            selectedColor,
                            RoundedCornerShape(14.dp),
                        )
                        .border(
                            1.dp,
                            MaterialTheme.colorScheme
                                .outlineVariant,
                            RoundedCornerShape(14.dp),
                        ),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = selectedHex,
                        color = if (brightness > 0.55f) {
                            Color.Black
                        } else {
                            Color.White
                        },
                        fontFamily = FontFamily.Monospace,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }
        }

        SettingsSection(
            header = stringResource(
                R.string.request_control_color_picker,
            ),
        ) {
            SettingsCardBlock {
                RequestControlColorComponentSlider(
                    title = stringResource(
                        R.string.request_control_color_hue,
                    ),
                    value = hue,
                    valueRange = 0f..360f,
                    gradient = listOf(
                        requestControlColorFromHsv(0f, 1f, 1f),
                        requestControlColorFromHsv(60f, 1f, 1f),
                        requestControlColorFromHsv(120f, 1f, 1f),
                        requestControlColorFromHsv(180f, 1f, 1f),
                        requestControlColorFromHsv(240f, 1f, 1f),
                        requestControlColorFromHsv(300f, 1f, 1f),
                        requestControlColorFromHsv(360f, 1f, 1f),
                    ),
                    thumbColor = selectedColor,
                    onValueChange = {
                        hue = it
                        updateColor(nextHue = it)
                    },
                )
                HorizontalDivider(
                    color = MaterialTheme.colorScheme
                        .outlineVariant.copy(alpha = 0.5f),
                )
                RequestControlColorComponentSlider(
                    title = stringResource(
                        R.string.request_control_color_saturation,
                    ),
                    value = saturation,
                    gradient = listOf(
                        requestControlColorFromHsv(
                            hue,
                            0f,
                            brightness,
                        ),
                        requestControlColorFromHsv(
                            hue,
                            1f,
                            brightness,
                        ),
                    ),
                    thumbColor = selectedColor,
                    onValueChange = {
                        saturation = it
                        updateColor(nextSaturation = it)
                    },
                )
                HorizontalDivider(
                    color = MaterialTheme.colorScheme
                        .outlineVariant.copy(alpha = 0.5f),
                )
                RequestControlColorComponentSlider(
                    title = stringResource(
                        R.string.request_control_color_brightness,
                    ),
                    value = brightness,
                    gradient = listOf(
                        Color.Black,
                        requestControlColorFromHsv(
                            hue,
                            saturation,
                            1f,
                        ),
                    ),
                    thumbColor = selectedColor,
                    onValueChange = {
                        brightness = it
                        updateColor(nextBrightness = it)
                    },
                )
            }
        }
    }
}

@Composable
private fun RequestControlColorComponentSlider(
    title: String,
    value: Float,
    gradient: List<Color>,
    thumbColor: Color,
    onValueChange: (Float) -> Unit,
    valueRange: ClosedFloatingPointRange<Float> = 0f..1f,
) {
    Column(
        modifier = Modifier.padding(vertical = 10.dp),
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.Medium,
        )
        Spacer(Modifier.height(4.dp))
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(40.dp),
            contentAlignment = Alignment.Center,
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(10.dp)
                    .clip(RoundedCornerShape(50))
                    .background(
                        Brush.horizontalGradient(gradient),
                    )
                    .border(
                        0.5.dp,
                        MaterialTheme.colorScheme
                            .outlineVariant,
                        RoundedCornerShape(50),
                    ),
            )
            Slider(
                value = value,
                onValueChange = onValueChange,
                valueRange = valueRange,
                colors = SliderDefaults.colors(
                    thumbColor = thumbColor,
                    activeTrackColor = Color.Transparent,
                    inactiveTrackColor = Color.Transparent,
                    activeTickColor = Color.Transparent,
                    inactiveTickColor = Color.Transparent,
                ),
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

@Composable
private fun MinixSliderGradientPreview(
    control: RequestBodyControl,
) {
    val startColor = requestControlColorFromHex(
        control.sliderStartColorHex,
    ) ?: requestControlColorFromHex(
        REQUEST_CONTROL_DEFAULT_SLIDER_START_COLOR_HEX,
    )!!
    val endColor = requestControlColorFromHex(
        control.sliderEndColorHex,
    ) ?: requestControlColorFromHex(
        REQUEST_CONTROL_DEFAULT_SLIDER_END_COLOR_HEX,
    )!!
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(28.dp)
            .clip(RoundedCornerShape(50))
            .background(
                Brush.horizontalGradient(
                    listOf(startColor, endColor),
                ),
            )
            .border(
                width = 1.dp,
                color = MaterialTheme.colorScheme
                    .outlineVariant.copy(alpha = 0.6f),
                shape = RoundedCornerShape(50),
            ),
    )
}

private data class MinixSelectionItem(
    val id: String,
    val title: String,
    val subtitle: String? = null,
)

@Composable
private fun SwipeToDeleteRequestRow(
    onDelete: () -> Unit,
    modifier: Modifier = Modifier,
    backgroundModifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    val dismissState = rememberSwipeToDismissBoxState()
    LaunchedEffect(dismissState.currentValue) {
        if (
            dismissState.currentValue ==
            SwipeToDismissBoxValue.EndToStart
        ) {
            onDelete()
            dismissState.reset()
        }
    }
    SwipeToDismissBox(
        state = dismissState,
        backgroundContent = {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .then(backgroundModifier)
                    .clip(RoundedCornerShape(14.dp))
                    .background(
                        MaterialTheme.colorScheme.errorContainer,
                    )
                    .padding(horizontal = 16.dp),
                contentAlignment = Alignment.CenterEnd,
            ) {
                Text(
                    text = stringResource(R.string.common_delete),
                    color = MaterialTheme.colorScheme
                        .onErrorContainer,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        },
        enableDismissFromStartToEnd = false,
        modifier = modifier,
        content = { content() },
    )
}

@Composable
private fun MinixSelectionDialog(
    title: String,
    items: List<MinixSelectionItem>,
    onSelect: (String) -> Unit,
    onDismiss: () -> Unit,
    selectedId: String? = null,
    emptyMessage: String? = null,
) {
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
        ),
    ) {
        Surface(
            modifier = Modifier.fillMaxSize(),
            color = MaterialTheme.colorScheme.background,
        ) {
            MinixSelectionScreen(
                title = title,
                items = items,
                selectedId = selectedId,
                emptyMessage = emptyMessage,
                onSelect = onSelect,
                onBack = onDismiss,
            )
        }
    }
}

@Composable
private fun MinixSelectionScreen(
    title: String,
    items: List<MinixSelectionItem>,
    onSelect: (String) -> Unit,
    onBack: () -> Unit,
    selectedId: String? = null,
    emptyMessage: String? = null,
) {
    BackHandler(onBack = onBack)
    SettingsScaffold(
        title = title,
        onBack = onBack,
        scrollable = false,
    ) {
        if (items.isEmpty()) {
            Box(
                modifier = Modifier.fillMaxSize(),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = emptyMessage
                        ?: stringResource(
                            R.string.request_control_no_options,
                        ),
                    color = MaterialTheme.colorScheme
                        .onSurfaceVariant,
                    modifier = Modifier.padding(24.dp),
                )
            }
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(
                    horizontal = 16.dp,
                    vertical = 12.dp,
                ),
                verticalArrangement =
                    Arrangement.spacedBy(8.dp),
            ) {
                items(
                    items = items,
                    key = { "selection:${it.id}" },
                ) { item ->
                    Surface(
                        color = MaterialTheme.colorScheme
                            .surfaceContainerLow,
                        shape = RoundedCornerShape(14.dp),
                    ) {
                        SettingsRow(
                            title = item.title,
                            subtitle = item.subtitle,
                            onClick = { onSelect(item.id) },
                            showChevron = false,
                            showDivider = false,
                            trailing = if (
                                item.id == selectedId
                            ) {
                                {
                                    Icon(
                                        imageVector =
                                            Icons.Default.Check,
                                        contentDescription = null,
                                        tint = MaterialTheme
                                            .colorScheme.primary,
                                    )
                                }
                            } else {
                                null
                            },
                            minHeight = 64.dp,
                        )
                    }
                }
            }
        }
    }
}

private fun normalizedRequestControlHex(
    raw: String,
): String? {
    val value = raw.trim()
    val normalized = if (value.startsWith("#")) {
        value
    } else {
        "#$value"
    }
    return normalized.takeIf {
        it.matches(Regex("^#[0-9A-Fa-f]{6}$"))
    }?.uppercase()
}

private fun requestControlColorFromHex(
    raw: String?,
): Color? {
    val normalized = raw?.let(::normalizedRequestControlHex)
        ?: return null
    return runCatching {
        Color(android.graphics.Color.parseColor(normalized))
    }.getOrNull()
}

private fun requestControlHsvFromHex(
    raw: String,
): FloatArray {
    val normalized =
        normalizedRequestControlHex(raw)
            ?: REQUEST_CONTROL_DEFAULT_SLIDER_START_COLOR_HEX
    val hsv = FloatArray(3)
    android.graphics.Color.colorToHSV(
        android.graphics.Color.parseColor(normalized),
        hsv,
    )
    return hsv
}

private fun requestControlColorFromHsv(
    hue: Float,
    saturation: Float,
    brightness: Float,
): Color =
    Color(
        android.graphics.Color.HSVToColor(
            floatArrayOf(
                hue.coerceIn(0f, 360f),
                saturation.coerceIn(0f, 1f),
                brightness.coerceIn(0f, 1f),
            ),
        ),
    )

private fun requestControlHexFromHsv(
    hue: Float,
    saturation: Float,
    brightness: Float,
): String {
    val color = android.graphics.Color.HSVToColor(
        floatArrayOf(
            hue.coerceIn(0f, 360f),
            saturation.coerceIn(0f, 1f),
            brightness.coerceIn(0f, 1f),
        ),
    )
    return String.format(
        Locale.US,
        "#%06X",
        color and 0x00FFFFFF,
    )
}

private fun updateControl(
    controls: List<RequestBodyControl>,
    index: Int,
    next: RequestBodyControl,
): List<RequestBodyControl>? {
    if (index !in controls.indices) return null
    return controls.toMutableList().also { it[index] = next }
}

private fun updateOption(
    control: RequestBodyControl,
    index: Int,
    next: RequestBodyControlOption,
): RequestBodyControl? {
    if (index !in control.options.indices) return null
    val options = control.options.toMutableList().also { it[index] = next }
    return control.copy(options = options)
}

private fun removeOption(
    control: RequestBodyControl,
    index: Int,
): RequestBodyControl? {
    if (index !in control.options.indices) return null
    val options = control.options.toMutableList()
    val removed = options.removeAt(index)
    val defaultId = if (control.defaultOptionID == removed.id) {
        options.firstOrNull()?.id
    } else {
        control.defaultOptionID
    }
    return control.copy(options = options, defaultOptionID = defaultId)
}
