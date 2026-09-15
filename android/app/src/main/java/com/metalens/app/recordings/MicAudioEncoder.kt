package com.metalens.app.recordings

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaRecorder
import android.util.Log

/**
 * Captures the phone microphone and muxes it as an AAC track alongside the glasses video.
 *
 * The glasses themselves expose no audio stream through the wearables SDK, so phone audio is
 * the only source available.
 */
class MicAudioEncoder private constructor(
    private val audioRecord: AudioRecord,
    private val bufferSize: Int,
) {
    private var codec: MediaCodec? = null
    private var thread: Thread? = null
    @Volatile private var running = false
    private var trackIndex = -1

    fun start(gate: MuxerGate, startNs: Long) {
        val encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC).apply {
            val format =
                MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, SAMPLE_RATE, CHANNELS).apply {
                    setInteger(
                        MediaFormat.KEY_AAC_PROFILE,
                        MediaCodecInfo.CodecProfileLevel.AACObjectLC,
                    )
                    setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE)
                    setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, bufferSize)
                }
            configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            start()
        }
        codec = encoder
        running = true

        audioRecord.startRecording()

        thread = Thread({ captureLoop(encoder, gate, startNs) }, "MicAudioEncoder").also { it.start() }
    }

    fun stop() {
        running = false
        thread?.join(STOP_JOIN_TIMEOUT_MS)
        thread = null

        runCatching {
            audioRecord.stop()
        }.onFailure { Log.w(TAG, "AudioRecord stop failed", it) }
        runCatching { audioRecord.release() }

        codec?.let { encoder ->
            runCatching { encoder.stop() }
            runCatching { encoder.release() }
        }
        codec = null
    }

    private fun captureLoop(encoder: MediaCodec, gate: MuxerGate, startNs: Long) {
        val pcm = ByteArray(bufferSize)
        val info = MediaCodec.BufferInfo()
        var lastPtsUs = -1L

        try {
            while (running) {
                val read = audioRecord.read(pcm, 0, pcm.size)
                if (read <= 0) continue

                val inputIndex = encoder.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
                if (inputIndex >= 0) {
                    val input = encoder.getInputBuffer(inputIndex)
                    if (input != null) {
                        input.clear()
                        input.put(pcm, 0, read)
                        // Shares the video clock so the two tracks line up on playback.
                        val elapsed = (System.nanoTime() - startNs) / 1000L
                        val pts = if (elapsed <= lastPtsUs) lastPtsUs + 1000L else elapsed
                        lastPtsUs = pts
                        encoder.queueInputBuffer(inputIndex, 0, read, pts, 0)
                    }
                }
                drain(encoder, gate, info)
            }

            val inputIndex = encoder.dequeueInputBuffer(END_OF_STREAM_TIMEOUT_US)
            if (inputIndex >= 0) {
                encoder.queueInputBuffer(
                    inputIndex,
                    0,
                    0,
                    lastPtsUs + 1000L,
                    MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                )
            }
            drain(encoder, gate, info)
        } catch (t: Throwable) {
            Log.e(TAG, "Audio capture failed", t)
        }
    }

    private fun drain(encoder: MediaCodec, gate: MuxerGate, info: MediaCodec.BufferInfo) {
        while (true) {
            val index = encoder.dequeueOutputBuffer(info, DEQUEUE_TIMEOUT_US)
            when {
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> return

                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    if (trackIndex < 0) {
                        trackIndex = gate.addTrack(encoder.outputFormat)
                    }
                }

                index >= 0 -> {
                    val encoded = encoder.getOutputBuffer(index)
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                        info.size = 0
                    }
                    if (encoded != null && info.size > 0) {
                        encoded.position(info.offset)
                        encoded.limit(info.offset + info.size)
                        gate.write(trackIndex, encoded, info)
                    }
                    encoder.releaseOutputBuffer(index, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                }
            }
        }
    }

    companion object {
        private const val TAG = "MicAudioEncoder"
        const val SAMPLE_RATE = 44100
        private const val CHANNELS = 1
        private const val BIT_RATE = 128_000
        private const val DEQUEUE_TIMEOUT_US = 10_000L
        private const val END_OF_STREAM_TIMEOUT_US = 500_000L
        private const val STOP_JOIN_TIMEOUT_MS = 2_000L

        /**
         * Returns null when the mic is unavailable (permission denied, or in use), so recording
         * can continue as video-only rather than failing outright.
         */
        fun createOrNull(): MicAudioEncoder? {
            return try {
                val minBuffer =
                    AudioRecord.getMinBufferSize(
                        SAMPLE_RATE,
                        AudioFormat.CHANNEL_IN_MONO,
                        AudioFormat.ENCODING_PCM_16BIT,
                    )
                if (minBuffer <= 0) return null

                val bufferSize = minBuffer * 2
                val record =
                    AudioRecord(
                        MediaRecorder.AudioSource.MIC,
                        SAMPLE_RATE,
                        AudioFormat.CHANNEL_IN_MONO,
                        AudioFormat.ENCODING_PCM_16BIT,
                        bufferSize,
                    )
                if (record.state != AudioRecord.STATE_INITIALIZED) {
                    record.release()
                    return null
                }
                MicAudioEncoder(record, bufferSize)
            } catch (t: Throwable) {
                Log.w(TAG, "Microphone unavailable, recording video only", t)
                null
            }
        }
    }
}
