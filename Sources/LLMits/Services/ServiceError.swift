import Foundation

enum ServiceError: LocalizedError {
    case noCredentials(String)
    case httpError(Int)
    case invalidResponse
    case parseError(String)
    case processNotFound(String)

    var errorDescription: String? {
        switch self {
        case .noCredentials(let msg): return msg
        case .httpError(let code): return "HTTP \(code)"
        case .invalidResponse: return "Invalid response"
        case .parseError(let msg): return msg
        case .processNotFound(let msg): return msg
        }
    }
}
