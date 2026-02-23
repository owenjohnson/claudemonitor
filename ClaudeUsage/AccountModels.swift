import Foundation

/// Persisted account metadata stored in UserDefaults.
/// Email is the canonical identity key for deduplication across token rotations.
struct AccountRecord: Codable, Identifiable {
    let email: String
    var displayName: String?
    var organizationName: String?
    var subscriptionType: String?
    var tokenExpiresAt: Date?
    var lastTokenCapturedAt: Date
    var addedAt: Date

    var id: String { email }
}

/// In-memory view model combining an AccountRecord with live fetch state.
/// Not persisted — rebuilt each refresh cycle.
struct AccountUsage: Identifiable {
    let account: AccountRecord
    var usage: UsageData?
    var error: String?
    var isLoading: Bool
    var lastUpdated: Date?
    /// True if this account holds the live keychain token.
    var isCurrentAccount: Bool

    var id: String { account.email }
}
