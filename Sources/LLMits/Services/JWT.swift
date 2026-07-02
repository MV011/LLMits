import Foundation

/// Minimal local JWT inspection — decodes the payload without verifying the
/// signature. Used to read expiry (`exp`) and identity claims (`email`, `sub`)
/// from CLI-issued tokens without any network calls.
enum JWT {
    static func payload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }

        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    /// The `exp` claim as a Date, if present.
    static func expiry(_ jwt: String) -> Date? {
        guard let payload = payload(jwt) else { return nil }
        let exp = (payload["exp"] as? Double) ?? (payload["exp"] as? Int).map(Double.init)
        return exp.map { Date(timeIntervalSince1970: $0) }
    }
}
