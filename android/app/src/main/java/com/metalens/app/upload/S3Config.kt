package com.metalens.app.upload

import com.metalens.app.BuildConfig

/**
 * Where uploaded images go, and the credentials used to put them there.
 *
 * Values come from `android/local.properties` (not committed) via BuildConfig, the same route
 * the OpenAI key already takes.
 *
 * NOTE: credentials compiled into an APK are readable by anyone who has the APK. The IAM user
 * behind these keys should be able to do nothing except `s3:PutObject` into this one bucket —
 * see the "Image upload to S3" section of android/README.md.
 */
data class S3Config(
    val bucket: String,
    val region: String,
    val accessKeyId: String,
    val secretAccessKey: String,
    val sessionToken: String,
    /** Key prefix all uploads live under, e.g. "photos". */
    val rootPrefix: String = "photos",
) {
    val isConfigured: Boolean
        get() = bucket.isNotBlank() && region.isNotBlank() &&
            accessKeyId.isNotBlank() && secretAccessKey.isNotBlank()

    /**
     * Virtual-hosted-style endpoint host.
     *
     * Buckets whose name contains a dot break TLS certificate matching on this style, so those
     * are rejected up front rather than failing later with an opaque handshake error.
     */
    val host: String
        get() = "$bucket.s3.$region.amazonaws.com"

    val hasDotInBucketName: Boolean
        get() = bucket.contains('.')

    companion object {
        fun fromBuildConfig(): S3Config =
            S3Config(
                bucket = BuildConfig.S3_BUCKET.trim(),
                region = BuildConfig.AWS_REGION.trim().ifBlank { "us-east-1" },
                accessKeyId = BuildConfig.AWS_ACCESS_KEY_ID.trim(),
                secretAccessKey = BuildConfig.AWS_SECRET_ACCESS_KEY.trim(),
                sessionToken = BuildConfig.AWS_SESSION_TOKEN.trim(),
            )
    }
}
