package com.openminis.app.ui.components

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.automirrored.filled.FormatListBulleted
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Flag
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.filled.ToggleOn
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import com.openminis.app.data.model.RequestBodyControl
import com.openminis.app.ui.settings.SettingsScaffold

class RequestControlIconChoice(
    val id: String,
    private val imageProvider: () -> ImageVector,
) {
    constructor(id: String, image: ImageVector) : this(id, { image })

    val image: ImageVector
        get() = imageProvider()
}

object RequestControlIcons {
    const val THINKING = "lightbulb"
    const val TOGGLE = "switch.2"
    const val OPTION_GROUP = "list.bullet"

    val choices = (listOf(
        RequestControlIconChoice(THINKING, Icons.Default.Lightbulb),
        RequestControlIconChoice("brain", Icons.Default.Psychology),
        RequestControlIconChoice("brain.head.profile", Icons.Default.Psychology),
        RequestControlIconChoice(TOGGLE, Icons.Default.ToggleOn),
        RequestControlIconChoice(OPTION_GROUP, Icons.AutoMirrored.Filled.FormatListBulleted),
        RequestControlIconChoice("slider.horizontal.3", Icons.Default.Tune),
        RequestControlIconChoice("sparkles", Icons.Default.AutoAwesome),
        RequestControlIconChoice("bolt", Icons.Default.Bolt),
        RequestControlIconChoice("globe", Icons.Default.Public),
        RequestControlIconChoice("network", Icons.Default.Language),
        RequestControlIconChoice("magnifyingglass", Icons.Default.Search),
        RequestControlIconChoice("lock", Icons.Default.Lock),
        RequestControlIconChoice("key", Icons.Default.Key),
        RequestControlIconChoice("wrench.and.screwdriver", Icons.Default.Build),
        RequestControlIconChoice("gearshape", Icons.Default.Settings),
        RequestControlIconChoice("terminal", Icons.Default.Terminal),
        RequestControlIconChoice("memorychip", Icons.Default.Memory),
        RequestControlIconChoice("cloud", Icons.Default.Cloud),
        RequestControlIconChoice("star", Icons.Default.Star),
        RequestControlIconChoice("heart", Icons.Default.Favorite),
        RequestControlIconChoice("flag", Icons.Default.Flag),
        RequestControlIconChoice("bookmark", Icons.Default.Bookmark),
        RequestControlIconChoice("bell", Icons.Default.Notifications),
        RequestControlIconChoice("clock", Icons.Default.Schedule),
        RequestControlIconChoice("mic", Icons.Default.Mic),
        RequestControlIconChoice("camera", Icons.Default.CameraAlt),
        RequestControlIconChoice("person", Icons.Default.Person),
        RequestControlIconChoice("message", Icons.AutoMirrored.Filled.Chat),
        RequestControlIconChoice("link", Icons.Default.Link),
    ) + requestControlMaterialIconChoices).distinctBy { it.id }

    fun defaultName(control: RequestBodyControl): String = when {
        control.semanticKind == RequestBodyControl.SemanticKind.thinkingBudget -> THINKING
        control.kind == RequestBodyControl.Kind.toggle -> TOGGLE
        else -> OPTION_GROUP
    }

    fun resolve(control: RequestBodyControl): RequestControlIconChoice {
        val requested = control.iconName ?: defaultName(control)
        return choices.firstOrNull { it.id == requested }
            ?: choices.first { it.id == defaultName(control) }
    }
}

@Composable
fun RequestControlIconPickerScreen(
    control: RequestBodyControl,
    onSelect: (String?) -> Unit,
    onBack: () -> Unit,
) {
    BackHandler(onBack = onBack)
    var search by remember(control.id) {
        mutableStateOf("")
    }
    val visible = remember(search) {
        RequestControlIcons.choices
            .distinctBy { it.id }
            .filter { search.isBlank() || it.id.contains(search, ignoreCase = true) }
    }
    val resolved = RequestControlIcons.resolve(control)

    SettingsScaffold(
        title = stringResource(R.string.request_control_icon),
        onBack = onBack,
        scrollable = false,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 12.dp),
            verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(48.dp)
                    .background(
                        MaterialTheme.colorScheme.primaryContainer,
                        RoundedCornerShape(12.dp),
                    ),
                contentAlignment =
                    androidx.compose.ui.Alignment.Center,
            ) {
                Icon(
                    imageVector = resolved.image,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme
                        .onPrimaryContainer,
                    modifier = Modifier.size(24.dp),
                )
            }
            Spacer(Modifier.width(14.dp))
            Text(
                text = control.iconName
                    ?: stringResource(
                        R.string.request_control_icon_default,
                    ),
                style = MaterialTheme.typography.bodyLarge,
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.Medium,
            )
        }
        OutlinedTextField(
            value = search,
            onValueChange = { search = it },
            placeholder = {
                Text(
                    stringResource(
                        R.string.request_control_icon_search,
                    ),
                )
            },
            singleLine = true,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp),
        )
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f),
        ) {
            if (visible.isEmpty()) {
                Text(
                    text = stringResource(
                        R.string.request_control_icon_no_results,
                    ),
                    color = MaterialTheme.colorScheme
                        .onSurfaceVariant,
                    modifier = Modifier.align(
                        androidx.compose.ui.Alignment.Center,
                    ),
                )
            } else {
                LazyVerticalGrid(
                    columns = GridCells.Adaptive(54.dp),
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(16.dp),
                    horizontalArrangement =
                        Arrangement.spacedBy(6.dp),
                    verticalArrangement =
                        Arrangement.spacedBy(6.dp),
                ) {
                    items(visible, key = { it.id }) { choice ->
                        val selected =
                            control.iconName == choice.id ||
                                (
                                    control.iconName == null &&
                                        RequestControlIcons
                                            .defaultName(control) ==
                                        choice.id
                                    )
                        IconButton(
                            onClick = { onSelect(choice.id) },
                            modifier = Modifier.background(
                                if (selected) {
                                    MaterialTheme.colorScheme
                                        .primaryContainer
                                } else {
                                    MaterialTheme.colorScheme
                                        .surfaceVariant
                                },
                                RoundedCornerShape(12.dp),
                            ),
                        ) {
                            Icon(
                                choice.image,
                                contentDescription = choice.id,
                                tint = if (selected) {
                                    MaterialTheme.colorScheme
                                        .onPrimaryContainer
                                } else {
                                    MaterialTheme.colorScheme
                                        .onSurfaceVariant
                                },
                            )
                        }
                    }
                }
            }
        }
        TextButton(
            onClick = { onSelect(null) },
            enabled = control.iconName != null,
            modifier = Modifier.padding(
                horizontal = 16.dp,
                vertical = 8.dp,
            ),
        ) {
                Text(stringResource(R.string.request_control_icon_default))
        }
    }
}
