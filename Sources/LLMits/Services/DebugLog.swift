import Foundation

/// File-based debug logger that works for GUI apps.
/// Writes to /tmp/llmits_debug.log when the file exists.
func debugLog(_ msg: String) {
    let logPath = "/tmp/llmits_debug.log"
    guard FileManager.default.fileExists(atPath: logPath) else { return }

    // Redact sensitive tokens from log output
    let sanitized = redactTokens(msg)
    let line = "\(Date()): \(sanitized)\n"

    guard let data = line.data(using: .utf8),
          let fh = FileHandle(forWritingAtPath: logPath) else { return }
    fh.seekToEndOfFile()
    fh.write(data)
    fh.closeFile()
}

/// Strips token values from log messages, keeping only the first 6 chars.
private func redactTokens(_ msg: String) -> String {
    var result = msg

    // Redact "token=XXX" patterns (keeping first 6 chars)
    let tokenPatterns = [
        (try? NSRegularExpression(pattern: #"token=([A-Za-z0-9_\-\.]{10,})"#)),
        (try? NSRegularExpression(pattern: #"Bearer ([A-Za-z0-9_\-\.]{10,})"#)),
    ]

    for regex in tokenPatterns.compactMap({ $0 }) {
        let range = NSRange(result.startIndex..., in: result)
        let matches = regex.matches(in: result, range: range).reversed()
        for match in matches {
            if let tokenRange = Range(match.range(at: 1), in: result) {
                let token = String(result[tokenRange])
                result.replaceSubrange(tokenRange, with: "\(token.prefix(6))…[redacted]")
            }
        }
    }

    return result
}
