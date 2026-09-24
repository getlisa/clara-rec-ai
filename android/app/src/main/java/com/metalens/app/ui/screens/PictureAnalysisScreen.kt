package com.metalens.app.ui.screens

import androidx.activity.ComponentActivity
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.metalens.app.pictureanalysis.PictureAnalysisViewModel
import com.metalens.app.upload.ImageUploadViewModel
import com.metalens.app.upload.UploadStatus
import com.meta.wearable.dat.core.Wearables
import com.meta.wearable.dat.core.types.Permission
import com.meta.wearable.dat.core.types.PermissionStatus
import com.metalens.app.R
import com.metalens.app.wearables.LocalWearablesPermissionRequester
import com.metalens.app.wearables.WearablesViewModel
import kotlinx.coroutines.delay
import android.speech.tts.TextToSpeech
import java.util.Locale

@Composable
fun PictureAnalysisScreen(
    modifier: Modifier = Modifier,
    onClose: () -> Unit,
) {
    val activity = LocalContext.current as ComponentActivity
    val wearablesViewModel: WearablesViewModel = viewModel(activity)
    val analysisViewModel: PictureAnalysisViewModel = viewModel(activity)
    val uploadViewModel: ImageUploadViewModel = viewModel(activity)
    val permissionRequester = LocalWearablesPermissionRequester.current
    val wearablesState by wearablesViewModel.uiState.collectAsStateWithLifecycle()
    val analysisState by analysisViewModel.uiState.collectAsStateWithLifecycle()
    val uploadState by uploadViewModel.uiState.collectAsStateWithLifecycle()

    var countdown by remember { mutableIntStateOf(0) }
    var isCountingDown by remember { mutableStateOf(false) }

    // TTS (UI-owned lifecycle)
    val context = LocalContext.current
    var ttsReady by remember { mutableStateOf(false) }
    val tts =
        remember {
            TextToSpeech(context.applicationContext) { status ->
                ttsReady = status == TextToSpeech.SUCCESS
            }
        }
    DisposableEffect(Unit) {
        onDispose {
            runCatching { tts.stop() }
            runCatching { tts.shutdown() }
        }
    }

    LaunchedEffect(Unit) {
        // Prepare camera session first (permission + STREAMING), then countdown will trigger capture.
        if (wearablesState.capturedPhoto == null && !wearablesState.isCapturingPhoto && !wearablesState.isPreparingPhotoSession && !wearablesState.isPhotoSessionReady) {
            val permission = Permission.CAMERA
            val statusResult = Wearables.checkPermissionStatus(permission)
            statusResult.onFailure { error, _ ->
                wearablesViewModel.setRecentError("Permission check error: ${error.description}")
            }
            val status = statusResult.getOrNull()
            val granted =
                when (status) {
                    PermissionStatus.Granted -> true
                    PermissionStatus.Denied -> permissionRequester.request(permission) == PermissionStatus.Granted
                    null -> false
                }

            if (granted) {
                wearablesViewModel.preparePhotoCaptureSession()
            } else {
                wearablesViewModel.setRecentError("Camera permission denied")
            }
        }
    }

    LaunchedEffect(wearablesState.isPhotoSessionReady, wearablesState.capturedPhoto) {
        // Start 3..2..1 countdown only once the session is ready and we don't have a photo yet.
        if (wearablesState.capturedPhoto != null) return@LaunchedEffect
        if (!wearablesState.isPhotoSessionReady) return@LaunchedEffect
        if (isCountingDown) return@LaunchedEffect

        isCountingDown = true
        for (i in 3 downTo 1) {
            countdown = i
            delay(1_000)
        }
        countdown = 0
        wearablesViewModel.capturePreparedPhoto()
        isCountingDown = false
    }

    LaunchedEffect(wearablesState.capturedPhoto) {
        // New photo => reset analysis so user always sees a fresh run.
        val photo = wearablesState.capturedPhoto
        if (photo != null) {
            analysisViewModel.reset()
            analysisViewModel.analyze(photo)
            // Archiving runs alongside analysis; neither blocks the other.
            uploadViewModel.uploadIfNeeded(photo)
        }
    }

    LaunchedEffect(analysisState.resultText, ttsReady) {
        // Auto-speak when we get a new result.
        val text = analysisState.resultText
        if (ttsReady && !text.isNullOrBlank()) {
            val preferred = Locale.US
            val res = tts.setLanguage(preferred)
            if (res == TextToSpeech.LANG_MISSING_DATA || res == TextToSpeech.LANG_NOT_SUPPORTED) {
                tts.setLanguage(Locale.getDefault())
            }
            tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, "picture_analysis_result")
        }
    }

    LaunchedEffect(analysisState.isAnalyzing, ttsReady) {
        // Speak a short status message when analysis starts.
        if (ttsReady && analysisState.isAnalyzing) {
            val preferred = Locale.US
            val res = tts.setLanguage(preferred)
            if (res == TextToSpeech.LANG_MISSING_DATA || res == TextToSpeech.LANG_NOT_SUPPORTED) {
                tts.setLanguage(Locale.getDefault())
            }
            tts.stop()
            tts.speak(
                context.getString(R.string.voice_messages),
                TextToSpeech.QUEUE_FLUSH,
                null,
                "picture_analysis_analyzing",
            )
        }
    }

    Surface(modifier = modifier.fillMaxSize(), color = Color.Black) {
        BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
            val photo = wearablesState.capturedPhoto
            when {
                photo != null -> {
                    Image(
                        bitmap = photo.asImageBitmap(),
                        contentDescription = stringResource(R.string.picture_analysis),
                        modifier = Modifier.fillMaxSize(),
                        contentScale = ContentScale.Fit,
                    )
                }
                wearablesState.isPreparingPhotoSession -> {
                    Column(
                        modifier = Modifier.align(Alignment.Center),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        CircularProgressIndicator()
                        Text(
                            text = stringResource(R.string.picture_analysis_preparing),
                            color = Color.White,
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    }
                }
                countdown > 0 -> {
                    // Big countdown overlay (3..2..1)
                    Text(
                        text = countdown.toString(),
                        color = Color.White,
                        style = MaterialTheme.typography.displayLarge.copy(fontWeight = FontWeight.Bold),
                        modifier = Modifier.align(Alignment.Center),
                    )
                }
                wearablesState.isCapturingPhoto -> {
                    Column(
                        modifier = Modifier.align(Alignment.Center),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        CircularProgressIndicator()
                        Text(
                            text = stringResource(R.string.picture_analysis_capturing),
                            color = Color.White,
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    }
                }
                else -> {
                    // Error / empty state
                    val msg = wearablesState.recentError ?: "No photo"
                    Text(
                        text = msg,
                        color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.bodyMedium,
                        modifier =
                            Modifier
                                .align(Alignment.Center)
                                .padding(24.dp),
                    )
                }
            }

            // Analysis overlay (only when we have a photo)
            if (photo != null) {
                Column(
                    modifier =
                        Modifier
                            .align(Alignment.TopStart)
                            .padding(16.dp)
                            .background(Color.Black.copy(alpha = 0.55f), shape = MaterialTheme.shapes.medium)
                            .padding(12.dp)
                            .fillMaxWidth(0.9f)
                            .verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            text = stringResource(R.string.picture_analysis_result),
                            color = Color.White,
                            style = MaterialTheme.typography.titleSmall,
                        )

                        if (analysisState.isAnalyzing) {
                            Text(
                                text = stringResource(R.string.picture_analysis_analyzing),
                                color = Color.White,
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                    }

                    analysisState.recentError?.let { err ->
                        Text(
                            text = err,
                            color = MaterialTheme.colorScheme.error,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }

                    when (val upload = uploadState.status) {
                        is UploadStatus.Uploading ->
                            Text(
                                text = stringResource(R.string.upload_uploading),
                                color = Color.White.copy(alpha = 0.8f),
                                style = MaterialTheme.typography.bodySmall,
                            )
                        is UploadStatus.Uploaded ->
                            Text(
                                text =
                                    stringResource(R.string.upload_uploaded) +
                                        " · " +
                                        stringResource(R.string.upload_author_prefix, uploadState.authorPrefix),
                                color = Color.White.copy(alpha = 0.8f),
                                style = MaterialTheme.typography.bodySmall,
                            )
                        is UploadStatus.Failed ->
                            Text(
                                text = stringResource(R.string.upload_failed, upload.message),
                                color = MaterialTheme.colorScheme.error,
                                style = MaterialTheme.typography.bodySmall,
                            )
                        // Idle and NotConfigured stay silent: uploading is optional, and a user
                        // who never set up a bucket shouldn't be nagged on every capture.
                        UploadStatus.Idle, UploadStatus.NotConfigured -> Unit
                    }

                    Text(
                        text = analysisState.resultText ?: "",
                        color = Color.White,
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
            }

            // Bottom actions
            Row(
                modifier =
                    Modifier
                        .align(Alignment.BottomCenter)
                        .navigationBarsPadding()
                        .fillMaxWidth()
                        .background(Color.Black.copy(alpha = 0.4f))
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                val busy = wearablesState.isPreparingPhotoSession || wearablesState.isCapturingPhoto || countdown > 0

                TextButton(
                    enabled = !busy,
                    onClick = {
                        // Reset and start again
                        countdown = 0
                        isCountingDown = false
                        wearablesViewModel.resetPictureAnalysis()
                        analysisViewModel.reset()
                        uploadViewModel.reset()
                        wearablesViewModel.preparePhotoCaptureSession()
                    },
                ) {
                    Text("Retake", color = Color.White)
                }

                if (photo != null) {
                    TextButton(
                        enabled = !analysisState.isAnalyzing,
                        onClick = {
                            analysisViewModel.reset()
                            analysisViewModel.analyze(photo)
                        },
                    ) {
                        Text(stringResource(R.string.picture_analysis_analyze), color = Color.White)
                    }
                }

                if (photo != null && uploadState.canRetry) {
                    TextButton(onClick = { uploadViewModel.upload(photo) }) {
                        Text(stringResource(R.string.upload_retry), color = Color.White)
                    }
                }

                if (!analysisState.resultText.isNullOrBlank()) {
                    TextButton(
                        onClick = {
                            tts.stop()
                            val preferred = Locale.US
                            val res = tts.setLanguage(preferred)
                            if (res == TextToSpeech.LANG_MISSING_DATA || res == TextToSpeech.LANG_NOT_SUPPORTED) {
                                tts.setLanguage(Locale.getDefault())
                            }
                            tts.speak(analysisState.resultText, TextToSpeech.QUEUE_FLUSH, null, "picture_analysis_result_manual")
                        },
                    ) {
                        Text(stringResource(R.string.picture_analysis_speak), color = Color.White)
                    }
                }

                TextButton(
                    enabled = !busy,
                    onClick = {
                        countdown = 0
                        isCountingDown = false
                        wearablesViewModel.resetPictureAnalysis()
                        analysisViewModel.reset()
                        uploadViewModel.reset()
                        runCatching { tts.stop() }
                        onClose()
                    },
                ) {
                    Text(stringResource(R.string.common_close), color = Color.White)
                }
            }
        }
    }
}

