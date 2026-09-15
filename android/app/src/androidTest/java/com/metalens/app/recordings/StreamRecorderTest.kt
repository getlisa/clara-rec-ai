package com.metalens.app.recordings

import android.media.MediaMetadataRetriever
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.io.RandomAccessFile

@RunWith(AndroidJUnit4::class)
class StreamRecorderTest {

    @Test
    fun encodesI420FramesIntoPlayableMp4() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val file = File(context.cacheDir, "recorder_test_${System.currentTimeMillis()}.mp4")
        val width = 640
        val height = 480
        val frames = 48

        val raf = RandomAccessFile(file, "rw")
        val result =
            raf.use {
                val recorder = StreamRecorder(it.fd)
                recorder.start(width, height, FRAME_RATE, withAudio = false)
                repeat(frames) { index ->
                    recorder.encode(syntheticI420(width, height, index), width, height)
                    // Frames are timestamped from the wall clock, so pacing shapes the duration.
                    Thread.sleep(20)
                }
                recorder.stop()
            }

        assertNotNull("Recorder produced no result", result)
        requireNotNull(result)
        assertEquals(width, result.width)
        assertEquals(height, result.height)
        assertEquals(frames.toLong(), result.frameCount)
        assertTrue("Output file is empty", file.length() > 0)
        assertTrue("Duration not positive: ${result.durationMs}", result.durationMs > 0)

        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(file.absolutePath)
            assertEquals(
                width,
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toInt(),
            )
            assertEquals(
                height,
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toInt(),
            )
            val durationMs =
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLong() ?: 0L
            assertTrue("Muxed duration not positive: $durationMs", durationMs > 0)
            assertNotNull(
                "No video track in output",
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO),
            )
            assertNotNull("First frame not decodable", retriever.getFrameAtTime(0))
        } finally {
            retriever.release()
            file.delete()
        }
    }

    @Test
    fun stopWithoutFramesProducesNoFile() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val file = File(context.cacheDir, "recorder_empty_${System.currentTimeMillis()}.mp4")

        val result =
            RandomAccessFile(file, "rw").use {
                val recorder = StreamRecorder(it.fd)
                recorder.start(640, 480, FRAME_RATE, withAudio = false)
                recorder.stop()
            }

        assertEquals(null, result)
        file.delete()
    }

    private fun syntheticI420(width: Int, height: Int, index: Int): ByteArray {
        val ySize = width * height
        val chromaSize = ySize / 4
        val data = ByteArray(ySize + chromaSize * 2)

        for (row in 0 until height) {
            for (col in 0 until width) {
                data[row * width + col] = ((col + row + index * 4) and 0xFF).toByte()
            }
        }
        java.util.Arrays.fill(data, ySize, ySize + chromaSize, 128.toByte())
        java.util.Arrays.fill(data, ySize + chromaSize, data.size, 128.toByte())
        return data
    }

    private companion object {
        private const val FRAME_RATE = 24
    }
}
