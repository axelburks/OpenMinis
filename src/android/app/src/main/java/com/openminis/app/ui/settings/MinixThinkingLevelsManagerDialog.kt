package com.openminis.app.ui.settings

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.DragHandle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.openminis.app.MinisApp
import com.openminis.app.R
import com.openminis.app.data.model.ThinkingLevelDefinition
import com.openminis.app.data.model.ThinkingLevelRegistry
import com.openminis.app.data.repository.ProviderRepository
import com.openminis.app.ui.components.MinisButton
import com.openminis.app.ui.components.MinisTextButton
import com.openminis.app.ui.components.RowLabel
import com.openminis.app.ui.components.SectionTextField
import kotlinx.coroutines.launch
import sh.calvin.reorderable.ReorderableItem
import sh.calvin.reorderable.rememberReorderableLazyListState

@Composable
internal fun ThinkingLevelsManagerScreen(
    providerRepository: ProviderRepository,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val originalItems = remember {
        ThinkingLevelRegistry.definitions(context)
    }
    var items by remember {
        mutableStateOf(originalItems)
    }
    var showAddDialog by remember {
        mutableStateOf(false)
    }
    var editingDefinitionId by remember {
        mutableStateOf<String?>(null)
    }
    var pendingDelete by remember {
        mutableStateOf<Pair<String, Int>?>(null)
    }
    var showUnsavedChangesDialog by remember {
        mutableStateOf(false)
    }
    val coroutineScope = rememberCoroutineScope()
    val lazyListState = rememberLazyListState()
    val reorderState = rememberReorderableLazyListState(
        lazyListState,
    ) { from, to ->
        val prefix = "thinking-level:"
        val fromId = (from.key as? String)
            ?.removePrefix(prefix)
            ?: return@rememberReorderableLazyListState
        val toId = (to.key as? String)
            ?.removePrefix(prefix)
            ?: return@rememberReorderableLazyListState
        val fromIndex = items.indexOfFirst {
            it.definitionId == fromId
        }
        val toIndex = items.indexOfFirst {
            it.definitionId == toId
        }
        if (fromIndex < 0 || toIndex < 0) {
            return@rememberReorderableLazyListState
        }
        items = items.toMutableList().apply {
            add(toIndex, removeAt(fromIndex))
        }.mapIndexed { index, definition ->
            definition.copy(rank = index)
        }
    }
    val customDefinitions = items.filterNot {
        it.isBuiltIn
    }
    val levelIds = customDefinitions.map { it.levelId }
    val canSave =
        levelIds.distinct().size == levelIds.size &&
            customDefinitions.all { definition ->
                definition.levelId ==
                    definition.levelId.trim() &&
                    definition.levelId.matches(
                        Regex("^[a-z0-9_]+$"),
                    ) &&
                    ThinkingLevelRegistry.builtInDefinitions.none {
                        it.levelId == definition.levelId
                    }
            }
    val hasUnsavedChanges = items != originalItems

    fun saveAndDismiss() {
        if (!canSave) return
        ThinkingLevelRegistry.saveDefinitions(
            context,
            items.mapIndexed { index, definition ->
                definition.copy(rank = index)
            },
        )
        onDismiss()
    }

    val requestClose = {
        if (hasUnsavedChanges) {
            showUnsavedChangesDialog = true
        } else {
            onDismiss()
        }
    }
    BackHandler(onBack = requestClose)

    Dialog(
        onDismissRequest = requestClose,
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
        ),
    ) {
        Surface(
            modifier = Modifier.fillMaxSize(),
            color = MaterialTheme.colorScheme.background,
        ) {
            SettingsScaffold(
                title = stringResource(
                    R.string.thinking_levels_manage,
                ),
                onBack = null,
                centerTitle = true,
                scrollable = false,
                navigation = {
                    MinisTextButton(
                        onClick = requestClose,
                        modifier = Modifier.padding(start = 8.dp),
                        colors = ButtonDefaults.textButtonColors(
                            contentColor = MaterialTheme
                                .colorScheme.onSurfaceVariant,
                        ),
                    ) {
                        Text(stringResource(R.string.common_cancel))
                    }
                },
                actions = {
                    MinisButton(
                        onClick = ::saveAndDismiss,
                        enabled = canSave,
                        modifier = Modifier.padding(end = 8.dp),
                    ) {
                        Text(stringResource(R.string.common_save))
                    }
                },
            ) {
                LazyColumn(
                    state = lazyListState,
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(
                        top = 16.dp,
                        bottom = 24.dp,
                    ),
                    verticalArrangement =
                        Arrangement.spacedBy(8.dp),
                ) {
                    item("thinking-level-header") {
                        Text(
                            text = stringResource(
                                R.string.thinking_levels_manage,
                            ).uppercase(),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme
                                .colorScheme.onSurfaceVariant,
                            fontWeight = FontWeight.Medium,
                            modifier = Modifier.padding(
                                horizontal = 32.dp,
                            ),
                        )
                    }
                    items(
                        items = items,
                        key = {
                            "thinking-level:${it.definitionId}"
                        },
                    ) { definition ->
                        val key =
                            "thinking-level:${definition.definitionId}"
                        ReorderableItem(
                            state = reorderState,
                            key = key,
                        ) { isDragging ->
                            DismissibleThinkingLevelRow(
                                definition = definition,
                                onEdit = {
                                    if (!definition.isBuiltIn) {
                                        editingDefinitionId =
                                            definition.definitionId
                                    }
                                },
                                onDelete = if (
                                    definition.isBuiltIn
                                ) {
                                    null
                                } else {
                                    {
                                        coroutineScope.launch {
                                            val app = context
                                                .applicationContext
                                                as? MinisApp
                                            val referenceCount =
                                                providerRepository
                                                    .thinkingDefinitionReferenceCount(
                                                        definition.definitionId,
                                                    ) +
                                                    (
                                                        app?.chatRepository
                                                            ?.thinkingDefinitionReferenceCount(
                                                                definition.definitionId,
                                                            )
                                                            ?: 0
                                                        )
                                            if (referenceCount > 0) {
                                                pendingDelete =
                                                    definition.definitionId to
                                                        referenceCount
                                            } else {
                                                items = items.filterNot {
                                                    it.definitionId ==
                                                        definition.definitionId
                                                }
                                            }
                                        }
                                    }
                                },
                                dragHandleModifier =
                                    Modifier.draggableHandle(),
                                modifier = Modifier.alpha(
                                    if (isDragging) 0.72f else 1f,
                                ),
                            )
                        }
                    }
                    item("thinking-level-footer") {
                        Text(
                            text = stringResource(
                                R.string.thinking_levels_reorder_footer,
                            ),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme
                                .colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(
                                horizontal = 32.dp,
                            ),
                        )
                    }
                    item("thinking-level-add") {
                        Box(
                            modifier = Modifier.padding(
                                horizontal = 16.dp,
                                vertical = 8.dp,
                            ),
                        ) {
                            SettingsRow(
                                title = stringResource(
                                    R.string.thinking_level_add,
                                ),
                                icon = Icons.Default.Add,
                                titleColor = MaterialTheme
                                    .colorScheme.primary,
                                showChevron = false,
                                showDivider = false,
                                onClick = {
                                    showAddDialog = true
                                },
                            )
                        }
                    }
                }
            }
        }
    }

    if (showUnsavedChangesDialog) {
        AlertDialog(
            onDismissRequest = {
                showUnsavedChangesDialog = false
            },
            title = {
                Text(stringResource(R.string.request_unsaved_title))
            },
            text = {
                Text(
                    stringResource(
                        R.string.thinking_levels_unsaved_message,
                    ),
                )
            },
            confirmButton = {
                TextButton(
                    onClick = ::saveAndDismiss,
                    enabled = canSave,
                ) {
                    Text(stringResource(R.string.common_save))
                }
            },
            dismissButton = {
                Column {
                    TextButton(onClick = onDismiss) {
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

    if (showAddDialog) {
        ThinkingLevelFormDialog(
            isEditing = false,
            initialLevelId = "",
            initialTitle = "",
            existingIDs = items.mapTo(mutableSetOf()) {
                it.levelId
            },
            onAdd = { definition ->
                items = items + definition.copy(rank = items.size)
                showAddDialog = false
            },
            onDismiss = { showAddDialog = false },
        )
    }

    editingDefinitionId?.let { definitionId ->
        items.firstOrNull {
            it.definitionId == definitionId
        }?.let { definition ->
            ThinkingLevelFormDialog(
                isEditing = true,
                initialLevelId = definition.levelId,
                initialTitle = definition.title,
                existingIDs = items
                    .filterNot {
                        it.definitionId == definitionId
                    }
                    .mapTo(mutableSetOf()) {
                        it.levelId
                    },
                onAdd = { updated ->
                    items = items.map {
                        if (it.definitionId == definitionId) {
                            updated.copy(
                                definitionId = definitionId,
                                rank = it.rank,
                            )
                        } else {
                            it
                        }
                    }
                    editingDefinitionId = null
                },
                onDismiss = {
                    editingDefinitionId = null
                },
            )
        }
    }

    pendingDelete?.let { (definitionId, count) ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = {
                Text(
                    stringResource(
                        R.string.thinking_level_delete_title,
                    ),
                )
            },
            text = {
                Text(
                    stringResource(
                        R.string.thinking_level_delete_referenced,
                        count,
                    ),
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        items = items.filterNot {
                            it.definitionId == definitionId &&
                                !it.isBuiltIn
                        }
                        pendingDelete = null
                    },
                ) {
                    Text(
                        stringResource(
                            R.string.thinking_level_delete,
                        ),
                        color = MaterialTheme.colorScheme.error,
                    )
                }
            },
            dismissButton = {
                TextButton(
                    onClick = { pendingDelete = null },
                ) {
                    Text(stringResource(R.string.common_cancel))
                }
            },
        )
    }
}

@Composable
private fun DismissibleThinkingLevelRow(
    definition: ThinkingLevelDefinition,
    onEdit: () -> Unit,
    onDelete: (() -> Unit)?,
    dragHandleModifier: Modifier,
    modifier: Modifier = Modifier,
) {
    if (onDelete == null) {
        ThinkingLevelRow(
            definition = definition,
            onEdit = onEdit,
            dragHandleModifier = dragHandleModifier,
            modifier = modifier,
        )
        return
    }
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
                    .padding(horizontal = 16.dp)
                    .fillMaxSize()
                    .clip(RoundedCornerShape(14.dp))
                    .background(
                        MaterialTheme.colorScheme.errorContainer,
                    )
                    .padding(horizontal = 16.dp),
                contentAlignment = Alignment.CenterEnd,
            ) {
                Text(
                    text = stringResource(
                        R.string.thinking_level_delete,
                    ),
                    color = MaterialTheme.colorScheme
                        .onErrorContainer,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        },
        enableDismissFromStartToEnd = false,
        modifier = modifier,
    ) {
        ThinkingLevelRow(
            definition = definition,
            onEdit = onEdit,
            dragHandleModifier = dragHandleModifier,
        )
    }
}

@Composable
private fun ThinkingLevelRow(
    definition: ThinkingLevelDefinition,
    onEdit: () -> Unit,
    dragHandleModifier: Modifier,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .padding(horizontal = 16.dp)
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(
                MaterialTheme.colorScheme.surfaceContainerLow,
            )
            .clickable(
                enabled = !definition.isBuiltIn,
                onClick = onEdit,
            )
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
                tint = MaterialTheme.colorScheme
                    .onSurfaceVariant,
            )
        }
        Spacer(Modifier.width(4.dp))
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            Text(
                text = definition.title,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = definition.levelId,
                style = MaterialTheme.typography.bodySmall,
                fontFamily = FontFamily.Monospace,
                color = MaterialTheme.colorScheme
                    .onSurfaceVariant,
            )
        }
        if (definition.isBuiltIn) {
            Text(
                text = stringResource(
                    R.string.thinking_level_built_in,
                ),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme
                    .onSurfaceVariant,
            )
        } else {
            Icon(
                imageVector = Icons.AutoMirrored.Filled
                    .KeyboardArrowRight,
                contentDescription = null,
                tint = MaterialTheme.colorScheme
                    .onSurfaceVariant.copy(alpha = 0.5f),
            )
        }
    }
}

