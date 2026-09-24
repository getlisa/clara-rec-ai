package com.metalens.app.upload

import org.junit.Assert.assertEquals
import org.junit.Test

class AuthorTest {
    @Test
    fun `prefix falls back to the id when no name is set`() {
        assertEquals("a1b2c3d4", Author(id = "a1b2c3d4", name = "").storagePrefix)
        assertEquals("a1b2c3d4", Author(id = "a1b2c3d4", name = "   ").storagePrefix)
    }

    @Test
    fun `prefix keeps the id so identical names never collide`() {
        val shivam = Author(id = "a1b2c3d4", name = "Shivam")
        val otherShivam = Author(id = "99887766", name = "Shivam")

        assertEquals("shivam-a1b2c3d4", shivam.storagePrefix)
        assertEquals("shivam-99887766", otherShivam.storagePrefix)
    }

    @Test
    fun `names are slugified into something S3-safe`() {
        assertEquals("bob-smith-ff00", Author(id = "ff00", name = "Bob  Smith").storagePrefix)
        assertEquals("a-b-ff00", Author(id = "ff00", name = "  a/b  ").storagePrefix)
        assertEquals("jose-ff00", Author(id = "ff00", name = "José").storagePrefix)
        // A name made entirely of punctuation slugifies away, leaving the id alone.
        assertEquals("ff00", Author(id = "ff00", name = "!!!").storagePrefix)
    }

    @Test
    fun `very long names are truncated without a trailing separator`() {
        val prefix = Author(id = "ff00", name = "x".repeat(80)).storagePrefix
        assertEquals("${"x".repeat(32)}-ff00", prefix)

        val trailing = Author(id = "ff00", name = "${"y".repeat(32)} tail").storagePrefix
        assertEquals("${"y".repeat(32)}-ff00", trailing)

        // Truncating right after a separator must not leave "name--id".
        val cutAtSeparator = Author(id = "ff00", name = "${"z".repeat(31)} tail").storagePrefix
        assertEquals("${"z".repeat(31)}-ff00", cutAtSeparator)
    }
}
