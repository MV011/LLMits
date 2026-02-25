import Foundation

struct Account: Identifiable, Codable, Hashable {
    let id: UUID
    var provider: Provider
    var displayName: String
    var tokenKeychainKey: String  // Reference to Keychain item

    init(id: UUID = UUID(), provider: Provider, displayName: String) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.tokenKeychainKey = "llmits-\(provider.rawValue)-\(id.uuidString)"
    }
}
