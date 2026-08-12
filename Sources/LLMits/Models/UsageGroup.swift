import Foundation

public struct UsageGroup: Identifiable, Codable, Equatable {
    // Stable, content-derived id (names are unique within an account) so
    // SwiftUI doesn't rebuild the whole list subtree on every refresh.
    public var id: String { name }
    public let name: String
    public let limits: [UsageLimit]

    public init(name: String, limits: [UsageLimit]) {
        self.name = name
        self.limits = limits
    }
}
