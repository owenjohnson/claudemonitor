import Foundation
import Security

struct UsageData {
    let sessionUtilization: Double
    let sessionResetsAt: Date?
    let weeklyUtilization: Double
    let weeklyResetsAt: Date?
    let sonnetUtilization: Double?
    let sonnetResetsAt: Date?

    var sessionPercentage: Int { Int(sessionUtilization.rounded()) }
    var weeklyPercentage: Int { Int(weeklyUtilization.rounded()) }
    var sonnetPercentage: Int? { sonnetUtilization.map { Int($0.rounded()) } }

    /// Single source of truth for worst-case utilization across all categories (D4).
    /// Includes sonnet when available — intentional behavioral change per ADR-002 D4.
    var bottleneck: (percentage: Int, category: String) {
        var worst = (percentage: sessionPercentage, category: "Session")
        if weeklyPercentage > worst.percentage {
            worst = (percentage: weeklyPercentage, category: "Weekly")
        }
        if let sonnet = sonnetPercentage, sonnet > worst.percentage {
            worst = (percentage: sonnet, category: "Sonnet")
        }
        return worst
    }
}

@MainActor
class UsageManager: ObservableObject {
    /// All known accounts with their current fetch state. Replaces the five individual
    /// @Published vars (usage, error, isLoading, lastUpdated, displayName) from v1.7.
    @Published var accounts: [AccountUsage] = []

    @Published var updateAvailable: String?

    /// Error to display when no accounts exist (e.g., not logged in).
    /// Cleared on successful token acquisition. Surfaced via the `error` convenience accessor.
    @Published private(set) var noAccountError: String?

    /// In-memory token from the last successful keychain read.
    /// Used to detect account switches without calling the profile API on every poll.
    private var lastSeenToken: String?

    /// In-memory cache of access tokens by email. Tokens remain valid after being
    /// overwritten in the keychain; we keep using them until a 401 evicts them.
    /// Never persisted to disk.
    private var tokenCache: [String: String] = [:]

    /// Guard to prevent overlapping refresh cycles (B2).
    private var isRefreshing = false

    static let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    static let githubRepo = "richhickson/claudecodeusage"

    private static let accountsDefaultsKey = "claudeusage.accounts"

    // Configured URLSession with timeouts
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    // MARK: - Convenience accessors (single-account compatibility for UsageView/AppDelegate)

    /// The current (live) account's usage, or nil if no live account is loaded yet.
    var usage: UsageData? {
        accounts.first(where: { $0.isCurrentAccount })?.usage
    }

    /// The current account's error string, or nil.
    /// Falls back to noAccountError when no live account exists (D1).
    var error: String? {
        accounts.first(where: { $0.isCurrentAccount })?.error ?? noAccountError
    }

    /// True while the live account is loading.
    var isLoading: Bool {
        accounts.first(where: { $0.isCurrentAccount })?.isLoading ?? false
    }

    /// Last update timestamp for the live account.
    var lastUpdated: Date? {
        accounts.first(where: { $0.isCurrentAccount })?.lastUpdated
    }

    /// Display name for the live account.
    var displayName: String? {
        accounts.first(where: { $0.isCurrentAccount })?.account.displayName
    }

    /// Worst-case utilization emoji across live and actively-refreshing accounts (stale excluded).
    /// Uses bottleneck.percentage (D4) — includes sonnet utilization in the comparison.
    var statusEmoji: String {
        let activeAccounts = accounts.filter { $0.isCurrentAccount || $0.isActivelyRefreshing }
        guard !activeAccounts.isEmpty else { return "❓" }
        let maxUtil = activeAccounts.compactMap { $0.usage }.map { $0.bottleneck.percentage }.max() ?? 0
        if maxUtil >= 90 { return "🔴" }
        if maxUtil >= 70 { return "🟡" }
        return "🟢"
    }

    /// Worst-case utilization percentage across live and actively-refreshing accounts (stale excluded).
    /// Uses bottleneck.percentage (D4) — includes sonnet utilization in the comparison.
    var worstCaseUtilization: Int? {
        let activeAccounts = accounts.filter { $0.isCurrentAccount || $0.isActivelyRefreshing }
        guard !activeAccounts.isEmpty else { return nil }
        return activeAccounts.compactMap { $0.usage }.map { $0.bottleneck.percentage }.max()
    }

