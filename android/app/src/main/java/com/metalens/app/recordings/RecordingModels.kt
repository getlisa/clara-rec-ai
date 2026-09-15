package com.metalens.app.recordings

import android.net.Uri

data class RecordingRecord(
    val id: String,
    val uri: Uri,
    val displayName: String,
    val startedAtMs: Long,
    val durationMs: Long,
    val sizeBytes: Long,
    val width: Int,
    val height: Int,
)
