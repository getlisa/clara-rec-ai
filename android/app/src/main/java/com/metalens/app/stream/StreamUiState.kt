package com.metalens.app.stream

import android.graphics.Bitmap
import com.meta.wearable.dat.camera.types.StreamSessionState

data class StreamUiState(
    val streamSessionState: StreamSessionState = StreamSessionState.STOPPED,
    val videoFrame: Bitmap? = null,
    val frameCount: Long = 0,
    val recentError: String? = null,
    val isRecording: Boolean = false,
    val recordingStartedAtMs: Long? = null,
    val recordingFrameCount: Long = 0,
    val lastSavedRecordingId: String? = null,
)
