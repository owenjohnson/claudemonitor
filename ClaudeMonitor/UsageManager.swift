import Foundation
import os.log

// MARK: - File Logger

struct FileLogger {
    private static let logsDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claudemonitor/logs", isDirectory: true)

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let fileDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func log(_ message: String, level: String = "INFO") {
        let fm = FileManager.default
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let fileName = "claudemonitor-\(fileDateFormatter.string(from: Date())).log"
        let fileURL = logsDir.appendingPathComponent(fileName)
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(level)] \(message)\n"

        if let data = line.data(using: .utf8) {
            if fm.fileExists(atPath: fileURL.path) {
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                fm.createFile(atPath: fileURL.path, contents: data, attributes: [.posixPermissions: 0o600])
            }
        }

        // Prune logs older than 7 days
        pruneOldLogs()
    }

    private static func pruneOldLogs() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        for file in files {
            guard let attrs = try? fm.attributesOfItem(atPath: file.path),
                  let created = attrs[.creationDate] as? Date,
                  created < cutoff else { continue }
            try? fm.removeItem(at: file)
        }
    }
}

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

    /// Single source of truth for worst-case utilization across all categories.
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
    @Published var accounts: [AccountUsage] = []
    @Published var updateAvailable: String?
    @Published private(set) var noAccountError: String?

    /// In-memory cache of access tokens by email.
    private var tokenCache: [String: String] = [:]

    /// Guard to prevent overlapping refresh cycles.
    private var isRefreshing = false

    static let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    static let githubRepo = "richhickson/claudecodeusage"

    private static let accountsDefaultsKey = "claudeusage.accounts"

    /// Configuration directory: ~/.claudemonitor/
    private static let configDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claudemonitor", isDirectory: true)
    /// Config file: ~/.claudemonitor/config.json
    private static let configFileURL: URL = configDir.appendingPathComponent("config.json")
    /// Default OAuth token file: ~/.claudemonitor/claudeoauth.json
    private static let defaultTokenFileURL: URL = configDir.appendingPathComponent("claudeoauth.json")
    // Configured URLSession with timeouts
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    // MARK: - Convenience accessors (single-account compatibility for UsageView/AppDelegate)

    /// The primary account's usage (first token in the file).
    var usage: UsageData? {
        accounts.first(where: { $0.isCurrentAccount })?.usage
    }

    /// The primary account's error, or the global no-account error.
    var error: String? {
        accounts.first(where: { $0.isCurrentAccount })?.error ?? noAccountError
    }

    /// True while the primary account is loading.
    var isLoading: Bool {
        accounts.first(where: { $0.isCurrentAccount })?.isLoading ?? false
    }

    /// Last update timestamp for the primary account.
    var lastUpdated: Date? {
        accounts.first(where: { $0.isCurrentAccount })?.lastUpdated
    }

    /// Display name for the primary account.
    var displayName: String? {
        accounts.first(where: { $0.isCurrentAccount })?.account.displayName
    }

    // MARK: - Config & Token File

    struct AppConfig: Codable {
        var tokenFile: String?
    }

    private func readConfig() -> AppConfig {
        guard let data = try? Data(contentsOf: Self.configFileURL),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig()
        }
        return config
    }

    private func resolvedTokenFileURL() -> URL {
        let config = readConfig()
        let path = config.tokenFile ?? Self.defaultTokenFileURL.path
        let expanded = NSString(string: path).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    /// Display-friendly token file path for error messages.
    func tokenFilePath() -> String {
        let config = readConfig()
        return config.tokenFile ?? "~/.claudemonitor/claudeoauth.json"
    }

    /// An entry in the OAuth token file. Supports both formats:
    ///   [{"token": "...", "name": "Personal"}]   — named entries
    ///   ["token1", "token2"]                      — plain strings (legacy)
    struct TokenEntry: Codable {
        let token: String
        let name: String?
    }

    private func readOAuthTokens() -> [TokenEntry] {
        let url = resolvedTokenFileURL()
        guard let data = try? Data(contentsOf: url) else { return [] }

        // Try object format first: [{"token": "...", "name": "..."}]
        if let entries = try? JSONDecoder().decode([TokenEntry].self, from: data) {
            return entries.filter { !$0.token.isEmpty }
        }

        // Fall back to plain string array: ["token1", "token2"]
        if let strings = try? JSONDecoder().decode([String].self, from: data) {
            return strings.filter { !$0.isEmpty }.map { TokenEntry(token: $0, name: nil) }
        }

        return []
    }

    /// Ensure the config directory exists on startup.
    func ensureConfigDir() {
        try? FileManager.default.createDirectory(at: Self.configDir, withIntermediateDirectories: true)
    }

    // MARK: - Refresh

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let entries = readOAuthTokens()
        FileLogger.log("Refresh started — \(entries.count) token(s) found")
        guard !entries.isEmpty else {
            let path = tokenFilePath()
            let msg = "No OAuth tokens found. Add tokens to \(path)"
            FileLogger.log(msg, level: "WARN")
            noAccountError = msg
            accounts = []
            return
        }
        noAccountError = nil

        // Resolve tokens to account IDs using name or fallback
        var resolvedAccounts: [(email: String, token: String, error: String?)] = []
        var seenIds = Set<String>()

        for (index, entry) in entries.enumerated() {
            let maskedToken = "…\(entry.token.suffix(6))"

            // Use explicit name if provided, otherwise try cached map, then profile API
            if let name = entry.name {
                guard !seenIds.contains(name) else { continue }
                seenIds.insert(name)
                resolvedAccounts.append((email: name, token: entry.token, error: nil))
                tokenCache[name] = entry.token
                FileLogger.log("Token \(index + 1) [\(maskedToken)] → named '\(name)'")
            } else {
                // No name provided — use masked token as fallback label
                let fallbackId = "account-\(index + 1) (\(maskedToken))"
                resolvedAccounts.append((email: fallbackId, token: entry.token, error: nil))
                tokenCache[fallbackId] = entry.token
                FileLogger.log("Token \(index + 1) [\(maskedToken)] → unnamed, using fallback ID")
            }
        }

        guard !resolvedAccounts.isEmpty else {
            let msg = "Could not authenticate any tokens. Verify tokens in \(tokenFilePath())"
            FileLogger.log(msg, level: "ERROR")
            noAccountError = msg
            return
        }

        FileLogger.log("Resolved \(resolvedAccounts.count) account(s) — fetching usage")

        // Rebuild accounts array (first token = primary for status bar)
        rebuildAccountsFromResolvedTokens(resolvedAccounts)

        // Fetch usage for all accounts
        await refreshAllAccounts()
    }

    /// Rebuild the accounts array from resolved token→email pairs.
    /// First account is marked as current (primary) for status bar display.
    private func rebuildAccountsFromResolvedTokens(_ resolved: [(email: String, token: String, error: String?)]) {
        let records = loadAccounts()
        var updated: [AccountUsage] = []

        for (index, entry) in resolved.enumerated() {
            let record = records.first(where: { $0.email == entry.email }) ?? AccountRecord(
                email: entry.email,
                displayName: nil,
                organizationName: nil,
                subscriptionType: nil,
                tokenExpiresAt: nil,
                lastTokenCapturedAt: Date(),
                addedAt: Date()
            )

            let existing = accounts.first(where: { $0.account.email == entry.email })

            updated.append(AccountUsage(
                account: record,
                usage: existing?.usage,
                error: entry.error,
                isLoading: entry.error == nil,
                lastUpdated: existing?.lastUpdated,
                isCurrentAccount: index == 0,
                hasCachedToken: true
            ))
        }

        accounts = updated
    }

    /// Fetch usage for all accounts sequentially with delays to avoid rate limiting.
    private func refreshAllAccounts() async {
        let cachedTokens = tokenCache
        let session = urlSession
        let version = Self.currentVersion

        for (i, account) in accounts.enumerated() {
            let email = account.account.email
            guard let token = cachedTokens[email] else {
                if let index = accounts.firstIndex(where: { $0.account.email == email }) {
                    accounts[index].error = "No token available"
                    accounts[index].isLoading = false
                }
                continue
            }

            // Stagger requests to avoid rate limiting
            if i > 0 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }

            FileLogger.log("Fetching usage for \(email)")
            do {
                let usage = try await Self.fetchUsage(
                    token: token, session: session, version: version
                )
                FileLogger.log("Usage OK for \(email): session=\(usage.sessionPercentage)% weekly=\(usage.weeklyPercentage)%")
                if let index = accounts.firstIndex(where: { $0.account.email == email }) {
                    accounts[index].usage = usage
                    accounts[index].error = nil
                    accounts[index].lastUpdated = Date()
                    accounts[index].isLoading = false
                }
            } catch let error as UsageError {
                FileLogger.log("Usage error for \(email): \(error.localizedDescription)", level: "ERROR")
                if let index = accounts.firstIndex(where: { $0.account.email == email }) {
                    if case .apiError(let code, _) = error, code == 401 {
                        accounts[index].error = "Token expired (401)"
                    } else {
                        accounts[index].error = Self.truncateForUI(error.localizedDescription)
                    }
                    accounts[index].isLoading = false
                }
            } catch {
                FileLogger.log("Usage error for \(email): \(error.localizedDescription)", level: "ERROR")
                if let index = accounts.firstIndex(where: { $0.account.email == email }) {
                    accounts[index].error = Self.truncateForUI(error.localizedDescription)
                    accounts[index].isLoading = false
                }
            }
        }
    }

    // MARK: - UserDefaults Persistence

    func loadAccounts() -> [AccountRecord] {
        guard let data = UserDefaults.standard.data(forKey: Self.accountsDefaultsKey),
              let records = try? JSONDecoder().decode([AccountRecord].self, from: data) else {
            return []
        }
        return records
    }

    func saveAccounts(_ records: [AccountRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: Self.accountsDefaultsKey)
    }

    // MARK: - Network: Usage via Inference Headers

    /// Fetch usage data by making a minimal inference call and reading rate limit headers.
    /// This works with long-lived OAuth tokens that only have user:inference scope.
    private nonisolated static func fetchUsage(
        token: String, session: URLSession, version: String
    ) async throws -> UsageData {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-code/\(version)", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        // Minimal inference call: 1 max token, cheapest model
        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "."]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw UsageError.apiError(statusCode: httpResponse.statusCode, body: responseBody)
        }

        // Parse usage from response headers
        let headers = httpResponse.allHeaderFields

        // Headers return 0.0-1.0 fractions; convert to 0-100 percentages
        let sessionUtil = headerDouble(headers, "anthropic-ratelimit-unified-5h-utilization").map { $0 * 100 }
        let weeklyUtil = headerDouble(headers, "anthropic-ratelimit-unified-7d-utilization").map { $0 * 100 }
        let sonnetUtil = headerDouble(headers, "anthropic-ratelimit-unified-7d_sonnet-utilization").map { $0 * 100 }

        let sessionReset = headerEpochDate(headers, "anthropic-ratelimit-unified-5h-reset")
        let weeklyReset = headerEpochDate(headers, "anthropic-ratelimit-unified-7d-reset")
        let sonnetReset = headerEpochDate(headers, "anthropic-ratelimit-unified-7d_sonnet-reset")

        return UsageData(
            sessionUtilization: sessionUtil ?? 0,
            sessionResetsAt: sessionReset,
            weeklyUtilization: weeklyUtil ?? 0,
            weeklyResetsAt: weeklyReset,
            sonnetUtilization: sonnetUtil,
            sonnetResetsAt: sonnetReset
        )
    }

    /// Parse a Double from a response header value.
    private nonisolated static func headerDouble(
        _ headers: [AnyHashable: Any], _ name: String
    ) -> Double? {
        guard let value = headers[name] as? String ?? headers[name.lowercased()] as? String else {
            return nil
        }
        return Double(value)
    }

    /// Parse a Unix epoch timestamp from a response header into a Date.
    private nonisolated static func headerEpochDate(
        _ headers: [AnyHashable: Any], _ name: String
    ) -> Date? {
        guard let value = headers[name] as? String ?? headers[name.lowercased()] as? String,
              let epoch = TimeInterval(value) else {
            return nil
        }
        return Date(timeIntervalSince1970: epoch)
    }

    // MARK: - Utilities

    func checkForUpdates() async {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.githubRepo)/releases/latest") else { return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeMonitor/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")

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

    /// Truncate error messages for display in the popover. Full details are in the log.
    nonisolated static func truncateForUI(_ message: String?) -> String {
        guard let message = message else { return "Unknown error" }
        if message.count <= 80 { return message }
        return String(message.prefix(77)) + "…"
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

enum UsageError: LocalizedError {
    case invalidResponse
    case apiError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from API"
        case .apiError(let code, let body):
            FileLogger.log("API error \(code): \(body)", level: "ERROR")
            if code == 401 {
                return "Token expired or invalid (401)"
            }
            if code == 429 {
                return "Rate limited (429). See logs."
            }
            return "API error \(code). See logs."
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
