import Foundation

/// Who an uploaded image belongs to.
///
/// The app has no accounts, so `id` is a stable per-install identifier generated on first use.
/// `name` is an optional label the user sets in Settings; it makes the bucket readable but is
/// never the identity, because two people can pick the same name.
///
/// Mirrors the Android `com.metalens.app.upload.Author` so both platforms write the same layout.
struct Author: Equatable {
    let id: String
    let name: String

    /// The S3 key prefix that separates this author's images from everyone else's.
    ///
    /// The id is always present, so the prefix stays unique even when two authors share a name.
    /// Renaming moves future uploads to a new prefix; existing objects keep the old one, which
    /// is why the id — not the name — is what identifies the author in object metadata.
    var storagePrefix: String {
        let slug = Self.slugify(name)
        return slug.isEmpty ? id : "\(slug)-\(id)"
    }

    static func slugify(_ raw: String) -> String {
        // Fold accents first, so "José" becomes "jose" rather than "jos".
        let folded = raw.folding(
            options: [.diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()

        var out = ""
        var pendingSeparator = false
        for character in folded {
            if character.isASCII, character.isLetter || character.isNumber {
                if pendingSeparator, !out.isEmpty { out.append("-") }
                pendingSeparator = false
                out.append(character)
            } else {
                pendingSeparator = true
            }
        }

        // Truncation can land straight after a separator, which would leave "name--id".
        var truncated = String(out.prefix(32))
        while truncated.hasSuffix("-") { truncated.removeLast() }
        return truncated
    }
}

enum AuthorIdentity {
    private static let idKey = "authorId"
    private static let nameKey = "authorName"

    static var current: Author {
        Author(id: id, name: name)
    }

    /// Generated once, on first read, and then kept for the lifetime of the install.
    static var id: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: idKey), !existing.isEmpty {
            return existing
        }
        let generated = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
            .lowercased()
        defaults.set(generated, forKey: idKey)
        return generated
    }

    static var name: String {
        get {
            UserDefaults.standard.string(forKey: nameKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        set {
            let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.isEmpty {
                UserDefaults.standard.removeObject(forKey: nameKey)
            } else {
                UserDefaults.standard.set(normalized, forKey: nameKey)
            }
        }
    }

    static let nameDefaultsKey = nameKey
}
