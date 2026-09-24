package com.metalens.app.upload

import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Minimal AWS Signature Version 4 signer, scoped to exactly what the S3 uploader needs:
 * one request, a fully buffered payload, and no query string.
 *
 * Hand-rolled rather than pulled from the AWS SDK: the SDK drags in a large transitive tree
 * (smithy-kotlin, kotlinx-serialization, its own HTTP engine) for a single PUT, while the rest
 * of this app already speaks raw OkHttp. See AwsV4SignerTest for the AWS-published test vector.
 */
object AwsV4Signer {
    private const val ALGORITHM = "AWS4-HMAC-SHA256"
    private const val TERMINATOR = "aws4_request"

    /** RFC 3986 unreserved characters — everything else in a path segment is percent-encoded. */
    private const val UNRESERVED =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"

    /**
     * Signs the request and returns the headers to add to it.
     *
     * [headers] are the extra headers to sign (content-type, x-amz-meta-*, x-amz-security-token).
     * The returned map also contains `x-amz-date`, `x-amz-content-sha256` and `Authorization`.
     * `Host` is signed but not returned, because OkHttp derives it from the URL itself.
     */
    fun sign(
        method: String,
        host: String,
        /** Raw, *unencoded* object key with no leading slash. */
        key: String,
        headers: Map<String, String>,
        payloadSha256: String,
        accessKeyId: String,
        secretAccessKey: String,
        region: String,
        service: String = "s3",
        timestamp: Date,
    ): Map<String, String> {
        val amzDate = amzDateFormat().format(timestamp)
        val dateStamp = dateStampFormat().format(timestamp)

        val signed =
            headers +
                mapOf(
                    "host" to host,
                    "x-amz-content-sha256" to payloadSha256,
                    "x-amz-date" to amzDate,
                )

        val canonical = canonicalRequest(method, key, signed, payloadSha256)
        val scope = "$dateStamp/$region/$service/$TERMINATOR"
        val stringToSign = stringToSign(amzDate, scope, canonical)

        val signingKey = signingKey(secretAccessKey, dateStamp, region, service)
        val signature = hex(hmacSha256(signingKey, stringToSign))

        val authorization =
            "$ALGORITHM Credential=$accessKeyId/$scope, " +
                "SignedHeaders=${signedHeaderNames(signed)}, " +
                "Signature=$signature"

        // Host is excluded: OkHttp sets it from the URL, and setting it twice would break the match.
        return signed.filterKeys { !it.equals("host", ignoreCase = true) } +
            mapOf("Authorization" to authorization)
    }

    internal fun canonicalRequest(
        method: String,
        key: String,
        headers: Map<String, String>,
        payloadSha256: String,
    ): String {
        val canonicalHeaders =
            headers
                .map { (name, value) -> name.lowercase(Locale.US) to normalizeHeaderValue(value) }
                .sortedBy { it.first }
                .joinToString("") { (name, value) -> "$name:$value\n" }

        return listOf(
            method,
            "/" + encodeKey(key),
            // No query string on a plain PUT Object.
            "",
            canonicalHeaders,
            signedHeaderNames(headers),
            payloadSha256,
        ).joinToString("\n")
    }

    internal fun stringToSign(
        amzDate: String,
        scope: String,
        canonicalRequest: String,
    ): String =
        listOf(
            ALGORITHM,
            amzDate,
            scope,
            sha256Hex(canonicalRequest.toByteArray(Charsets.UTF_8)),
        ).joinToString("\n")

    private fun signedHeaderNames(headers: Map<String, String>): String =
        headers.keys
            .map { it.lowercase(Locale.US) }
            .sorted()
            .joinToString(";")

    /**
     * S3 percent-encodes the object key once (unlike most services, which encode twice),
     * keeping `/` as the path separator.
     */
    internal fun encodeKey(key: String): String =
        key.split("/").joinToString("/") { segment ->
            val out = StringBuilder(segment.length)
            for (byte in segment.toByteArray(Charsets.UTF_8)) {
                val char = byte.toInt().toChar()
                if (byte >= 0 && UNRESERVED.indexOf(char) >= 0) {
                    out.append(char)
                } else {
                    out.append('%').append(String.format(Locale.US, "%02X", byte.toInt() and 0xFF))
                }
            }
            out.toString()
        }

    /** SigV4 trims the value and collapses runs of internal whitespace. */
    private fun normalizeHeaderValue(value: String): String =
        value.trim().replace(Regex("\\s+"), " ")

    private fun signingKey(
        secretAccessKey: String,
        dateStamp: String,
        region: String,
        service: String,
    ): ByteArray {
        val date = hmacSha256("AWS4$secretAccessKey".toByteArray(Charsets.UTF_8), dateStamp)
        val regional = hmacSha256(date, region)
        val serviceKey = hmacSha256(regional, service)
        return hmacSha256(serviceKey, TERMINATOR)
    }

    private fun hmacSha256(key: ByteArray, data: String): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data.toByteArray(Charsets.UTF_8))
    }

    fun sha256Hex(bytes: ByteArray): String = hex(MessageDigest.getInstance("SHA-256").digest(bytes))

    private fun hex(bytes: ByteArray): String {
        val out = StringBuilder(bytes.size * 2)
        for (byte in bytes) {
            out.append(String.format(Locale.US, "%02x", byte.toInt() and 0xFF))
        }
        return out.toString()
    }

    private fun amzDateFormat(): SimpleDateFormat =
        SimpleDateFormat("yyyyMMdd'T'HHmmss'Z'", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }

    private fun dateStampFormat(): SimpleDateFormat =
        SimpleDateFormat("yyyyMMdd", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }
}