@Composable
private fun ThinkingLevelFormDialog(
    isEditing: Boolean,
    initialLevelId: String,
    initialTitle: String,
    existingIDs: Set<String>,
    onAdd: (ThinkingLevelDefinition) -> Unit,
    onDismiss: () -> Unit,
) {
    var levelID by remember(initialLevelId) {
        mutableStateOf(initialLevelId)
    }
    var title by remember(initialTitle) {
        mutableStateOf(initialTitle)
    }
    val trimmedID = levelID.trim()
    val isValid =
        levelID == trimmedID &&
            trimmedID.matches(Regex("^[a-z0-9_]+$"))
    val isDuplicate = trimmedID in existingIDs

    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(
                stringResource(
                    if (isEditing) {
                        R.string.thinking_level_edit
                    } else {
                        R.string.thinking_level_add
                    },
                ),
            )
        },
        text = {
            Column {
                RowLabel(
                    text = stringResource(
                        R.string.request_control_level_id,
                    ),
                )
                SectionTextField(
                    value = levelID,
                    onValueChange = { levelID = it },
                    singleLine = true,
                    textStyle = MaterialTheme.typography.bodyMedium
                        .copy(fontFamily = FontFamily.Monospace),
                )
                if (levelID.isNotEmpty() && !isValid) {
                    Text(
                        text = stringResource(
                            R.string.thinking_level_id_invalid,
                        ),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error,
                    )
                } else if (isDuplicate) {
                    Text(
                        text = stringResource(
                            R.string.thinking_level_id_duplicate,
                        ),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error,
                    )
                }
                Spacer(Modifier.height(8.dp))
                RowLabel(
                    text = stringResource(
                        R.string.model_entry_display_name,
                    ),
                )
                SectionTextField(
                    value = title,
                    onValueChange = { title = it },
                    singleLine = true,
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = {
                    onAdd(
                        ThinkingLevelDefinition(
                            levelId = trimmedID,
                            title = title.trim()
                                .ifEmpty { trimmedID },
                            rank = 0,
                        ),
                    )
                },
                enabled = isValid && !isDuplicate,
            ) {
                Text(
                    stringResource(
                        if (isEditing) {
                            R.string.common_save
                        } else {
                            R.string.thinking_level_add
                        },
                    ),
                )
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.common_cancel))
            }
        },
    )
}
