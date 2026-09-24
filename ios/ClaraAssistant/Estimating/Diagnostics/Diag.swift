import Foundation

/// Debug-only mirror of the app's own log lines to stderr.
///
/// `os.Logger` writes to the unified log, which needs USB (`idevicesyslog`) to read off a device —
/// and modern macOS dropped `log stream --device`. When the phone is paired over Wi-Fi the only
/// stream available is `devicectl … --console`, which carries stdout/stderr and nothing else.
///
/// So this exists purely so a Wi-Fi-attached console shows what the app is doing. It compiles to
/// nothing in Release: a shipped binary must not narrate its network calls.
enum Diag {
    /// Distinctive so it can be grepped out of the framework chatter the console is full of.
    private static let marker = "CLARA»"

    static func log(_ category: String, _ message: @autoclosure () -> String) {
        #if DEBUG
        let line = "\(marker) [\(category)] \(message())\n"
        FileHandle.standardError.write(Data(line.utf8))
        #endif
    }

    /// Never logs the token itself — just enough to tell "present and plausible" from "missing".
    static func token(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "none" }
        return "\(value.prefix(6))…(\(value.count) chars)"
    }

    /// Emails are personal data; enough to confirm which account without printing it whole.
    static func redact(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@") else { return "***" }
        return "\(email.prefix(2))***\(email[at...])"
    }
}
