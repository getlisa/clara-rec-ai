package com.metalens.app.recordings

import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.util.Log
import java.io.FileDescriptor

/**
 * Encodes raw I420 frames from the glasses stream into an H.264/MP4 file, optionally with
 * an AAC audio track.
 *
 * Writes into [outputFd], which the caller owns and must close after [stop].
 *
 * Not thread-safe: every call must be made from the same single thread, since MediaCodec
 * state transitions are not synchronized.
 */
class StreamRecorder(private val outputFd: FileDescriptor) {

    data class Result(
        val durationMs: Long,
        val frameCount: Long,
        val width: Int,
        val height: Int,
        val hasAudio: Boolean,
    )

    private var codec: MediaCodec? = null
    private var gate: MuxerGate? = null
    private var audioEncoder: MicAudioEncoder? = null
    private val bufferInfo = MediaCodec.BufferInfo()

    private var trackIndex = -1
    private var startNs = 0L
    private var lastPtsUs = -1L

    private var width = 0
    private var height = 0
    private var frameCount = 0L

    fun start(frameWidth: Int, frameHeight: Int, frameRate: Int, withAudio: Boolean) {
        // Encoders reject odd dimensions; chroma planes are half-resolution.
        width = frameWidth and 1.inv()
        height = frameHeight and 1.inv()
        require(width > 0 && height > 0) { "Invalid frame size ${frameWidth}x$frameHeight" }

        val format = MediaFormat.createVideoFormat(MIME_TYPE, width, height).apply {
            setInteger(
                MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible,
            )
            setInteger(MediaFormat.KEY_BIT_RATE, bitRateFor(width, height, frameRate))
            setInteger(MediaFormat.KEY_FRAME_RATE, frameRate)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, I_FRAME_INTERVAL_SECONDS)
        }

        // Resolve audio before creating the gate: the muxer cannot start until it knows
        // how many tracks to expect.
        val audio = if (withAudio) MicAudioEncoder.createOrNull() else null
        audioEncoder = audio

        val muxer = MediaMuxer(outputFd, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        val muxerGate = MuxerGate(muxer, expectedTracks = if (audio != null) 2 else 1)
        gate = muxerGate

        codec = MediaCodec.createEncoderByType(MIME_TYPE).apply {
            configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            start()
        }

        startNs = System.nanoTime()
        lastPtsUs = -1L
        frameCount = 0L

        if (audio != null) {
            runCatching { audio.start(muxerGate, startNs) }
                .onFailure {
                    Log.w(TAG, "Failed to start audio capture", it)
                    audioEncoder = null
                }
        }
    }

    /**
     * [i420] must already be a private copy: the SDK reuses its frame buffers once the
     * stream collector returns.
     */
    fun encode(i420: ByteArray, frameWidth: Int, frameHeight: Int) {
        val encoder = codec ?: return
        if (frameWidth != width || frameHeight != height) {
            // Resolution changes mid-stream would corrupt the track; drop instead.
            return
        }

        val inputIndex = encoder.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
        if (inputIndex < 0) {
            drain()
            return
        }

        val image = encoder.getInputImage(inputIndex)
        if (image == null) {
            encoder.queueInputBuffer(inputIndex, 0, 0, nextPtsUs(), 0)
            throw IllegalStateException("Encoder did not provide a YUV input image")
        }

        fillImage(image, i420)
        encoder.queueInputBuffer(inputIndex, 0, width * height * 3 / 2, nextPtsUs(), 0)
        frameCount++

        drain()
    }

    fun stop(): Result? {
        val encoder = codec
        val muxerGate = gate
        val audio = audioEncoder
        codec = null
        gate = null
        audioEncoder = null

        // Stop audio first so its end-of-stream samples reach the muxer before it closes.
        runCatching { audio?.stop() }
            .onFailure { Log.w(TAG, "Audio stop failed", it) }

        if (encoder != null) {
            runCatching {
                val index = encoder.dequeueInputBuffer(END_OF_STREAM_TIMEOUT_US)
                if (index >= 0) {
                    encoder.queueInputBuffer(
                        index,
                        0,
                        0,
                        nextPtsUs(),
                        MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                    )
                }
            }
            if (muxerGate != null) {
                runCatching { drainInternal(encoder, muxerGate, endOfStream = true) }
            }
            runCatching { encoder.stop() }
            runCatching { encoder.release() }
        }

        val wroteSamples = muxerGate?.stopAndRelease() ?: false
        trackIndex = -1

        if (frameCount == 0L || !wroteSamples) return null

        return Result(
            durationMs = (lastPtsUs.coerceAtLeast(0L)) / 1000L,
            frameCount = frameCount,
            width = width,
            height = height,
            hasAudio = audio != null,
        )
    }

