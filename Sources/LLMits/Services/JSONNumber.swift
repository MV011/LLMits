import Foundation

/// Coerces the mixed number encodings provider APIs actually send:
/// `100`, `100.0`, `"100"`, `{ "val": 100 }`.
enum JSONNumber {
    static func double(from value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        case let dict as [String: Any]:
            return double(from: dict["val"] ?? dict["value"])
        default:
            return nil
        }
    }
}
