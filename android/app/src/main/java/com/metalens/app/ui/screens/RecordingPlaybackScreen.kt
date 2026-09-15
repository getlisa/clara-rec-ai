package com.metalens.app.ui.screens

import android.widget.MediaController
import android.widget.VideoView
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.viewinterop.AndroidView
import com.metalens.app.R
import com.metalens.app.recordings.RecordingStorage

@Composable
fun RecordingPlaybackScreen(
    recordingId: String,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current.applicationContext
    val storage = remember { RecordingStorage(context) }
    val record = remember(recordingId) { storage.getRecording(recordingId) }

    if (record == null) {
        Column(
            modifier = modifier.fillMaxSize(),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                text = stringResource(R.string.recordings_not_found),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        return
    }

    Surface(modifier = modifier.fillMaxSize(), color = Color.Black) {
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            AndroidView(
                modifier = Modifier.fillMaxSize(),
                factory = { viewContext ->
                    VideoView(viewContext).apply {
                        setVideoURI(record.uri)
                        val controller = MediaController(viewContext)
                        controller.setAnchorView(this)
                        setMediaController(controller)
                        setOnPreparedListener { player ->
                            player.isLooping = true
                            start()
                        }
                    }
                },
                onRelease = { view -> view.stopPlayback() },
            )
        }
    }
}