    /**
     * Frames carry no timestamp, so the wall clock since start defines playback pacing.
     * Muxers reject non-monotonic timestamps, hence the forced step.
     */
    private fun nextPtsUs(): Long {
        val elapsed = (System.nanoTime() - startNs) / 1000L
        val pts = if (elapsed <= lastPtsUs) lastPtsUs + 1000L else elapsed
        lastPtsUs = pts
        return pts
    }

    private fun fillImage(image: Image, i420: ByteArray) {
        val ySize = width * height
        val chromaWidth = width / 2
        val chromaHeight = height / 2
        val chromaSize = chromaWidth * chromaHeight

        copyPlane(i420, 0, width, height, image.planes[0])
        copyPlane(i420, ySize, chromaWidth, chromaHeight, image.planes[1])
        copyPlane(i420, ySize + chromaSize, chromaWidth, chromaHeight, image.planes[2])
    }

    private fun copyPlane(
        src: ByteArray,
        srcOffset: Int,
        planeWidth: Int,
        planeHeight: Int,
        plane: Image.Plane,
    ) {
        val dst = plane.buffer
        val rowStride = plane.rowStride
        val pixelStride = plane.pixelStride

        if (pixelStride == 1 && rowStride == planeWidth) {
            dst.position(0)
            dst.put(src, srcOffset, planeWidth * planeHeight)
            return
        }

        for (row in 0 until planeHeight) {
            val srcRow = srcOffset + row * planeWidth
            val dstRow = row * rowStride
            if (pixelStride == 1) {
                dst.position(dstRow)
                dst.put(src, srcRow, planeWidth)
            } else {
                for (col in 0 until planeWidth) {
                    dst.put(dstRow + col * pixelStride, src[srcRow + col])
                }
            }
        }
    }

    private fun drain() {
        val encoder = codec ?: return
        val muxerGate = gate ?: return
        drainInternal(encoder, muxerGate, endOfStream = false)
    }

    private fun drainInternal(encoder: MediaCodec, muxerGate: MuxerGate, endOfStream: Boolean) {
        val deadline = System.nanoTime() + END_OF_STREAM_DRAIN_NS

        while (true) {
            val index = encoder.dequeueOutputBuffer(bufferInfo, DEQUEUE_TIMEOUT_US)
            when {
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!endOfStream) return
                    if (System.nanoTime() > deadline) {
                        Log.w(TAG, "Timed out waiting for end of stream")
                        return
                    }
                }

                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    if (trackIndex < 0) {
                        trackIndex = muxerGate.addTrack(encoder.outputFormat)
                    }
                }

                index >= 0 -> {
                    val encoded = encoder.getOutputBuffer(index)
                    // Codec config bytes travel in the track format, not as a sample.
                    if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                        bufferInfo.size = 0
                    }
                    if (encoded != null && bufferInfo.size > 0) {
                        encoded.position(bufferInfo.offset)
                        encoded.limit(bufferInfo.offset + bufferInfo.size)
                        muxerGate.write(trackIndex, encoded, bufferInfo)
                    }
                    encoder.releaseOutputBuffer(index, false)
                    if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                }
            }
        }
    }

    private companion object {
        private const val TAG = "StreamRecorder"
        private const val MIME_TYPE = MediaFormat.MIMETYPE_VIDEO_AVC
        private const val I_FRAME_INTERVAL_SECONDS = 1
        private const val DEQUEUE_TIMEOUT_US = 10_000L
        private const val END_OF_STREAM_TIMEOUT_US = 1_000_000L
        private const val END_OF_STREAM_DRAIN_NS = 3_000_000_000L

        private fun bitRateFor(width: Int, height: Int, frameRate: Int): Int {
            val estimate = width.toLong() * height.toLong() * frameRate.toLong() / 10L
            return estimate.coerceIn(1_000_000L, 12_000_000L).toInt()
        }
    }
}
