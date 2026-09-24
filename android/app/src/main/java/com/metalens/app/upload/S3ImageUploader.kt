package com.metalens.app.upload

import android.graphics.Bitmap
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.ByteArrayOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.TimeUnit

/**
 * Uploads a captured photo to S3 with a single signed PUT.
 *
 * Mirrors [com.metalens.app.pictureanalysis.OpenAIImageAnalysisService]: raw OkHttp, no SDK.
 */
class S3ImageUploader(
    private val client: OkHttpClient = defaultClient(),
) {
    companion object {
        private const val JPEG_QUALITY = 90
        private val JPEG = "image/jpeg".toMediaType()

        private fun defaultClient(): OkHttpClient =
            OkHttpClient.Builder()
                .callTimeout(60, TimeUnit.SECONDS)
                .connectTimeout(15, TimeUnit.SECONDS)
                .readTimeout(30, TimeUnit.SECONDS)
                .writeTimeout(60, TimeUnit.SECONDS)
                .build()
    }

    data class Upload(
        val key: String,
        val bucket: String,
        val sizeBytes: Int,
    ) {
        val uri: String get() = "s3://$bucket/$key"
    }

    fun upload(
        config: S3Config,
        author: Author,
        bitmap: Bitmap,
        capturedAt: Date = Date(),
    ): Result<Upload> {
        if (!config.isConfigured) {
            return Result.failure(IllegalStateException("S3 is not configured"))
        }
        if (config.hasDotInBucketName) {
            return Result.failure(
                IllegalStateException(
                    "Bucket name contains a dot, which breaks HTTPS for virtual-hosted-style S3 URLs",
                ),
            )
        }

        return runCatching {
            val jpeg = bitmap.toJpegBytes(JPEG_QUALITY)
            val payloadSha256 = AwsV4Signer.sha256Hex(jpeg)
            val key = objectKey(config, author, capturedAt, payloadSha256)

            val metadata =
                buildMap {
                    put("content-type", "image/jpeg")
                    put("x-amz-meta-author-id", author.id)
                    asciiOrNull(author.name)?.let { put("x-amz-meta-author-name", it) }
                    put("x-amz-meta-captured-at", iso8601().format(capturedAt))
                    put("x-amz-meta-source", "clara-assistant-android")
                    if (config.sessionToken.isNotBlank()) {
                        put("x-amz-security-token", config.sessionToken)
                    }
                }

            val signedHeaders =
                AwsV4Signer.sign(
                    method = "PUT",
                    host = config.host,
                    key = key,
                    headers = metadata,
                    payloadSha256 = payloadSha256,
                    accessKeyId = config.accessKeyId,
                    secretAccessKey = config.secretAccessKey,
                    region = config.region,
                    timestamp = Date(),
                )

            val builder =
                Request.Builder()
                    .url("https://${config.host}/${AwsV4Signer.encodeKey(key)}")
                    .put(jpeg.toRequestBody(JPEG))
            signedHeaders.forEach { (name, value) -> builder.header(name, value) }

            client.newCall(builder.build()).execute().use { response ->
                if (!response.isSuccessful) {
                    throw IllegalStateException(describeError(response.code, response.body?.string()))
                }
                Upload(key = key, bucket = config.bucket, sizeBytes = jpeg.size)
            }
        }
    }

    /**
     * `photos/<author>/<yyyy>/<MM>/<dd>/<yyyyMMdd-HHmmss>-<content hash>.jpg`
     *
     * The author prefix keeps each person's images separate; the content hash suffix means the
     * very same photo re-uploaded within a second lands on the same key instead of duplicating.
     */
    private fun objectKey(
        config: S3Config,
        author: Author,
        capturedAt: Date,
        payloadSha256: String,
    ): String {
        val day = dayFormat().format(capturedAt)
        val stamp = stampFormat().format(capturedAt)
        return "${config.rootPrefix}/${author.storagePrefix}/$day/$stamp-${payloadSha256.take(12)}.jpg"
    }

    private fun describeError(code: Int, body: String?): String {
        val s3Code = body?.let { Regex("<Code>(.*?)</Code>").find(it)?.groupValues?.get(1) }
        return when {
            !s3Code.isNullOrBlank() -> "S3 $s3Code (HTTP $code)"
            code == 403 -> "S3 rejected the credentials (HTTP 403)"
            else -> "S3 upload failed (HTTP $code)"
        }
    }

    /**
     * S3 user metadata must be US-ASCII, and OkHttp refuses header values outside printable
     * ASCII, so anything else is dropped rather than failing the upload.
     */
    private fun asciiOrNull(raw: String): String? =
        raw.trim()
            .filter { it.code in 0x20..0x7E }
            .trim()
            .take(128)
            .ifBlank { null }

    private fun dayFormat() = utcFormat("yyyy/MM/dd")

    private fun stampFormat() = utcFormat("yyyyMMdd-HHmmss")

    private fun iso8601() = utcFormat("yyyy-MM-dd'T'HH:mm:ss'Z'")

    private fun utcFormat(pattern: String) =
        SimpleDateFormat(pattern, Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }
}

private fun Bitmap.toJpegBytes(quality: Int): ByteArray {
    val out = ByteArrayOutputStream()
    if (!compress(Bitmap.CompressFormat.JPEG, quality.coerceIn(1, 100), out)) {
        throw IllegalStateException("Failed to encode JPEG")
    }
    return out.toByteArray()
}
