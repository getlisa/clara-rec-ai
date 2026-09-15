package com.metalens.app.recordings

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import android.util.Log
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Stores recordings in shared device storage (Movies/Clara-Assistant) so they appear in the
 * Gallery and survive uninstall. The app writes directly into the MediaStore entry, so there
 * is only ever one copy of a recording.
 */
class RecordingStorage(
    context: Context,
) {
    private val appContext = context.applicationContext
    private val resolver = appContext.contentResolver

    class Pending(
        val uri: Uri,
        val descriptor: ParcelFileDescriptor,
    )

    /**
     * Creates a pending MediaStore entry. It stays invisible to other apps until [publish],
     * so a half-written file never shows up in the Gallery.
     */
    fun createPending(startedAtMs: Long): Pending? {
        return try {
            val name = "clara_${FILE_NAME_FORMAT.format(Date(startedAtMs))}.mp4"
            val values = ContentValues().apply {
                put(MediaStore.Video.Media.DISPLAY_NAME, name)
                put(MediaStore.Video.Media.MIME_TYPE, MIME_TYPE)
                put(MediaStore.Video.Media.RELATIVE_PATH, RELATIVE_PATH)
                put(MediaStore.Video.Media.DATE_ADDED, startedAtMs / 1000L)
                put(MediaStore.Video.Media.IS_PENDING, 1)
            }
            val uri = resolver.insert(collection(), values) ?: return null
            val pfd = resolver.openFileDescriptor(uri, "rw")
            if (pfd == null) {
                resolver.delete(uri, null, null)
                return null
            }
            Pending(uri, pfd)
        } catch (t: Throwable) {
            Log.e(TAG, "Failed to create pending recording", t)
            null
        }
    }

    fun publish(pending: Pending) {
        try {
            val values = ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) }
            resolver.update(pending.uri, values, null, null)
        } catch (t: Throwable) {
            Log.e(TAG, "Failed to publish recording", t)
        }
    }

    fun discard(pending: Pending) {
        try {
            resolver.delete(pending.uri, null, null)
        } catch (t: Throwable) {
            Log.w(TAG, "Failed to discard pending recording", t)
        }
    }

    fun getAllRecordings(): List<RecordingRecord> {
        val projection =
            arrayOf(
                MediaStore.Video.Media._ID,
                MediaStore.Video.Media.DISPLAY_NAME,
                MediaStore.Video.Media.DATE_ADDED,
                MediaStore.Video.Media.DURATION,
                MediaStore.Video.Media.SIZE,
                MediaStore.Video.Media.WIDTH,
                MediaStore.Video.Media.HEIGHT,
            )

        return try {
            resolver.query(
                collection(),
                projection,
                "${MediaStore.Video.Media.RELATIVE_PATH} LIKE ?",
                arrayOf("$RELATIVE_PATH%"),
                "${MediaStore.Video.Media.DATE_ADDED} DESC",
            )?.use { cursor ->
                val idCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media._ID)
                val nameCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.DISPLAY_NAME)
                val dateCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.DATE_ADDED)
                val durationCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.DURATION)
                val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.SIZE)
                val widthCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.WIDTH)
                val heightCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.HEIGHT)

                buildList {
                    while (cursor.moveToNext()) {
                        val id = cursor.getLong(idCol)
                        add(
                            RecordingRecord(
                                id = id.toString(),
                                uri = ContentUris.withAppendedId(collection(), id),
                                displayName = cursor.getString(nameCol).orEmpty(),
                                startedAtMs = cursor.getLong(dateCol) * 1000L,
                                durationMs = cursor.getLong(durationCol),
                                sizeBytes = cursor.getLong(sizeCol),
                                width = cursor.getInt(widthCol),
                                height = cursor.getInt(heightCol),
                            ),
                        )
                    }
                }
            }.orEmpty()
        } catch (t: Throwable) {
            Log.e(TAG, "Failed to list recordings", t)
            emptyList()
        }
    }

    fun getRecording(id: String): RecordingRecord? =
        getAllRecordings().firstOrNull { it.id == id }

    fun deleteRecording(id: String): Boolean {
        return try {
            val recordingId = id.toLongOrNull() ?: return false
            resolver.delete(ContentUris.withAppendedId(collection(), recordingId), null, null) > 0
        } catch (t: Throwable) {
            Log.e(TAG, "Failed to delete recording", t)
            false
        }
    }

    private fun collection(): Uri =
        MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)

    private companion object {
        private const val TAG = "RecordingStorage"
        private const val MIME_TYPE = "video/mp4"
        private val RELATIVE_PATH = "${Environment.DIRECTORY_MOVIES}/Clara-Assistant"
        private val FILE_NAME_FORMAT = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US)
    }
}
