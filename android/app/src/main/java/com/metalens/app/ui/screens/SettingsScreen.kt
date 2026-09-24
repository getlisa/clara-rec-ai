package com.metalens.app.ui.screens

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.background
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material.icons.filled.BluetoothDisabled
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.CloudUpload
import androidx.compose.material.icons.filled.Coffee
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Feedback
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.ButtonDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.foundation.verticalScroll
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.metalens.app.BuildConfig
import com.metalens.app.R
import com.metalens.app.ui.components.FeatureActionCard
import com.metalens.app.wearables.WearablesViewModel
import androidx.lifecycle.viewmodel.compose.viewModel
import com.meta.wearable.dat.camera.types.VideoQuality
import com.metalens.app.conversation.OpenAIRealtimeClient
import com.metalens.app.settings.AppSettings
import com.metalens.app.upload.Author
import com.metalens.app.upload.S3Config
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicBoolean
import java.util.Locale
import java.util.TimeZone
import kotlin.coroutines.resume

private enum class AiInstructionsModule {
    Vision,
    Voice,
}

@Composable
fun SettingsScreen(
    modifier: Modifier = Modifier,
) {
    val activity = LocalContext.current as ComponentActivity
    val wearablesViewModel: WearablesViewModel = viewModel(activity)
    val uiState by wearablesViewModel.uiState.collectAsStateWithLifecycle()

    val context = LocalContext.current
    var openAiApiKey by rememberSaveable { mutableStateOf(AppSettings.getOpenAiApiKey(context)) }
    var apiKeyVisible by rememberSaveable { mutableStateOf(false) }

    val modelOptions =
        rememberSaveable {
            listOf(
                "gpt-4o-realtime-preview",
                "gpt-4o-mini-realtime-preview",
            )
        }

    var openAiModel by rememberSaveable {
        val saved = AppSettings.getOpenAiModel(context).trim()
        val initial = saved.takeIf { it in modelOptions } ?: OpenAIRealtimeClient.DEFAULT_MODEL
        mutableStateOf(initial)
    }

    var authorName by rememberSaveable { mutableStateOf(AppSettings.getAuthorName(context)) }
    val authorId = remember { AppSettings.getAuthorId(context) }
    var showEditAuthorNameDialog by rememberSaveable { mutableStateOf(false) }
    var authorNameDraft by rememberSaveable { mutableStateOf(authorName) }

    var showEditApiKeyDialog by rememberSaveable { mutableStateOf(false) }
    var showSelectModelDialog by rememberSaveable { mutableStateOf(false) }
    var showPersonalizeAiDialog by rememberSaveable { mutableStateOf(false) }
    var apiKeyDraft by rememberSaveable { mutableStateOf(openAiApiKey) }
    var modelDraft by rememberSaveable { mutableStateOf(openAiModel) }

    var selectedAiModule by rememberSaveable { mutableStateOf(AiInstructionsModule.Vision) }
    var visionInstructionsDraft by rememberSaveable { mutableStateOf("") }
    var voiceInstructionsDraft by rememberSaveable { mutableStateOf("") }

    val cameraQualityOptions =
        rememberSaveable {
            listOf(
                VideoQuality.LOW,
                VideoQuality.MEDIUM,
                VideoQuality.HIGH,
            )
        }
    var cameraQuality by rememberSaveable {
        mutableStateOf(AppSettings.getCameraVideoQuality(context).name)
    }
    var showSelectCameraQualityDialog by rememberSaveable { mutableStateOf(false) }
    var cameraQualityDraft by rememberSaveable { mutableStateOf(cameraQuality) }

    val scope = rememberCoroutineScope()
    var isCheckingConnection by rememberSaveable { mutableStateOf(false) }
    var lastConnectionCheckResult by rememberSaveable { mutableStateOf<String?>(null) }
    var showConnectedDevicesDialog by rememberSaveable { mutableStateOf(false) }

    var isCheckingForUpdate by rememberSaveable { mutableStateOf(false) }
    var updateDialogMessage by rememberSaveable { mutableStateOf<String?>(null) }
    var updateDialogReleaseUrl by rememberSaveable { mutableStateOf<String?>(null) }

    var showFeedbackDialog by rememberSaveable { mutableStateOf(false) }
    var feedbackDraft by rememberSaveable { mutableStateOf("") }

    LaunchedEffect(Unit) {
        wearablesViewModel.startMonitoring()
    }

    LaunchedEffect(showEditApiKeyDialog) {
        if (showEditApiKeyDialog) {
            apiKeyDraft = openAiApiKey
            apiKeyVisible = false
        }
    }

    LaunchedEffect(showSelectModelDialog) {
        if (showSelectModelDialog) {
            modelDraft = openAiModel
        }
    }

    LaunchedEffect(showPersonalizeAiDialog) {
        if (showPersonalizeAiDialog) {
            visionInstructionsDraft = AppSettings.getPictureAnalysisSystemInstructions(context)
            voiceInstructionsDraft = AppSettings.getConversationSystemInstructions(context)
        }
    }

    LaunchedEffect(showSelectCameraQualityDialog) {
        if (showSelectCameraQualityDialog) {
            cameraQualityDraft = cameraQuality
        }
    }

    if (showEditAuthorNameDialog) {
        AlertDialog(
            onDismissRequest = { showEditAuthorNameDialog = false },
            containerColor = MaterialTheme.colorScheme.surface,
            titleContentColor = MaterialTheme.colorScheme.onSurface,
            textContentColor = MaterialTheme.colorScheme.onSurface,
            title = { Text(stringResource(R.string.settings_author_name)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        value = authorNameDraft,
                        onValueChange = { authorNameDraft = it },
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true,
                        placeholder = { Text(stringResource(R.string.settings_author_name_hint)) },
                    )
                    Text(
                        text = stringResource(R.string.settings_author_name_description),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    // Shows how the name actually lands in the bucket, including the id that
                    // keeps two people with the same name apart.
                    SettingsKeyValueRow(
                        key = stringResource(R.string.settings_author_upload_prefix),
                        value = Author(id = authorId, name = authorNameDraft).storagePrefix,
                    )
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        val normalized = authorNameDraft.trim()
                        AppSettings.setAuthorName(context, normalized)
                        authorName = normalized
                        authorNameDraft = normalized
                        showEditAuthorNameDialog = false
                    },
                ) {
                    Text(stringResource(R.string.common_save))
                }
            },
            dismissButton = {
                TextButton(
                    onClick = {
                        authorNameDraft = authorName
                        showEditAuthorNameDialog = false
                    },
                ) {
                    Text(stringResource(R.string.common_cancel))
                }
            },
        )
    }

    if (showEditApiKeyDialog) {
        AlertDialog(
            onDismissRequest = { showEditApiKeyDialog = false },
            containerColor = MaterialTheme.colorScheme.surface,
            titleContentColor = MaterialTheme.colorScheme.onSurface,
            textContentColor = MaterialTheme.colorScheme.onSurface,
            title = { Text(stringResource(R.string.settings_openai_api_key)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        value = apiKeyDraft,
                        onValueChange = { apiKeyDraft = it },
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true,
                        visualTransformation =
                            if (apiKeyVisible) {
                                VisualTransformation.None
                            } else {
                                PasswordVisualTransformation()
                            },
                        trailingIcon = {
                            IconButton(onClick = { apiKeyVisible = !apiKeyVisible }) {
                                Icon(
                                    imageVector = if (apiKeyVisible) Icons.Filled.VisibilityOff else Icons.Filled.Visibility,
                                    contentDescription = null,
                                )
                            }
                        },
                    )
                    TextButton(
                        onClick = {
                            val intent =
                                Intent(
                                    Intent.ACTION_VIEW,
                                    Uri.parse("https://help.openai.com/en/articles/4936850-where-do-i-find-my-openai-api-key"),
                                )
                            context.startActivity(intent)
                        },
                        contentPadding = PaddingValues(0.dp),
                    ) {
                        Text(stringResource(R.string.settings_openai_api_key_help))
                    }
                }
            },
            confirmButton = {
                TextButton(
                    colors =
                        ButtonDefaults.textButtonColors(
                            contentColor = MaterialTheme.colorScheme.primary,
                        ),
                    onClick = {
                        val normalized = apiKeyDraft.trim()
                        AppSettings.setOpenAiApiKey(context, normalized)
                        openAiApiKey = normalized
                        showEditApiKeyDialog = false
                    },
                ) {
                    Text(stringResource(R.string.common_save))
                }
            },
            dismissButton = {
                TextButton(
                    colors =
                        ButtonDefaults.textButtonColors(
                            contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
                        ),
                    onClick = { showEditApiKeyDialog = false },
                ) {
                    Text(stringResource(R.string.common_cancel))
                }
            },
        )
    }

    if (showSelectModelDialog) {
        AlertDialog(
            onDismissRequest = { showSelectModelDialog = false },
            containerColor = MaterialTheme.colorScheme.surface,
            titleContentColor = MaterialTheme.colorScheme.onSurface,
            textContentColor = MaterialTheme.colorScheme.onSurface,
            title = { Text(stringResource(R.string.settings_openai_model)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    modelOptions.forEach { model ->
                        val isSelected = model == modelDraft
                        val subtitleRes = openAiModelDescriptionRes(model)
                        FeatureActionCard(
                            title = openAiModelDisplayName(model),
                            // Don't show "Current" in popups; selection is indicated by the check icon.
                            subtitle = subtitleRes?.let { stringResource(it) },
                            icon = if (isSelected) Icons.Filled.CheckCircle else Icons.Filled.Psychology,
                            onClick = { modelDraft = model },
                            enabled = true,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            },
            confirmButton = {
                TextButton(
                    colors =
                        ButtonDefaults.textButtonColors(
                            contentColor = MaterialTheme.colorScheme.primary,
                        ),
                    onClick = {
                        val normalized = modelDraft.trim()
                        AppSettings.setOpenAiModel(context, normalized)
                        openAiModel = normalized
                        showSelectModelDialog = false
                    },
                ) {
                    Text(stringResource(R.string.common_save))
                }
            },
            dismissButton = {
                TextButton(
                    colors =
                        ButtonDefaults.textButtonColors(
                            contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
                        ),
                    onClick = { showSelectModelDialog = false },
                ) {
                    Text(stringResource(R.string.common_cancel))
                }
            },
        )
    }

    if (showPersonalizeAiDialog) {
        val defaultVision = context.getString(R.string.picture_analysis_system_instructions).trim()
        val defaultVoice = context.getString(R.string.conversation_system_instructions).trim()

        val isVisionSelected = selectedAiModule == AiInstructionsModule.Vision
        val editorValue = if (isVisionSelected) visionInstructionsDraft else voiceInstructionsDraft

        AlertDialog(
            onDismissRequest = { showPersonalizeAiDialog = false },
            containerColor = MaterialTheme.colorScheme.surface,
            titleContentColor = MaterialTheme.colorScheme.onSurface,
            textContentColor = MaterialTheme.colorScheme.onSurface,
            title = { Text(stringResource(R.string.settings_ai_personalize_title)) },
            text = {
                var moduleMenuExpanded by rememberSaveable { mutableStateOf(false) }
                val selectedModuleLabel =
                    if (selectedAiModule == AiInstructionsModule.Vision) {
                        stringResource(R.string.settings_ai_personalize_vision)
                    } else {
                        stringResource(R.string.settings_ai_personalize_voice)
                    }

                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(
                        text = stringResource(R.string.settings_ai_personalize_module_label),
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                    )

                    Box(modifier = Modifier.fillMaxWidth()) {
                        OutlinedButton(
                            onClick = { moduleMenuExpanded = true },
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text(
                                text = selectedModuleLabel,
                                modifier = Modifier.weight(1f),
                            )
                            Icon(
                                imageVector = Icons.Filled.ArrowDropDown,
                                contentDescription = null,
                            )
                        }

                        DropdownMenu(
                            expanded = moduleMenuExpanded,
                            onDismissRequest = { moduleMenuExpanded = false },
                            modifier =
                                Modifier
                                    .widthIn(min = 220.dp)
                                    .background(
                                        color = MaterialTheme.colorScheme.surface,
                                        shape = MaterialTheme.shapes.medium,
                                    ),
                        ) {
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.settings_ai_personalize_vision)) },
                                onClick = {
                                    selectedAiModule = AiInstructionsModule.Vision
                                    moduleMenuExpanded = false
                                },
                            )
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.settings_ai_personalize_voice)) },
                                onClick = {
                                    selectedAiModule = AiInstructionsModule.Voice
                                    moduleMenuExpanded = false
                                },
                            )
                        }
                    }

                    OutlinedTextField(
                        value = editorValue,
                        onValueChange = { new ->
                            if (selectedAiModule == AiInstructionsModule.Vision) {
                                visionInstructionsDraft = new
                            } else {
                                voiceInstructionsDraft = new
                            }
                        },
                        label = { Text(stringResource(R.string.settings_ai_personalize_instructions_label)) },
                        placeholder = { Text(stringResource(R.string.settings_ai_personalize_instructions_hint)) },
                        modifier = Modifier.fillMaxWidth(),
                        minLines = 6,
                        maxLines = 12,
                        singleLine = false,
                    )
                }
            },
            confirmButton = {
                TextButton(
                    colors =
                        ButtonDefaults.textButtonColors(
                            contentColor = MaterialTheme.colorScheme.primary,
                        ),
                    onClick = {
                        val normalizedVision = visionInstructionsDraft.trim()
                        val normalizedVoice = voiceInstructionsDraft.trim()

                        if (normalizedVision.isBlank() || normalizedVision == defaultVision) {
                            AppSettings.resetPictureAnalysisSystemInstructions(context)
                        } else {
                            AppSettings.setPictureAnalysisSystemInstructions(context, normalizedVision)
                        }

                        if (normalizedVoice.isBlank() || normalizedVoice == defaultVoice) {
                            AppSettings.resetConversationSystemInstructions(context)
                        } else {
                            AppSettings.setConversationSystemInstructions(context, normalizedVoice)
                        }

                        showPersonalizeAiDialog = false
                    },
                ) {
                    Text(stringResource(R.string.common_save))
                }
            },
            dismissButton = {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton(
                        colors =
                            ButtonDefaults.textButtonColors(
                                contentColor = MaterialTheme.colorScheme.error,
                            ),
                        onClick = {
                            if (selectedAiModule == AiInstructionsModule.Vision) {
                                visionInstructionsDraft = defaultVision
                            } else {
                                voiceInstructionsDraft = defaultVoice
                            }
                        },
                    ) {
                        Text(stringResource(R.string.settings_ai_reset_factory))
                    }

                    TextButton(
                        colors =
                            ButtonDefaults.textButtonColors(
                                contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
                            ),
                        onClick = { showPersonalizeAiDialog = false },
                    ) {
                        Text(stringResource(R.string.common_close))
                    }
                }
            },
        )
    }

    if (showSelectCameraQualityDialog) {
        AlertDialog(
            onDismissRequest = { showSelectCameraQualityDialog = false },
            containerColor = MaterialTheme.colorScheme.surface,
            titleContentColor = MaterialTheme.colorScheme.onSurface,
            textContentColor = MaterialTheme.colorScheme.onSurface,
            title = { Text(stringResource(R.string.settings_camera_quality_title)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    cameraQualityOptions.forEach { quality ->
                        val desc =
                            when (quality) {
                                VideoQuality.LOW -> stringResource(R.string.settings_camera_quality_low_desc)
                                VideoQuality.MEDIUM -> stringResource(R.string.settings_camera_quality_medium_desc)
                                VideoQuality.HIGH -> stringResource(R.string.settings_camera_quality_high_desc)
                            }

                        val isSelected = quality.name == cameraQualityDraft

                        FeatureActionCard(
                            title = quality.name,
                            // Don't show "Current" in popups; selection is indicated by the check icon.
                            subtitle = desc,
                            icon = if (isSelected) Icons.Filled.CheckCircle else Icons.Filled.Videocam,
                            onClick = { cameraQualityDraft = quality.name },
                            enabled = true,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            },
            confirmButton = {
                TextButton(
                    colors =
                        ButtonDefaults.textButtonColors(
                            contentColor = MaterialTheme.colorScheme.primary,
                        ),
                    onClick = {
                        val selected =
                            cameraQualityOptions.firstOrNull { it.name == cameraQualityDraft }
                                ?: VideoQuality.MEDIUM
                        AppSettings.setCameraVideoQuality(context, selected)
                        cameraQuality = selected.name
                        showSelectCameraQualityDialog = false
                    },
                ) {
                    Text(stringResource(R.string.common_save))
                }
            },
            dismissButton = {
                TextButton(
                    colors =
                        ButtonDefaults.textButtonColors(
                            contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
                        ),
                    onClick = { showSelectCameraQualityDialog = false },
                ) {
                    Text(stringResource(R.string.common_cancel))
                }
            },
        )
    }

    if (showConnectedDevicesDialog) {
        val connectedDevices = uiState.connectedDevices
        AlertDialog(
            onDismissRequest = { showConnectedDevicesDialog = false },
            containerColor = MaterialTheme.colorScheme.surface,
            titleContentColor = MaterialTheme.colorScheme.onSurface,
            textContentColor = MaterialTheme.colorScheme.onSurface,
            title = { Text(stringResource(R.string.settings_connected_devices)) },
            text = {
                if (connectedDevices.isEmpty()) {
                    Text(text = stringResource(R.string.settings_no_connected_devices))
                } else {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        connectedDevices.forEach { deviceId ->
                            val id = deviceId.toString()
                            val name = uiState.deviceDisplayNames[id] ?: stringResource(R.string.settings_unknown_device)
                            Text(
                                text = name,
                                style = MaterialTheme.typography.bodyMedium,
                            )
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(
                    colors =
                        ButtonDefaults.textButtonColors(
                            contentColor = MaterialTheme.colorScheme.primary,
                        ),
                    onClick = { showConnectedDevicesDialog = false },
                ) {
                    Text(stringResource(R.string.common_close))
                }
            },
        )
    }

    if (updateDialogMessage != null) {
        val releaseUrl = updateDialogReleaseUrl
        AlertDialog(
            onDismissRequest = {
                updateDialogMessage = null
                updateDialogReleaseUrl = null
            },
            containerColor = MaterialTheme.colorScheme.surface,
            titleContentColor = MaterialTheme.colorScheme.onSurface,
            textContentColor = MaterialTheme.colorScheme.onSurface,
            title = { Text(stringResource(R.string.settings_update_check_title)) },
            text = { Text(text = updateDialogMessage ?: "") },
            confirmButton = {
                if (releaseUrl.isNullOrBlank()) {
                    TextButton(
                        colors =
                            ButtonDefaults.textButtonColors(
                                contentColor = MaterialTheme.colorScheme.primary,
                            ),
                        onClick = {
                            updateDialogMessage = null
                            updateDialogReleaseUrl = null
                        },
                    ) {
                        Text(stringResource(R.string.common_close))
                    }
                } else {
                    TextButton(
                        colors =
                            ButtonDefaults.textButtonColors(
                                contentColor = MaterialTheme.colorScheme.primary,
                            ),
                        onClick = {
                            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(releaseUrl))
                            context.startActivity(intent)
                        },
                    ) {
                        Text(stringResource(R.string.settings_update_open_release))
                    }
                }
            },
            dismissButton =
                if (releaseUrl.isNullOrBlank()) {
                    null
                } else {
                    {
                        TextButton(
                            colors =
                                ButtonDefaults.textButtonColors(
                                    contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
                                ),
                            onClick = {
                                updateDialogMessage = null
                                updateDialogReleaseUrl = null
                            },
                        ) {
                            Text(stringResource(R.string.common_close))
                        }
                    }
                },
        )
    }

    if (showFeedbackDialog) {
        val openingFormText = stringResource(R.string.settings_feedback_opening_form)
        val notConfiguredText = stringResource(R.string.settings_feedback_form_not_configured)
        AlertDialog(
            onDismissRequest = { showFeedbackDialog = false },
            containerColor = MaterialTheme.colorScheme.surface,
            titleContentColor = MaterialTheme.colorScheme.onSurface,
            textContentColor = MaterialTheme.colorScheme.onSurface,
            title = { Text(stringResource(R.string.settings_feedback_dialog_title)) },
            text = {
                OutlinedTextField(
                    value = feedbackDraft,
                    onValueChange = { feedbackDraft = it },
                    modifier = Modifier.fillMaxWidth(),
                    placeholder = { Text(stringResource(R.string.settings_feedback_hint)) },
                    minLines = 6,
                    maxLines = 12,
                    singleLine = false,
                )
            },
            confirmButton = {
                val formBaseUrl = stringResource(R.string.settings_feedback_form_base_url).trim()
                val entryFeedback = stringResource(R.string.settings_feedback_form_entry_feedback).trim()
                val entryAppVersion = stringResource(R.string.settings_feedback_form_entry_app_version).trim()
                val entryAndroidVersion = stringResource(R.string.settings_feedback_form_entry_android_version).trim()
                val entryDevice = stringResource(R.string.settings_feedback_form_entry_device).trim()
                val entryLocaleTz = stringResource(R.string.settings_feedback_form_entry_locale_timezone).trim()

                val canSend = feedbackDraft.trim().isNotBlank()
                TextButton(
                    enabled = canSend,
                    colors =
                        ButtonDefaults.textButtonColors(
                            contentColor = MaterialTheme.colorScheme.primary,
                        ),
                    onClick = {
                        val feedback = feedbackDraft.trim()
                        if (feedback.isBlank()) return@TextButton

                        if (formBaseUrl.isBlank() || entryFeedback.isBlank()) {
                            Toast.makeText(context, notConfiguredText, Toast.LENGTH_SHORT).show()
                            return@TextButton
                        }

                        val appVersion = "${BuildConfig.VERSION_NAME} (build ${BuildConfig.VERSION_CODE})"
                        val androidVersion = "Android ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT})"
                        val device = "${Build.MANUFACTURER} ${Build.MODEL}"
                        val localeTimezone = "${Locale.getDefault().toLanguageTag()} / ${TimeZone.getDefault().id}"

                        val uriBuilder = Uri.parse(formBaseUrl).buildUpon()
                        uriBuilder.appendQueryParameter(entryFeedback, feedback)
                        if (entryAppVersion.isNotBlank()) uriBuilder.appendQueryParameter(entryAppVersion, appVersion)
                        if (entryAndroidVersion.isNotBlank()) uriBuilder.appendQueryParameter(entryAndroidVersion, androidVersion)
                        if (entryDevice.isNotBlank()) uriBuilder.appendQueryParameter(entryDevice, device)
                        if (entryLocaleTz.isNotBlank()) uriBuilder.appendQueryParameter(entryLocaleTz, localeTimezone)

                        val intent = Intent(Intent.ACTION_VIEW, uriBuilder.build())
                        context.startActivity(intent)

                        // We're opening a prefilled form in the browser; user still needs to submit it.
                        feedbackDraft = ""
                        showFeedbackDialog = false
                        Toast.makeText(context, openingFormText, Toast.LENGTH_SHORT).show()
                    },
                ) {
                    Text(stringResource(R.string.settings_feedback_send))
                }
            },
            dismissButton = {
                TextButton(
                    colors =
                        ButtonDefaults.textButtonColors(
                            contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
                        ),
                    onClick = { showFeedbackDialog = false },
                ) {
                    Text(stringResource(R.string.common_cancel))
                }
            },
        )
    }

    Column(
        modifier =
            modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(PaddingValues(horizontal = 20.dp, vertical = 24.dp)),
        verticalArrangement = Arrangement.Top,
        horizontalAlignment = Alignment.Start,
    ) {
        Text(
            text = stringResource(R.string.tab_settings),
            style = MaterialTheme.typography.headlineLarge,
        )

        Spacer(modifier = Modifier.height(20.dp))

        SettingsSectionTitle(text = stringResource(R.string.settings_group_hardware))

        uiState.recentError?.let { error ->
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = error,
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodySmall,
            )
        }

        Spacer(modifier = Modifier.height(12.dp))

        val glassesStatusSubtitle =
            if (uiState.hasActiveDevice) {
                stringResource(R.string.glasses_status_connected)
            } else {
                stringResource(R.string.glasses_status_not_connected)
            }

        // We only show "Disconnect" when the glasses are actually connected.
        val canDisconnectGlasses = uiState.isRegistered && uiState.hasActiveDevice
        FeatureActionCard(
            title =
                if (canDisconnectGlasses) {
                    stringResource(R.string.disconnect_my_glasses)
                } else {
                    stringResource(R.string.connect_my_glasses)
                },
            subtitle = glassesStatusSubtitle,
            icon = if (canDisconnectGlasses) Icons.Filled.BluetoothDisabled else Icons.Filled.Bluetooth,
            onClick = {
                if (canDisconnectGlasses) {
                    wearablesViewModel.startUnregistration()
                } else {
                    wearablesViewModel.startRegistration()
                }
            },
            modifier = Modifier.fillMaxWidth(),
        )

        Spacer(modifier = Modifier.height(12.dp))

        val connectedDevices = uiState.connectedDevices
        val connectedDevicesSubtitle =
            if (connectedDevices.isEmpty()) {
                stringResource(R.string.settings_no_connected_devices)
            } else {
                stringResource(R.string.settings_connected_devices_count, connectedDevices.size)
            }

        FeatureActionCard(
            title = stringResource(R.string.settings_connected_devices),
            subtitle = connectedDevicesSubtitle,
            icon = Icons.Filled.Devices,
            onClick = { showConnectedDevicesDialog = true },
            enabled = connectedDevices.isNotEmpty(),
            modifier = Modifier.fillMaxWidth(),
        )

        Spacer(modifier = Modifier.height(12.dp))

        val cameraQualityValue = runCatching { VideoQuality.valueOf(cameraQuality) }.getOrDefault(VideoQuality.MEDIUM)
        val cameraQualityDesc =
            when (cameraQualityValue) {
                VideoQuality.LOW -> stringResource(R.string.settings_camera_quality_low_desc)
                VideoQuality.MEDIUM -> stringResource(R.string.settings_camera_quality_medium_desc)
                VideoQuality.HIGH -> stringResource(R.string.settings_camera_quality_high_desc)
            }
        FeatureActionCard(
            title = stringResource(R.string.settings_camera_quality_title),
            subtitle = "${cameraQualityValue.name} — $cameraQualityDesc",
            icon = Icons.Filled.Videocam,
            onClick = { showSelectCameraQualityDialog = true },
            modifier = Modifier.fillMaxWidth(),
        )

        Spacer(modifier = Modifier.height(24.dp))

        SettingsSectionTitle(text = stringResource(R.string.settings_group_ai))

        Spacer(modifier = Modifier.height(12.dp))

        val apiKeySubtitle =
            if (openAiApiKey.isBlank()) {
                stringResource(R.string.settings_not_set)
            } else {
                "***"
            }

        FeatureActionCard(
            title = stringResource(R.string.settings_openai_api_key),
            subtitle = apiKeySubtitle,
            icon = Icons.Filled.Key,
            onClick = { showEditApiKeyDialog = true },
            modifier = Modifier.fillMaxWidth(),
        )

        Spacer(modifier = Modifier.height(12.dp))

        FeatureActionCard(
            title = stringResource(R.string.settings_openai_model),
            subtitle = openAiModelDisplayName(openAiModel),
            icon = Icons.Filled.Psychology,
            onClick = { showSelectModelDialog = true },
            modifier = Modifier.fillMaxWidth(),
        )

        Spacer(modifier = Modifier.height(12.dp))

        FeatureActionCard(
            title = stringResource(R.string.settings_ai_personalize),
            subtitle = stringResource(R.string.settings_ai_personalize_subtitle),
            icon = Icons.Filled.Tune,
            onClick = { showPersonalizeAiDialog = true },
            modifier = Modifier.fillMaxWidth(),
        )

        Spacer(modifier = Modifier.height(12.dp))

        val checkSubtitle =
            when {
                isCheckingConnection -> stringResource(R.string.settings_checking_connection)
                lastConnectionCheckResult != null -> lastConnectionCheckResult
                else -> stringResource(R.string.settings_tap_to_test)
            }

        val connectionOkText = stringResource(R.string.settings_connection_ok)
        FeatureActionCard(
            title = stringResource(R.string.settings_check_connection),
            subtitle = checkSubtitle,
            icon = if (lastConnectionCheckResult == connectionOkText) {
                Icons.Filled.CheckCircle
            } else {
                Icons.Filled.Wifi
            },
            enabled = !isCheckingConnection,
            onClick = {
                if (isCheckingConnection) return@FeatureActionCard
                isCheckingConnection = true
                lastConnectionCheckResult = null
                scope.launch {
                    val connectionFailedPrefix = context.getString(R.string.settings_connection_failed)
                    val connectionOk = context.getString(R.string.settings_connection_ok)
                    // Use the persisted settings, same source as conversation start.
                    val apiKey = AppSettings.getOpenAiApiKey(context).trim()
                    val model = AppSettings.getOpenAiModel(context).trim()
                    val result =
                        if (apiKey.isBlank()) {
                            Result.failure(IllegalStateException("Missing API key"))
                        } else {
                            checkOpenAiRealtimeHandshake(
                                apiKey = apiKey,
                                model = model,
                            )
                        }

                    lastConnectionCheckResult =
                        result.fold(
                            onSuccess = { connectionOk },
                            onFailure = { t ->
                                // Keep UX simple; don't surface provider error details here.
                                connectionFailedPrefix
                            },
                        )
                    isCheckingConnection = false
                }
            },
            modifier = Modifier.fillMaxWidth(),
        )

        Spacer(modifier = Modifier.height(24.dp))

        SettingsSectionTitle(text = stringResource(R.string.settings_group_cloud))

        Spacer(modifier = Modifier.height(12.dp))

        FeatureActionCard(
            title = stringResource(R.string.settings_author_name),
            subtitle =
                if (authorName.isBlank()) {
                    stringResource(R.string.settings_author_name_unset)
                } else {
                    Author(id = authorId, name = authorName).storagePrefix
                },
            icon = Icons.Filled.Person,
            onClick = {
                authorNameDraft = authorName
                showEditAuthorNameDialog = true
            },
            modifier = Modifier.fillMaxWidth(),
        )

        Spacer(modifier = Modifier.height(12.dp))

        val s3Config = remember { S3Config.fromBuildConfig() }
        FeatureActionCard(
            title = stringResource(R.string.settings_s3_bucket),
            subtitle =
                if (s3Config.isConfigured) {
                    "${s3Config.bucket} (${s3Config.region})"
                } else {
                    stringResource(R.string.settings_s3_not_configured)
                },
            icon = Icons.Filled.CloudUpload,
            // Credentials are build-time only, so there is nothing to edit here.
            enabled = false,
            onClick = {},
            modifier = Modifier.fillMaxWidth(),
        )

        Spacer(modifier = Modifier.height(24.dp))

        SettingsSectionTitle(text = stringResource(R.string.settings_group_about))

        Spacer(modifier = Modifier.height(12.dp))

        FeatureActionCard(
            title = stringResource(R.string.settings_version),
            subtitle = BuildConfig.VERSION_NAME,
            icon = Icons.Filled.Info,
            onClick = {
                if (isCheckingForUpdate) return@FeatureActionCard
                isCheckingForUpdate = true
                scope.launch {
                    val installed = BuildConfig.VERSION_NAME
                    val failedText = context.getString(R.string.settings_update_check_failed)
                    val result = fetchLatestReleaseInfo()
                    val (message, url) =
                        result.fold(
                            onSuccess = { latest ->
                                val installedNormalized = normalizeVersionForComparison(installed)
                                val latestNormalized = normalizeVersionForComparison(latest.tagName)

                                if (latestNormalized.isBlank() || installedNormalized.isBlank()) {
                                    failedText to null
                                } else if (latestNormalized == installedNormalized) {
                                    context.getString(
                                        R.string.settings_update_up_to_date,
                                        installed,
                                    ) to null
                                } else {
                                    context.getString(
                                        R.string.settings_update_available,
                                        latest.tagName,
                                        installed,
                                    ) to (latest.htmlUrl ?: "https://github.com/przemek-nowicki/meta-lens-ai/releases")
                                }
                            },
                            onFailure = {
                                failedText to null
                            },
                        )

                    updateDialogMessage = message
                    updateDialogReleaseUrl = url
                    isCheckingForUpdate = false
                }
            },
            modifier = Modifier.fillMaxWidth(),
        )

        Spacer(modifier = Modifier.height(12.dp))

        FeatureActionCard(
            title = stringResource(R.string.settings_feedback),
            subtitle = stringResource(R.string.settings_feedback_subtitle),
            icon = Icons.Filled.Feedback,
            onClick = { showFeedbackDialog = true },
            modifier = Modifier.fillMaxWidth(),
        )

        Spacer(modifier = Modifier.height(12.dp))

        FeatureActionCard(
            title = stringResource(R.string.settings_support_development),
            subtitle = stringResource(R.string.settings_support_development_subtitle),
            icon = Icons.Filled.Coffee,
            onClick = {
                val intent =
                    Intent(
                        Intent.ACTION_VIEW,
                        Uri.parse(context.getString(R.string.settings_support_development_url)),
                    )
                context.startActivity(intent)
            },
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun SettingsSectionTitle(
    text: String,
    modifier: Modifier = Modifier,
) {
    Text(
        text = text,
        style = MaterialTheme.typography.titleMedium,
        color = MaterialTheme.colorScheme.onSurface,
        modifier = modifier,
    )
}

@Composable
private fun SettingsKeyValueRow(
    key: String,
    value: String,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(
            text = key,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            text = value,
            style = MaterialTheme.typography.bodyMedium,
        )
    }
}

private suspend fun checkOpenAiRealtimeHandshake(
    apiKey: String,
    model: String,
): Result<Unit> {
    return try {
        withTimeout(7_000) {
            suspendCancellableCoroutine { cont ->
                val resumed = AtomicBoolean(false)
                val client = OkHttpClient()
                val request =
                    Request.Builder()
                        .url("wss://api.openai.com/v1/realtime?model=$model")
                        .addHeader("Authorization", "Bearer $apiKey")
                        .addHeader("OpenAI-Beta", "realtime=v1")
                        .build()

                val socketRef = arrayOfNulls<WebSocket>(1)
                val socket =
                    client.newWebSocket(
                        request,
                        object : WebSocketListener() {
                            override fun onOpen(webSocket: WebSocket, response: Response) {
                                // Don't mark success on open: invalid_api_key can arrive as an "error" event.
                                // Send a minimal session.update to prompt a response from the server.
                                webSocket.send("""{"type":"session.update","session":{}}""")
                            }

                            override fun onMessage(webSocket: WebSocket, text: String) {
                                val type =
                                    try {
                                        JSONObject(text).optString("type")
                                    } catch (_: Throwable) {
                                        ""
                                    }

                                if (type == "error") {
                                    val obj = runCatching { JSONObject(text) }.getOrNull()
                                    val err = obj?.optJSONObject("error")
                                    val code = err?.optString("code")?.takeIf { it.isNotBlank() }
                                    val msg =
                                        err?.optString("message")?.takeIf { it.isNotBlank() }
                                            ?: obj?.optString("message")?.takeIf { it.isNotBlank() }
                                            ?: "Realtime error"
                                    val detail = if (code != null) "$code: $msg" else msg
                                    webSocket.close(1000, "error")
                                    if (resumed.compareAndSet(false, true) && cont.isActive) {
                                        cont.resume(Result.failure(IllegalStateException(detail)))
                                    }
                                    return
                                }

                                // Any non-error server event means auth worked and we can consider this "OK".
                                webSocket.close(1000, "ok")
                                if (resumed.compareAndSet(false, true) && cont.isActive) {
                                    cont.resume(Result.success(Unit))
                                }
                            }

                            override fun onFailure(
                                webSocket: WebSocket,
                                t: Throwable,
                                response: Response?,
                            ) {
                                val message =
                                    if (response != null) {
                                        "HTTP ${response.code}: ${response.message}"
                                    } else {
                                        t.message ?: "Connection error"
                                    }
                                if (resumed.compareAndSet(false, true) && cont.isActive) {
                                    cont.resume(Result.failure(IllegalStateException(message, t)))
                                }
                            }
                        },
                    )

                socketRef[0] = socket
                cont.invokeOnCancellation {
                    socketRef[0]?.cancel()
                }
            }.getOrThrow()
        }
        Result.success(Unit)
    } catch (t: Throwable) {
        Result.failure(t)
    }
}

private fun openAiModelDisplayName(modelId: String): String {
    val raw = modelId.trim()

    // Explicit display overrides (UI only). Keep backend ids unchanged.
    return when (raw) {
        "gpt-4o-realtime-preview" -> "GPT-4o-preview"
        "gpt-4o-mini-realtime-preview" -> "GPT-4o-mini"
        else -> {
            // Generic fallback: hide "realtime" and capitalize GPT prefix.
            raw
                .replaceFirst("gpt-", "GPT-")
                .replace("-realtime-", "-")
                .replace("-realtime", "")
        }
    }
}

private fun openAiModelDescriptionRes(modelId: String): Int? {
    return when (modelId.trim()) {
        "gpt-4o-realtime-preview" -> R.string.settings_openai_model_gpt4o_desc
        "gpt-4o-mini-realtime-preview" -> R.string.settings_openai_model_gpt4omini_desc
        else -> null
    }
}

private data class ReleaseInfo(
    val tagName: String,
    val htmlUrl: String?,
)

private fun normalizeVersionForComparison(raw: String): String {
    // Normalize typical tag/version formats: "v0.1.0" == "0.1.0"
    return raw.trim().removePrefix("v").removePrefix("V")
}

private suspend fun fetchLatestReleaseInfo(): Result<ReleaseInfo> {
    return withContext(Dispatchers.IO) {
        try {
            val client = OkHttpClient()
            val request =
                Request.Builder()
                    .url("https://api.github.com/repos/przemek-nowicki/meta-lens-ai/releases")
                    .header("Accept", "application/vnd.github+json")
                    .header("User-Agent", "MetaLens-AI-Android")
                    .build()

            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    return@withContext Result.failure(IllegalStateException("HTTP ${response.code}"))
                }

                val body = response.body?.string().orEmpty()
                val releases = JSONArray(body)
                if (releases.length() == 0) {
                    return@withContext Result.failure(IllegalStateException("No releases"))
                }

                val latest = releases.getJSONObject(0)
                val tagName = latest.optString("tag_name").orEmpty()
                val htmlUrl = latest.optString("html_url").takeIf { it.isNotBlank() }
                Result.success(ReleaseInfo(tagName = tagName, htmlUrl = htmlUrl))
            }
        } catch (t: Throwable) {
            Result.failure(t)
        }
    }
}

@Preview(showBackground = true)
@Composable
private fun SettingsScreenPreview() {
    SettingsScreen()
}
