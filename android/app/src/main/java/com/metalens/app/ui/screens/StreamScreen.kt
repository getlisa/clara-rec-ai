package com.metalens.app.ui.screens

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts.RequestPermission
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.FiberManualRecord
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.delay
import com.meta.wearable.dat.camera.types.StreamSessionState
import com.meta.wearable.dat.core.Wearables
import com.meta.wearable.dat.core.types.Permission
import com.meta.wearable.dat.core.types.PermissionStatus
import com.metalens.app.R
import com.metalens.app.settings.AppSettings
import com.metalens.app.stream.StreamViewModel
import com.metalens.app.wearables.LocalWearablesPermissionRequester
import com.metalens.app.wearables.WearablesViewModel

@Composable
fun StreamScreen(
    modifier: Modifier = Modifier,
    onStop: () -> Unit,
) {
    val activity = LocalContext.current as ComponentActivity
    val context = LocalContext.current
    val wearablesViewModel: WearablesViewModel = viewModel(activity)
    val permissionRequester = LocalWearablesPermissionRequester.current

    val streamViewModel: StreamViewModel =
        viewModel(
            factory =
                StreamViewModel.Factory(
                    application = activity.application,
                    wearablesViewModel = wearablesViewModel,
                ),
        )

    val uiState by streamViewModel.uiState.collectAsStateWithLifecycle()

    // Recording falls back to video-only when the mic is denied, so a refusal must not block it.
    val micPermissionLauncher =
        rememberLauncherForActivityResult(RequestPermission()) { _ ->
            streamViewModel.startRecording()
        }

    fun beginRecording() {
        val granted =
            ContextCompat.checkSelfPermission(activity, Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED
        if (granted) {
            streamViewModel.startRecording()
        } else {
            micPermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    LaunchedEffect(Unit) {
        // Ensure wearable camera permission before starting stream
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
            streamViewModel.startStream()
        } else {
            onStop()
        }
    }

    Surface(modifier = modifier.fillMaxSize(), color = Color.Black) {
        Box(modifier = Modifier.fillMaxSize()) {
        uiState.videoFrame?.let { frame ->
            Image(
                bitmap = frame.asImageBitmap(),
                contentDescription = stringResource(R.string.live_stream),
                modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Crop,
            )
        }

        if (uiState.isRecording) {
            RecordingIndicator(
                startedAtMs = uiState.recordingStartedAtMs,
                modifier = Modifier.align(Alignment.TopEnd).padding(16.dp),
            )
        }

        if (uiState.streamSessionState == StreamSessionState.STARTING) {
            CircularProgressIndicator(
                modifier = Modifier.align(Alignment.Center),
            )
        }
        if (uiState.videoFrame == null && uiState.recentError == null) {
            CircularProgressIndicator(
                modifier = Modifier.align(Alignment.Center),
            )
        }

        // Debug/Status overlay (helps when screen is blank)
        Column(
            modifier =
                Modifier
                    .align(Alignment.TopStart)
                    .padding(16.dp)
                    .background(Color.Black.copy(alpha = 0.4f), shape = MaterialTheme.shapes.medium)
                    .padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                text = "session=${uiState.streamSessionState}",
                color = Color.White,
                style = MaterialTheme.typography.bodySmall,
            )
            Text(
                text = "quality=${AppSettings.getCameraVideoQuality(context).name}",
                color = Color.White,
                style = MaterialTheme.typography.bodySmall,
            )
            Text(
                text = "frames=${uiState.frameCount}",
                color = Color.White,
                style = MaterialTheme.typography.bodySmall,
            )
            Text(
                text = "registered=${wearablesViewModel.uiState.value.isRegistered} active=${wearablesViewModel.uiState.value.hasActiveDevice}",
                color = Color.White,
                style = MaterialTheme.typography.bodySmall,
            )
            uiState.recentError?.let {
                Text(
                    text = "error=$it",
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }

        Row(
            modifier =
                Modifier
                    .align(Alignment.BottomCenter)
                    .navigationBarsPadding()
                    .fillMaxWidth()
                    .height(64.dp)
                    .padding(horizontal = 16.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val canRecord = uiState.videoFrame != null
            IconButton(
                onClick = {
                    if (uiState.isRecording) {
                        streamViewModel.stopRecording()
                    } else {
                        beginRecording()
                    }
                },
                enabled = canRecord,
                colors =
                    IconButtonDefaults.iconButtonColors(
                        contentColor = if (uiState.isRecording) Color.White else Color.Red,
                    ),
                modifier = Modifier.size(56.dp).clip(CircleShape),
            ) {
                Icon(
                    imageVector =
                        if (uiState.isRecording) Icons.Filled.Stop else Icons.Filled.FiberManualRecord,
                    contentDescription =
                        stringResource(
                            if (uiState.isRecording) {
                                R.string.stop_recording
                            } else {
                                R.string.start_recording
                            },
                        ),
                    modifier = Modifier.size(40.dp),
                )
            }

            TextButton(
                onClick = {
                    streamViewModel.stopStream()
                    onStop()
                },
            ) {
                Text(stringResource(R.string.stop_streaming))
            }
        }
        }
    }
}

@Composable
private fun RecordingIndicator(
    startedAtMs: Long?,
    modifier: Modifier = Modifier,
) {
    var elapsedMs by remember(startedAtMs) { mutableLongStateOf(0L) }

    LaunchedEffect(startedAtMs) {
        if (startedAtMs == null) return@LaunchedEffect
        while (true) {
            elapsedMs = System.currentTimeMillis() - startedAtMs
            delay(500)
        }
    }

    Row(
        modifier =
            modifier
                .background(Color.Black.copy(alpha = 0.5f), shape = MaterialTheme.shapes.medium)
                .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(modifier = Modifier.size(10.dp).clip(CircleShape).background(Color.Red))
        Text(
            text = formatElapsed(elapsedMs),
            color = Color.White,
            style = MaterialTheme.typography.bodyMedium,
        )
    }
}

private fun formatElapsed(elapsedMs: Long): String {
    val totalSeconds = (elapsedMs / 1000L).coerceAtLeast(0L)
    val minutes = totalSeconds / 60
    val seconds = totalSeconds % 60
    return "%02d:%02d".format(minutes, seconds)
}

