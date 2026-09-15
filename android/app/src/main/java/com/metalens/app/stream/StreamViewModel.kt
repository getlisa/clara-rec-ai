package com.metalens.app.stream

import android.app.Application
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.meta.wearable.dat.camera.StreamSession
import com.meta.wearable.dat.camera.startStreamSession
import com.meta.wearable.dat.camera.types.StreamConfiguration
import com.meta.wearable.dat.camera.types.StreamSessionState
import com.meta.wearable.dat.camera.types.VideoFrame
import com.meta.wearable.dat.core.Wearables
import com.meta.wearable.dat.core.selectors.DeviceSelector
import com.metalens.app.recordings.RecordingStorage
import com.metalens.app.recordings.StreamRecorder
import com.metalens.app.settings.AppSettings
import com.metalens.app.wearables.WearablesViewModel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class StreamViewModel(
    application: Application,
    wearablesViewModel: WearablesViewModel,
) : AndroidViewModel(application) {
    companion object {
        private const val TAG = "StreamViewModel"
        private const val FRAME_RATE = 24

        // Bounded so a slow encoder drops frames instead of growing the queue without limit.
        private const val ENCODE_QUEUE_CAPACITY = 4
    }

    private data class PendingFrame(val bytes: ByteArray, val width: Int, val height: Int)

    private val deviceSelector: DeviceSelector = wearablesViewModel.deviceSelector
    private var streamSession: StreamSession? = null

    private val _uiState = MutableStateFlow(StreamUiState())
    val uiState: StateFlow<StreamUiState> = _uiState.asStateFlow()

    private var videoJob: Job? = null
    private var stateJob: Job? = null
    private var lastSessionState: StreamSessionState? = null

    private val storage = RecordingStorage(application)
    private val encoderDispatcher = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
    private val encoderScope = CoroutineScope(encoderDispatcher + SupervisorJob())
    private var frameChannel: Channel<PendingFrame>? = null
    private var encoderJob: Job? = null

    fun startStream() {
        Log.d(TAG, "startStream()")
        stopStream()
        lastSessionState = null

        val session =
            try {
                Wearables.startStreamSession(
                    getApplication(),
                    deviceSelector,
                    StreamConfiguration(videoQuality = AppSettings.getCameraVideoQuality(getApplication()), FRAME_RATE),
                ).also { streamSession = it }
            } catch (t: Throwable) {
                Log.e(TAG, "startStreamSession() failed", t)
                _uiState.update { it.copy(recentError = t.message ?: "Failed to start stream session") }
                return
            }

        videoJob =
            viewModelScope.launch {
                try {
                    Log.d(TAG, "Collecting videoStream...")
                    session.videoStream.collect { frame -> handleVideoFrame(frame) }
                    Log.d(TAG, "videoStream completed")
                } catch (t: Throwable) {
                    if (t is CancellationException) {
                        Log.d(TAG, "videoStream collector cancelled")
                        return@launch
                    }
                    Log.e(TAG, "videoStream collector failed", t)
                    _uiState.update {
                        it.copy(
                            recentError = t.message ?: "Video stream collector failed",
                        )
                    }
                }
            }

        stateJob =
            viewModelScope.launch {
                session.state.collect { state ->
                    val prev = lastSessionState
                    lastSessionState = state
                    Log.d(TAG, "session.state=$state (prev=$prev)")
                    _uiState.update { it.copy(streamSessionState = state) }

                    // IMPORTANT: StreamSessionState starts as STOPPED. Only treat STOPPED as "ended"
                    // if it is a transition from a different state (like STARTING/STREAMING/etc.).
                    if (prev != null && prev != state && state == StreamSessionState.STOPPED) {
                        Log.d(TAG, "Session transitioned to STOPPED -> cleaning up")
                        stopStream()
                    }

                    if (prev != null && prev != state && state == StreamSessionState.CLOSED) {
                        Log.d(TAG, "Session transitioned to CLOSED -> cleaning up")
                        stopStream()
                    }
                }
            }
    }

    fun stopStream() {
        Log.d(TAG, "stopStream()")
        stopRecording()
        videoJob?.cancel()
        videoJob = null
        stateJob?.cancel()
        stateJob = null
        streamSession?.close()
        streamSession = null
        _uiState.update { StreamUiState(lastSavedRecordingId = it.lastSavedRecordingId) }
    }

    fun startRecording() {
        if (frameChannel != null) return

        val startedAtMs = System.currentTimeMillis()
        val pending = storage.createPending(startedAtMs)
        if (pending == null) {
            _uiState.update { it.copy(recentError = "Could not create recording file") }
            return
        }

        val channel =
            Channel<PendingFrame>(
                capacity = ENCODE_QUEUE_CAPACITY,
                onBufferOverflow = BufferOverflow.DROP_OLDEST,
            )
        frameChannel = channel

        encoderJob =
            encoderScope.launch {
                val recorder = StreamRecorder(pending.descriptor.fileDescriptor)
                var started = false
                try {
                    for (frame in channel) {
                        if (!started) {
                            recorder.start(frame.width, frame.height, FRAME_RATE, withAudio = true)
                            started = true
                        }
                        recorder.encode(frame.bytes, frame.width, frame.height)
                        _uiState.update { it.copy(recordingFrameCount = it.recordingFrameCount + 1) }
                    }
                } catch (t: Throwable) {
                    Log.e(TAG, "Recording failed", t)
                    _uiState.update {
                        it.copy(recentError = t.message ?: "Recording failed")
                    }
                } finally {
                    // Runs even when the scope is cancelled, so a stopped recording is still
                    // muxed into a playable file rather than left truncated.
                    val result = if (started) runCatching { recorder.stop() }.getOrNull() else null
                    // The descriptor must outlive the muxer and be closed before publishing,
                    // otherwise MediaStore reports a zero-length file.
                    runCatching { pending.descriptor.close() }

                    if (result != null) {
                        storage.publish(pending)
                        _uiState.update { it.copy(lastSavedRecordingId = pending.uri.toString()) }
                        Log.d(TAG, "Saved recording ${pending.uri} (${result.durationMs}ms)")
                    } else {
                        storage.discard(pending)
                        Log.w(TAG, "Recording produced no output")
                    }
                }
            }

        _uiState.update {
            it.copy(
                isRecording = true,
                recordingStartedAtMs = startedAtMs,
                recordingFrameCount = 0,
            )
        }
    }

    fun stopRecording() {
        val channel = frameChannel ?: return
        frameChannel = null
        // Closing lets the encoder drain what is queued, then finalize the file.
        channel.close()
        _uiState.update { it.copy(isRecording = false, recordingStartedAtMs = null) }
    }

    private fun handleVideoFrame(videoFrame: VideoFrame) {
        try {
            if (_uiState.value.frameCount == 0L) {
                Log.d(TAG, "First video frame received: ${videoFrame.width}x${videoFrame.height}")
            }

            // Copy before returning: the SDK reuses the frame buffer once this collector yields.
            val bytes = copyFrameBytes(videoFrame)
            val width = videoFrame.width
            val height = videoFrame.height

            frameChannel?.trySend(PendingFrame(bytes, width, height))

            viewModelScope.launch {
                val bitmap =
                    withContext(Dispatchers.Default) {
                        decodeToBitmap(bytes, width, height)
                    }
                _uiState.update { it.copy(videoFrame = bitmap, frameCount = it.frameCount + 1) }
            }
        } catch (t: Throwable) {
            Log.e(TAG, "handleVideoFrame failed", t)
            _uiState.update { it.copy(recentError = t.message ?: "Failed to decode video frame") }
        }
    }

    private fun copyFrameBytes(videoFrame: VideoFrame): ByteArray {
        val buffer = videoFrame.buffer
        val byteArray = ByteArray(buffer.remaining())
        val originalPosition = buffer.position()
        buffer.get(byteArray)
        buffer.position(originalPosition)
        return byteArray
    }

    private fun decodeToBitmap(i420: ByteArray, width: Int, height: Int): android.graphics.Bitmap? {
        val nv21 = convertI420toNV21(i420, width, height)
        val image = YuvImage(nv21, ImageFormat.NV21, width, height, null)
        val out =
            ByteArrayOutputStream().use { stream ->
                image.compressToJpeg(Rect(0, 0, width, height), 50, stream)
                stream.toByteArray()
            }

        return BitmapFactory.decodeByteArray(out, 0, out.size)
    }

    // Convert I420 (YYYYYYYY:UUVV) to NV21 (YYYYYYYY:VUVU)
    private fun convertI420toNV21(input: ByteArray, width: Int, height: Int): ByteArray {
        val output = ByteArray(input.size)
        val size = width * height
        val quarter = size / 4

        input.copyInto(output, 0, 0, size) // Y is the same

        for (n in 0 until quarter) {
            output[size + n * 2] = input[size + quarter + n] // V first
            output[size + n * 2 + 1] = input[size + n] // U second
        }
        return output
    }

    override fun onCleared() {
        super.onCleared()
        stopStream()
        val job = encoderJob
        if (job == null) {
            encoderDispatcher.close()
        } else {
            // Shut the thread down only once the final mux has been written.
            job.invokeOnCompletion { encoderDispatcher.close() }
        }
    }

    class Factory(
        private val application: Application,
        private val wearablesViewModel: WearablesViewModel,
    ) : ViewModelProvider.Factory {
        override fun <T : ViewModel> create(modelClass: Class<T>): T {
            if (modelClass.isAssignableFrom(StreamViewModel::class.java)) {
                @Suppress("UNCHECKED_CAST", "KotlinGenericsCast")
                return StreamViewModel(
                    application = application,
                    wearablesViewModel = wearablesViewModel,
                ) as T
            }
            throw IllegalArgumentException("Unknown ViewModel class")
        }
    }
}