    // MARK: - Refresh

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await refreshWithRetry(retriesRemaining: 3)
    }

    /// Loop-based retry (B-pre: replaces recursive pattern that skipped loading-state reset on retry paths).
    private func refreshWithRetry(retriesRemaining: Int) async {
        var attemptsLeft = retriesRemaining

        while true {
            do {
                let (token, tokenChanged) = try await getAccessTokenWithChangeDetection()

                if tokenChanged {
                    await updateAccountRecord(for: token)
                }

                await refreshAllAccounts(liveToken: token)
                return
            } catch let keychainError as KeychainError {
                if attemptsLeft > 0 && keychainError.isRetryable {
                    attemptsLeft -= 1
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                publishLiveAccountUpdate(usage: nil, error: keychainError.localizedDescription)
                return
            } catch {
                publishLiveAccountUpdate(usage: nil, error: error.localizedDescription)
                return
            }
        }
    }

    /// Refresh all accounts using TaskGroup for concurrent per-account fetches (B4/B5).
    /// Live account: fetch usage with the current keychain token.
    /// Cached accounts: fetch usage with their cached token; evict on 401.
    /// Stale accounts (no token): keep last-known data.
    private func refreshAllAccounts(liveToken: String) async {
        noAccountError = nil  // Clear no-account error on successful token acquisition (D1)

        // Snapshot tokenCache before entering TaskGroup for @Sendable safety
        let cachedTokens = tokenCache

        // Set loading state for all accounts that have a token
        for index in accounts.indices {
            let email = accounts[index].account.email
            if accounts[index].isCurrentAccount || cachedTokens[email] != nil {
                accounts[index].isLoading = true
                if accounts[index].isCurrentAccount {
                    accounts[index].error = nil
                }
            }
        }

        let session = urlSession
        let version = Self.currentVersion

        // 4-tuple: email, usage, error, tokenExpired
        await withTaskGroup(of: (String, UsageData?, String?, Bool).self) { group in
            for account in accounts {
                let email = account.account.email
                let isCurrent = account.isCurrentAccount
                let token: String? = isCurrent ? liveToken : cachedTokens[email]

                group.addTask {
                    guard let token = token else {
                        // Truly stale: no token available, preserve last-known data
                        return (email, nil, nil, false)
                    }
                    do {
                        let usage = try await Self.fetchUsage(
                            token: token, session: session, version: version
                        )
                        return (email, usage, nil, false)
                    } catch let error as UsageError {
                        if case .apiError(let code) = error, code == 401 {
                            return (email, nil, error.localizedDescription, true)
                        }
                        return (email, nil, error.localizedDescription, false)
                    } catch {
                        return (email, nil, error.localizedDescription, false)
                    }
                }
            }

            // Collect results back on @MainActor
            for await (email, usage, error, tokenExpired) in group {
                guard let index = accounts.firstIndex(where: { $0.account.email == email }) else { continue }

                if tokenExpired && !accounts[index].isCurrentAccount {
                    // Evict expired cached token; account becomes truly stale
                    tokenCache.removeValue(forKey: email)
                    accounts[index].hasCachedToken = false
                    accounts[index].error = "Token expired — switch to this account to refresh"
                    accounts[index].isLoading = false
                    continue
                }

                let hadToken = accounts[index].isCurrentAccount || cachedTokens[email] != nil
                if hadToken {
                    accounts[index].usage = usage ?? accounts[index].usage
                    accounts[index].error = error
                    accounts[index].lastUpdated = usage != nil ? Date() : accounts[index].lastUpdated
                    accounts[index].isLoading = false
                }
            }
        }

        // Sync hasCachedToken flags after refresh
        syncCachedTokenFlags()
    }

    // MARK: - accounts array helpers

    private func setCurrentAccountLoading(_ loading: Bool) {
        if let index = accounts.firstIndex(where: { $0.isCurrentAccount }) {
            accounts[index].isLoading = loading
        }
    }

    private func clearCurrentAccountError() {
        if let index = accounts.firstIndex(where: { $0.isCurrentAccount }) {
            accounts[index].error = nil
        }
    }

    private func publishLiveAccountUpdate(usage: UsageData?, error: String?) {
        if let index = accounts.firstIndex(where: { $0.isCurrentAccount }) {
            accounts[index].usage = usage
            accounts[index].error = error
            accounts[index].lastUpdated = usage != nil ? Date() : accounts[index].lastUpdated
            accounts[index].isLoading = false
        } else if let errorMsg = error {
            // No live account in array (e.g., not logged in): surface error via
            // noAccountError so the convenience accessor and UI pick it up (D1).
            noAccountError = errorMsg
        }
    }

    /// Rebuild the in-memory accounts array from persisted records after a successful
    /// profile fetch, marking the new current account as live and all others as stale.
    private func rebuildAccountsFromRecords(currentEmail: String) {
        let records = loadAccounts()
        var updated: [AccountUsage] = []

        for record in records {
            let isCurrent = record.email == currentEmail
            if isCurrent {
                // Preserve existing live account data if already present
                if let existing = accounts.first(where: { $0.account.email == record.email }) {
                    var au = existing
                    au.isCurrentAccount = true
                    updated.append(au)
                } else {
                    updated.append(AccountUsage(
                        account: record,
                        usage: nil,
                        error: nil,
                        isLoading: true,
                        lastUpdated: nil,
                        isCurrentAccount: true
                    ))
                }
            } else {
                // Preserve stale account's last-known data
                if let existing = accounts.first(where: { $0.account.email == record.email }) {
                    var au = existing
                    au.isCurrentAccount = false
                    updated.append(au)
                } else {
                    updated.append(AccountUsage(
                        account: record,
                        usage: nil,
                        error: nil,
                        isLoading: false,
                        lastUpdated: nil,
                        isCurrentAccount: false
                    ))
                }
            }
        }

        accounts = updated
        syncCachedTokenFlags()
    }

    /// Sync hasCachedToken on each AccountUsage from the in-memory tokenCache.
    private func syncCachedTokenFlags() {
        for index in accounts.indices {
            accounts[index].hasCachedToken = tokenCache[accounts[index].account.email] != nil
        }
    }

    // MARK: - Token detection

    private func getAccessTokenWithChangeDetection() async throws -> (token: String, tokenChanged: Bool) {
        let token = try await getClaudeCodeToken()
        let changed = token != lastSeenToken
        if changed {
            lastSeenToken = token
        }
        return (token, changed)
    }

    // MARK: - Keychain reading

    /// Read raw JSON string from the keychain using the security CLI.
    /// Runs off @MainActor via nonisolated + terminationHandler to avoid blocking the main thread.
    private nonisolated func readKeychainRawJSON(service: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["find-generic-password", "-s", service, "-w"]
            process.standardOutput = pipe
            process.standardError = errorPipe
            process.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorString = String(data: errorData, encoding: .utf8) ?? ""
                guard proc.terminationStatus == 0 else {
                    if errorString.contains("could not be found") {
                        continuation.resume(throwing: KeychainError.notLoggedIn)
                    } else {
                        continuation.resume(throwing: KeychainError.securityCommandFailed(
                            errorString.isEmpty ? "Exit code \(proc.terminationStatus)" : errorString
                        ))
                    }
                    return
                }
                guard let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !result.isEmpty else {
                    continuation.resume(throwing: KeychainError.notLoggedIn)
                    return
                }
                continuation.resume(returning: result)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: KeychainError.unexpectedError(status: -1))
            }
        }
    }

    /// Get token from Claude Code's keychain using security CLI (avoids ACL prompt!)
    private func getClaudeCodeToken() async throws -> String {
        let jsonString: String
        do {
            jsonString = try await readKeychainRawJSON(service: "Claude Code-credentials")
        } catch KeychainError.notLoggedIn, KeychainError.securityCommandFailed {
            if let token = try? await getAccessTokenFromAlternateKeychain() {
                return token
            }
            throw KeychainError.notLoggedIn
        }

        if let jsonData = jsonString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            if let oauth = json["claudeAiOauth"] as? [String: Any],
               let accessToken = oauth["accessToken"] as? String {
                return accessToken
            }
            let keys = Array(json.keys).joined(separator: ", ")
            if let token = try? await getAccessTokenFromAlternateKeychain() {
                return token
            }
            throw KeychainError.missingOAuthToken(availableKeys: keys)
        }

        if let token = try? await getAccessTokenFromAlternateKeychain() {
            return token
        }

        throw KeychainError.invalidCredentialFormat
    }

    /// Fallback: Check for "Claude Code" keychain entry (alternate storage location)
    private func getAccessTokenFromAlternateKeychain() async throws -> String {
        let jsonString = try await readKeychainRawJSON(service: "Claude Code")

        guard let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String else {
            throw KeychainError.notLoggedIn
        }

        return accessToken
    }

    /// Extract the accessToken string from raw keychain JSON without throwing.
    nonisolated func extractAccessToken(from rawJSON: String) -> String? {
        guard let jsonData = rawJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String else {
            return nil
        }
        return accessToken
    }

    // MARK: - UserDefaults Persistence (A2)

    /// Load persisted account records from UserDefaults. Returns empty array on fresh install.
    func loadAccounts() -> [AccountRecord] {
        guard let data = UserDefaults.standard.data(forKey: Self.accountsDefaultsKey),
              let records = try? JSONDecoder().decode([AccountRecord].self, from: data) else {
            return []
        }
        return records
    }

    /// Persist account records to UserDefaults.
    func saveAccounts(_ records: [AccountRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: Self.accountsDefaultsKey)
    }

    /// Remove a stale account by email from UserDefaults and the in-memory accounts array (C12).
    /// Only non-current accounts may be removed. Removal persists across relaunches.
    func removeAccount(email: String) {
        // Guard: do not remove the live account
        guard accounts.first(where: { $0.account.email == email })?.isCurrentAccount != true else { return }
        tokenCache.removeValue(forKey: email)
        var records = loadAccounts()
        records.removeAll { $0.email == email }
        saveAccounts(records)
        accounts.removeAll { $0.account.email == email }
    }

    // MARK: - Network: Usage

    /// Nonisolated static usage fetch for TaskGroup compatibility (B1/B4).
    /// Takes dependencies as parameters instead of accessing @MainActor self.
    private nonisolated static func fetchUsage(
        token: String, session: URLSession, version: String
    ) async throws -> UsageData {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ClaudeUsage/\(version)", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw UsageError.apiError(statusCode: httpResponse.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.invalidResponse
        }

        let fiveHour = json["five_hour"] as? [String: Any]
        let sevenDay = json["seven_day"] as? [String: Any]
        let sonnetOnly = json["sonnet_only"] as? [String: Any]

        return UsageData(
            sessionUtilization: fiveHour?["utilization"] as? Double ?? 0,
            sessionResetsAt: parseDate(fiveHour?["resets_at"] as? String),
            weeklyUtilization: sevenDay?["utilization"] as? Double ?? 0,
            weeklyResetsAt: parseDate(sevenDay?["resets_at"] as? String),
            sonnetUtilization: sonnetOnly?["utilization"] as? Double,
            sonnetResetsAt: parseDate(sonnetOnly?["resets_at"] as? String)
        )
    }

    // MARK: - Network: Profile

    /// Structured profile data returned from the OAuth profile endpoint.
    struct ProfileData {
        let email: String
        let displayName: String?
        let organizationName: String?
        let subscriptionType: String?
    }

    /// Fetch full profile data from /api/oauth/profile. Returns nil on non-200 responses.
    private func fetchProfileData(token: String) async throws -> ProfileData? {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accountDict = json["account"] as? [String: Any],
              let email = accountDict["email"] as? String else {
            return nil
        }

        let displayName = accountDict["display_name"] as? String ?? accountDict["full_name"] as? String
        let org = json["organization"] as? [String: Any]
        let organizationName = org?["name"] as? String
        let subscriptionType = accountDict["subscription_type"] as? String

        return ProfileData(
            email: email,
            displayName: displayName,
            organizationName: organizationName,
            subscriptionType: subscriptionType
        )
    }

    // MARK: - Account record management (A6)

    /// Create or update an AccountRecord in UserDefaults when a token change is detected.
    /// Also rebuilds the in-memory `accounts` array with the new current account marked live.
    /// Caches the token in memory so we can keep refreshing this account after a switch.
    @discardableResult
    private func updateAccountRecord(for token: String) async -> String? {
        guard let profile = try? await fetchProfileData(token: token) else { return nil }

        // Cache the token for this account (stays valid even after keychain overwrite)
        tokenCache[profile.email] = token

        var records = loadAccounts()
        let now = Date()

        if let index = records.firstIndex(where: { $0.email == profile.email }) {
            records[index].displayName = profile.displayName
            records[index].organizationName = profile.organizationName
            records[index].subscriptionType = profile.subscriptionType
            records[index].lastTokenCapturedAt = now
        } else {
            let newRecord = AccountRecord(
                email: profile.email,
                displayName: profile.displayName,
                organizationName: profile.organizationName,
                subscriptionType: profile.subscriptionType,
                tokenExpiresAt: nil,
                lastTokenCapturedAt: now,
                addedAt: now
            )
            records.append(newRecord)
        }

        saveAccounts(records)
        rebuildAccountsFromRecords(currentEmail: profile.email)
        return profile.email
    }

    // MARK: - Utilities

    private nonisolated static func parseDate(_ string: String?) -> Date? {
        guard let string = string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    func checkForUpdates() async {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.githubRepo)/releases/latest") else { return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeUsage/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, _) = try await urlSession.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tagName = json["tag_name"] as? String {
                let latestVersion = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                if isNewerVersion(latestVersion, than: Self.currentVersion) {
                    updateAvailable = latestVersion
                }
            }
        } catch {
            // Silently fail - update check is not critical
        }
    }

    private func isNewerVersion(_ latest: String, than current: String) -> Bool {
        let latestParts = latest.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(latestParts.count, currentParts.count) {
            let l = i < latestParts.count ? latestParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            if l > c { return true }
            if l < c { return false }
        }
        return false
    }
}

