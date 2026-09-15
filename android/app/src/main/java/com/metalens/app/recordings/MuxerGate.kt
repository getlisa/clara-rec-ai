package com.metalens.app.recordings

import android.media.MediaCodec
import android.media.MediaFormat
import android.media.MediaMuxer
import android.util.Log
import java.nio.ByteBuffer

/**
 * Serializes access to a [MediaMuxer] shared by the video and audio encoders.
 *
 * A muxer only accepts samples once every track has been added, so writes are dropped
 * until the expected tracks have registered.
 */
class MuxerGate(
    private val muxer: MediaMuxer,
    private val expectedTracks: Int,
) {
    private val lock = Any()
    private var addedTracks = 0
    private var started = false
    private var stopped = false

    fun addTrack(format: MediaFormat): Int {
        synchronized(lock) {
            val index = muxer.addTrack(format)
            addedTracks++
            if (addedTracks == expectedTracks && !started) {
                muxer.start()
                started = true
            }
            return index
        }
    }

    fun write(trackIndex: Int, buffer: ByteBuffer, info: MediaCodec.BufferInfo) {
        synchronized(lock) {
            if (!started || stopped || trackIndex < 0 || info.size <= 0) return
            muxer.writeSampleData(trackIndex, buffer, info)
        }
    }

    fun stopAndRelease(): Boolean {
        synchronized(lock) {
            if (stopped) return false
            stopped = true
            val wroteAnything = started
            if (started) {
                runCatching { muxer.stop() }
                    .onFailure { Log.w(TAG, "Muxer stop failed", it) }
            }
            runCatching { muxer.release() }
            return wroteAnything
        }
    }

    private companion object {
        private const val TAG = "MuxerGate"
    }
}
