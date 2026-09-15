package com.metalens.app.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.metalens.app.R
import com.metalens.app.recordings.RecordingRecord
import com.metalens.app.recordings.RecordingStorage
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

@Composable
fun RecordingsScreen(
    modifier: Modifier = Modifier,
    onOpenRecording: (String) -> Unit = {},
) {
    val context = LocalContext.current.applicationContext
    val storage = remember { RecordingStorage(context) }
    var recordings by remember { mutableStateOf<List<RecordingRecord>>(emptyList()) }

    fun reload() {
        recordings = storage.getAllRecordings()
    }

    LaunchedEffect(Unit) {
        reload()
    }

    if (recordings.isEmpty()) {
        Column(
            modifier = modifier.fillMaxSize(),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                text = stringResource(R.string.recordings_empty),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        return
    }

    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        items(items = recordings, key = { it.id }) { record ->
            RecordingRow(
                title = formatStartedAt(record.startedAtMs),
                subtitle = buildSubtitle(record),
                onClick = { onOpenRecording(record.id) },
                onDelete = {
                    storage.deleteRecording(record.id)
                    reload()
                },
            )
        }
    }
}

@Composable
private fun RecordingRow(
    title: String,
    subtitle: String,
    onClick: () -> Unit,
    onDelete: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier =
            modifier
                .fillMaxWidth()
                .clickable(onClick = onClick),
        shape = MaterialTheme.shapes.large,
        tonalElevation = 1.dp,
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(text = title, style = MaterialTheme.typography.titleMedium)
                Spacer(modifier = Modifier.height(2.dp))
                Text(
                    text = subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            Spacer(modifier = Modifier.width(8.dp))
            IconButton(onClick = onDelete) {
                Icon(
                    imageVector = Icons.Filled.Delete,
                    contentDescription = stringResource(R.string.recordings_delete),
                    tint = MaterialTheme.colorScheme.error,
                )
            }
        }
    }
}

private fun buildSubtitle(record: RecordingRecord): String {
    val duration = formatDuration(record.durationMs)
    val size = formatSize(record.sizeBytes)
    return if (record.width > 0 && record.height > 0) {
        "$duration  ${record.width}x${record.height}  $size"
    } else {
        "$duration  $size"
    }
}

private fun formatDuration(durationMs: Long): String {
    val totalSeconds = (durationMs / 1000L).coerceAtLeast(0L)
    return "%02d:%02d".format(totalSeconds / 60, totalSeconds % 60)
}

private fun formatSize(sizeBytes: Long): String {
    val mb = sizeBytes.toDouble() / (1024 * 1024)
    return String.format(Locale.US, "%.1f MB", mb)
}

private fun formatStartedAt(startedAtMs: Long): String {
    val dt =
        Instant.ofEpochMilli(startedAtMs)
            .atZone(ZoneId.systemDefault())
            .toLocalDateTime()
    return DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm").format(dt)
}
