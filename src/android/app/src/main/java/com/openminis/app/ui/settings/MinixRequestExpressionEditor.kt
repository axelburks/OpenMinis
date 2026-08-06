package com.openminis.app.ui.settings

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.openminis.app.R
import com.openminis.app.data.model.RequestBodyControl
import com.openminis.app.provider.RequestExpressionValidator
import com.openminis.app.ui.components.SectionTextField
import com.openminis.app.ui.markdown.MarkdownText

// [Minix] Shared request-expression editor labels, validation, and normalization.

internal fun requestExpressionLines(text: String): List<String> =
    text.lines().map { it.trim() }.filter { it.isNotEmpty() }

internal fun hasInvalidRequestCustomization(
    headers: String,
    body: String,
    controls: List<RequestBodyControl>,
): Boolean =
    RequestExpressionValidator.validate(
        requestExpressionLines(headers),
        RequestExpressionValidator.Target.HEADER,
    ).isNotEmpty() ||
        RequestExpressionValidator.validate(
            requestExpressionLines(body),
            RequestExpressionValidator.Target.BODY,
        ).isNotEmpty() ||
        controls.any { control ->
            RequestExpressionValidator.validate(
                control.payloadExpressions,
                RequestExpressionValidator.Target.CONTROL,
            ).isNotEmpty() ||
                (
                    control.semanticKind ==
                        RequestBodyControl.SemanticKind.thinkingBudget &&
                        control.options.mapNotNull {
                            it.thinkingDefinitionId
                        }.let { definitionIds ->
                            definitionIds.size != control.options.size ||
                                definitionIds.toSet().size !=
                                definitionIds.size
                        }
                ) ||
                control.options.any { option ->
                    RequestExpressionValidator.validate(
                        option.payloadExpressions,
                        RequestExpressionValidator.Target.CONTROL,
                    ).isNotEmpty()
                }
        }

@Composable
internal fun ExpressionFieldLabel(
    text: String,
    onHelp: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Text(
            text = text,
            style = MaterialTheme.typography.labelLarge,
            modifier = Modifier.weight(1f),
        )
        IconButton(onClick = onHelp) {
            Icon(
                Icons.Default.Info,
                contentDescription = stringResource(R.string.request_expression_help),
            )
        }
    }
}

@Composable
internal fun ExpressionValidationIssues(
    issues: List<RequestExpressionValidator.Issue>,
) {
    issues.forEach { issue ->
        val detail = when (issue.kind) {
            RequestExpressionValidator.ErrorKind.MISSING_ASSIGNMENT ->
                stringResource(R.string.request_expression_error_assignment)
            RequestExpressionValidator.ErrorKind.EMPTY_VALUE ->
                stringResource(R.string.request_expression_error_empty)
            RequestExpressionValidator.ErrorKind.UNBALANCED_DELIMITER ->
                stringResource(R.string.request_expression_error_delimiter)
            RequestExpressionValidator.ErrorKind.INVALID_PATH ->
                stringResource(R.string.request_expression_error_path)
            RequestExpressionValidator.ErrorKind.UNKNOWN_FUNCTION ->
                stringResource(R.string.request_expression_error_function)
            RequestExpressionValidator.ErrorKind.INVALID_FUNCTION_ARGUMENTS ->
                stringResource(R.string.request_expression_error_function_arguments)
            RequestExpressionValidator.ErrorKind.EVALUATION_LIMIT ->
                stringResource(R.string.request_expression_error_evaluation_limit)
            RequestExpressionValidator.ErrorKind.UNKNOWN_TEMPLATE_REFERENCE ->
                stringResource(R.string.request_expression_error_template)
        }
        Text(
            text = stringResource(
                R.string.request_expression_error_line,
                issue.line,
                detail,
            ),
            color = MaterialTheme.colorScheme.error,
            fontSize = 12.sp,
        )
    }
}

@Composable
internal fun MinixRequestExpressionFields(
    headers: String,
    onHeadersChange: (String) -> Unit,
    body: String,
    onBodyChange: (String) -> Unit,
    headerTitle: String,
    bodyTitle: String,
    headerPlaceholder: String,
    bodyPlaceholder: String,
    onHelp: () -> Unit,
    fieldModifier: Modifier = Modifier,
    headerFooter: String? = null,
    bodyFooter: String? = null,
) {
    val headerIssues = RequestExpressionValidator.validate(
        requestExpressionLines(headers),
        RequestExpressionValidator.Target.HEADER,
    )
    val bodyIssues = RequestExpressionValidator.validate(
        requestExpressionLines(body),
        RequestExpressionValidator.Target.BODY,
    )

    Column {
        ExpressionFieldLabel(text = headerTitle, onHelp = onHelp)
        SectionTextField(
            value = headers,
            onValueChange = onHeadersChange,
            singleLine = false,
            maxLines = 3,
            placeholder = headerPlaceholder,
            isError = headerIssues.isNotEmpty(),
            textStyle = MaterialTheme.typography.bodySmall.copy(
                fontFamily = FontFamily.Monospace,
            ),
            fieldModifier = fieldModifier,
            inputNormalizer = ::normalizedExpressionEditorText,
            onFocusLost = {
                onHeadersChange(finalizedExpressionEditorText(it))
            },
        )
        ExpressionValidationIssues(headerIssues)
        headerFooter?.let {
            Text(
                text = it,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Spacer(Modifier.height(12.dp))
        ExpressionFieldLabel(text = bodyTitle, onHelp = onHelp)
        SectionTextField(
            value = body,
            onValueChange = onBodyChange,
            singleLine = false,
            maxLines = 3,
            placeholder = bodyPlaceholder,
            isError = bodyIssues.isNotEmpty(),
            textStyle = MaterialTheme.typography.bodySmall.copy(
                fontFamily = FontFamily.Monospace,
            ),
            fieldModifier = fieldModifier,
            inputNormalizer = ::normalizedExpressionEditorText,
            onFocusLost = {
                onBodyChange(finalizedExpressionEditorText(it))
            },
        )
        ExpressionValidationIssues(bodyIssues)
        bodyFooter?.let {
            Text(
                text = it,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

internal fun normalizedExpressionEditorText(raw: String): String {
    val lines = raw.replace("\r\n", "\n").split('\n')
    val result = mutableListOf<String>()
    lines.forEachIndexed { index, line ->
        if (line.isBlank()) {
            if (index == lines.lastIndex && result.lastOrNull()?.isNotEmpty() == true) {
                result += ""
            }
        } else {
            result += line
        }
    }
    return result.joinToString("\n")
}

internal fun finalizedExpressionEditorText(raw: String): String =
    normalizedExpressionEditorText(raw).trimEnd('\n', '\r')

@Composable
internal fun RequestExpressionHelpDialog(
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val configuration = LocalConfiguration.current
    val markdown = remember(configuration) {
        context.resources.openRawResource(
            R.raw.expression_capability_help,
        ).bufferedReader().use { it.readText() }
    }
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
            SettingsScaffold(
                title = stringResource(
                    R.string.request_expression_help_title,
                ),
                onBack = onDismiss,
                scrollable = false,
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .verticalScroll(rememberScrollState())
                        .padding(16.dp),
                ) {
                    MarkdownText(
                        markdown = markdown,
                    )
                }
            }
        }
    }
}