enum KeychainError: LocalizedError {
    case notLoggedIn
    case accessDenied
    case interactionNotAllowed
    case invalidData
    case invalidCredentialFormat
    case unexpectedError(status: OSStatus)
    case securityCommandFailed(String)
    case missingOAuthToken(availableKeys: String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in to Claude Code"
        case .accessDenied:
            return "Keychain access denied. Please allow access in System Settings."
        case .interactionNotAllowed:
            return "Keychain interaction not allowed. Try unlocking your Mac."
        case .invalidData:
            return "Could not read Keychain data"
        case .invalidCredentialFormat:
            return "Invalid credential format in keychain"
        case .unexpectedError(let status):
            return "Keychain error (code: \(status))"
        case .securityCommandFailed(let error):
            return "Keychain access failed: \(error.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .missingOAuthToken(let keys):
            return "No OAuth token in keychain. Found keys: \(keys). Try 'claude' to re-login."
        }
    }

    /// Errors that may resolve after the keychain unlocks (post-sleep/lock/boot)
    var isRetryable: Bool {
        switch self {
        case .notLoggedIn, .invalidCredentialFormat, .invalidData, .interactionNotAllowed, .securityCommandFailed:
            return true
        case .accessDenied, .unexpectedError, .missingOAuthToken:
            return false
        }
    }
}

enum UsageError: LocalizedError {
    case invalidResponse
    case apiError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from API"
        case .apiError(let code):
            if code == 401 {
                return "Authentication expired. Run 'claude' to re-authenticate."
            }
            return "API error (code: \(code))"
        }
    }
}

extension URLError {
    /// Network errors that may resolve after wake from sleep
    var isRetryable: Bool {
        switch self.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .dnsLookupFailed,
             .cannotFindHost,
             .cannotConnectToHost,
             .timedOut,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }
}
