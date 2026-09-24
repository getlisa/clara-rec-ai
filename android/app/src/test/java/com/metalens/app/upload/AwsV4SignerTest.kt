package com.metalens.app.upload

import org.junit.Assert.assertEquals
import org.junit.Test
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * A wrong signature shows up only as an opaque S3 403, so the signer is pinned to known-good
 * vectors: the first is AWS's own published "PUT Object" example, the rest were produced with
 * botocore (the implementation behind the AWS CLI).
 */
class AwsV4SignerTest {
    private val accessKeyId = "AKIAIOSFODNN7EXAMPLE"
    private val secretAccessKey = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

    private fun at(amzDate: String): Date =
        SimpleDateFormat("yyyyMMdd'T'HHmmss'Z'", Locale.US)
            .apply { timeZone = TimeZone.getTimeZone("UTC") }
            .parse(amzDate)!!

    private fun signatureOf(headers: Map<String, String>): String =
        headers.getValue("Authorization").substringAfter("Signature=")

    /** AWS docs, "Signature Calculation: Transfer Payload in a Single Chunk" — PUT Object. */
    @Test
    fun `matches the AWS published PUT Object example`() {
        val signed =
            AwsV4Signer.sign(
                method = "PUT",
                host = "examplebucket.s3.amazonaws.com",
                key = "test\$file.text",
                headers =
                    mapOf(
                        "date" to "Fri, 24 May 2013 00:00:00 GMT",
                        "x-amz-storage-class" to "REDUCED_REDUNDANCY",
                    ),
                payloadSha256 = "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072",
                accessKeyId = accessKeyId,
                secretAccessKey = secretAccessKey,
                region = "us-east-1",
                timestamp = at("20130524T000000Z"),
            )

        assertEquals(
            "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd",
            signatureOf(signed),
        )
        assertEquals(
            "AWS4-HMAC-SHA256 Credential=$accessKeyId/20130524/us-east-1/s3/aws4_request, " +
                "SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class, " +
                "Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd",
            signed.getValue("Authorization"),
        )
    }

    /** The shape this app actually sends: JPEG body plus author metadata. */
    @Test
    fun `matches botocore for an author-scoped image upload`() {
        val signed =
            AwsV4Signer.sign(
                method = "PUT",
                host = "examplebucket.s3.us-east-1.amazonaws.com",
                key = "photos/alice-a1b2c3d4/2026/09/22/1758499200000-abcd1234.jpg",
                headers =
                    mapOf(
                        "Content-Type" to "image/jpeg",
                        "x-amz-meta-author-id" to "a1b2c3d4",
                        "x-amz-meta-author-name" to "alice",
                    ),
                // sha256("hello clara")
                payloadSha256 = "c0e9785f45dc3c96075fd042a3aa164e9304860357166055de3567906bd4a59e",
                accessKeyId = accessKeyId,
                secretAccessKey = secretAccessKey,
                region = "us-east-1",
                timestamp = at("20260922T000000Z"),
            )

        assertEquals(
            "2aa3664d708e72ffa4eb6a3a36319d960e6445e34251ca08cc6713276828dc73",
            signatureOf(signed),
        )
    }

    /** Temporary STS credentials, and an author name that forces percent-encoding in the key. */
    @Test
    fun `matches botocore with a session token and an escaped key`() {
        val signed =
            AwsV4Signer.sign(
                method = "PUT",
                host = "examplebucket.s3.eu-west-1.amazonaws.com",
                key = "photos/bob smith-ff00/2026/09/22/pic (1).jpg",
                headers =
                    mapOf(
                        "Content-Type" to "image/jpeg",
                        "x-amz-security-token" to "FQoGZXIvYXdzEXAMPLETOKEN",
                        "x-amz-meta-author-id" to "ff00",
                    ),
                // sha256("x")
                payloadSha256 = "2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881",
                accessKeyId = accessKeyId,
                secretAccessKey = secretAccessKey,
                region = "eu-west-1",
                timestamp = at("20260922T000000Z"),
            )

        assertEquals(
            "8b33847dd71f3e48310f04e85babab4d53af22388b58fec3519c22b0a514d496",
            signatureOf(signed),
        )
    }

    @Test
    fun `host is signed but left for OkHttp to set`() {
        val signed =
            AwsV4Signer.sign(
                method = "PUT",
                host = "examplebucket.s3.us-east-1.amazonaws.com",
                key = "photos/a/b.jpg",
                headers = mapOf("Content-Type" to "image/jpeg"),
                payloadSha256 = "c0e9785f45dc3c96075fd042a3aa164e9304860357166055de3567906bd4a59e",
                accessKeyId = accessKeyId,
                secretAccessKey = secretAccessKey,
                region = "us-east-1",
                timestamp = at("20260922T000000Z"),
            )

        assertEquals(false, signed.keys.any { it.equals("host", ignoreCase = true) })
        assertEquals("20260922T000000Z", signed.getValue("x-amz-date"))
        assertEquals(true, signed.getValue("Authorization").contains("SignedHeaders=content-type;host;"))
    }

    @Test
    fun `keys are percent-encoded once, keeping slashes`() {
        assertEquals("photos/a-b/c.jpg", AwsV4Signer.encodeKey("photos/a-b/c.jpg"))
        assertEquals("test%24file.text", AwsV4Signer.encodeKey("test\$file.text"))
        assertEquals("a%20b/c%20%281%29.jpg", AwsV4Signer.encodeKey("a b/c (1).jpg"))
        // Already-encoded input must not be double-encoded into %2520.
        assertEquals("a%2Bb", AwsV4Signer.encodeKey("a+b"))
        // Multi-byte UTF-8.
        assertEquals("caf%C3%A9.jpg", AwsV4Signer.encodeKey("café.jpg"))
    }
}
