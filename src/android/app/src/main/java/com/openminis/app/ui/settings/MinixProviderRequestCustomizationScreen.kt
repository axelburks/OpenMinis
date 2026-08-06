package com.openminis.app.ui.settings

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import com.openminis.app.data.repository.ProviderRepository
import com.openminis.app.ui.components.MinisAlertDialog
import com.openminis.app.ui.components.MinisButton
import com.openminis.app.ui.components.MinisTextButton

// [Minix] Provider request customization UI kept out of the upstream detail screen.

@Composable
internal fun ProviderRequestCustomizationScreen(
    instanceId: String,
    providerRepository: ProviderRepository,
    onBack: () -> Unit,
) {
    val config by providerRepository.config.collectAsState()
    val instance = config.instances.find { it.id == instanceId }
    if (instance == null) {
        LaunchedEffect(instanceId) { onBack() }
        return
    }

    val initialHeaders = remember(instanceId) {
        instance.customRequestHeaders
    }
    val initialBody = remember(instanceId) {
        instance.customRequestBody
    }
    var customHeaders by remember(instanceId) {
        mutableStateOf(initialHeaders.joinToString("\n"))
    }
    var customBody by remember(instanceId) {
        mutableStateOf(initialBody.joinToString("\n"))
    }
    var showHelp by remember { mutableStateOf(false) }
    var showUnsavedChangesDialog by remember {
        mutableStateOf(false)
    }

    val hasInvalidExpressions = hasInvalidRequestCustomization(
        customHeaders,
        customBody,
        emptyList(),
    )
    val hasUnsavedChanges =
        requestExpressionLines(customHeaders) != initialHeaders ||
            requestExpressionLines(customBody) != initialBody

    fun saveAndClose() {
        if (hasInvalidExpressions) return
        providerRepository.updateInstance(
            instance.copy(
                customRequestHeaders =
                    requestExpressionLines(customHeaders),
                customRequestBody =
                    requestExpressionLines(customBody),
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

    if (showHelp) {
        RequestExpressionHelpDialog(
            onDismiss = { showHelp = false },
        )
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
                        R.string.provider_request_unsaved_message,
                    ),
                )
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
                    onHeadersChange = { customHeaders = it },
                    body = customBody,
                    onBodyChange = { customBody = it },
                    headerTitle = stringResource(
                        R.string.provider_detail_custom_request_headers,
                    ),
                    bodyTitle = stringResource(
                        R.string.provider_detail_custom_request_body,
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
}
