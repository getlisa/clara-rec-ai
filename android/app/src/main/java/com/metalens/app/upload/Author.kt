package com.metalens.app.upload

import android.content.Context
import com.metalens.app.settings.AppSettings
import java.text.Normalizer
import java.util.Locale

/**
 * Who an uploaded image belongs to.
 *
 * The app has no accounts, so [id] is a stable per-install identifier generated on first use.
 * [name] is an optional label the user sets in Settings; it makes the bucket readable but is
 * never the identity, because two people can pick the same name.
 */
data class Author(
    val id: String,
    val name: String,
) {
    /**
     * The S3 key prefix that separates this author's images from everyone else's.
     *
     * The id is always present, so the prefix stays unique even when two authors share a name.
     * Renaming moves future uploads to a new prefix; existing objects keep the old one, which
     * is why the id — not the name — is what identifies the author in object metadata.
     */
    val storagePrefix: String
        get() {
            val slug = slugify(name)
            return if (slug.isEmpty()) id else "$slug-$id"
        }

    private fun slugify(raw: String): String =
        // Decompose accents first, so "José" becomes "jose" rather than "jos".
        Normalizer.normalize(raw, Normalizer.Form.NFD)
            .replace(Regex("\\p{Mn}+"), "")
            .lowercase(Locale.US)
            .replace(Regex("[^a-z0-9]+"), "-")
            .trim('-')
            .take(32)
            .trim('-')
}

object AuthorIdentity {
    fun current(context: Context): Author =
        Author(
            id = AppSettings.getAuthorId(context),
            name = AppSettings.getAuthorName(context),
        )
}
