import Foundation

protocol UsageService {
    func fetchUsage(token: String) async throws -> [UsageGroup]
}
