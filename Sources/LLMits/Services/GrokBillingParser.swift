import Foundation

/// Pure parser for Grok Build / xAI billing payloads.
///
/// Two endpoints are merged:
/// - `GET /v1/billing?format=credits` — unified weekly pool (June 2026+)
/// - `GET /v1/billing` — legacy monthly included credits
///
/// Unified-billing accounts (`isUnifiedBillingUser` or
/// `USAGE_PERIOD_TYPE_WEEKLY`) no longer populate `monthlyLimit`/`used`
/// (they come back as 0). The weekly pool lives on the credits payload:
/// `creditUsagePercent`, `currentPeriod`, `productUsage`.
public enum GrokBillingParser {

    public static func parse(credits: Data, plain: Data) throws -> [UsageGroup] {
        guard let creditsJson = try? JSONSerialization.jsonObject(with: credits) as? [String: Any],
              let plainJson = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else {
            throw ServiceError.parseError("Invalid JSON response from Grok billing")
        }

        let creditsConfig = creditsJson["config"] as? [String: Any] ?? creditsJson
        let plainConfig = plainJson["config"] as? [String: Any] ?? plainJson

        debugLog("[Grok] credits keys=\(creditsConfig.keys.sorted()) plain keys=\(plainConfig.keys.sorted())")

        if isUnifiedWeekly(creditsConfig) {
            return [UsageGroup(name: "Grok Build", limits: parseUnifiedWeekly(creditsConfig, plain: plainConfig))]
        }
        return [UsageGroup(name: "Grok Build", limits: parseLegacyMonthly(creditsConfig, plain: plainConfig))]
    }

    // MARK: - Unified weekly pool (June 2026+)

    static func isUnifiedWeekly(_ config: [String: Any]) -> Bool {
        if config["isUnifiedBillingUser"] as? Bool == true { return true }
        let period = periodDict(config)
        let type = period?["type"] as? String
        return TimeFormatter.windowType(fromPeriodType: type) == .weekly
    }

    static func parseUnifiedWeekly(_ config: [String: Any], plain: [String: Any] = [:]) -> [UsageLimit] {
        var limits: [UsageLimit] = []

        let period = periodDict(config)
        let resetAt = TimeFormatter.parseResetDate(
            isoString: (period?["end"] as? String)
                ?? (config["billingPeriodEnd"] as? String)
        )
        let windowType = TimeFormatter.windowType(fromPeriodType: period?["type"] as? String)
        let resolvedType: UsageLimit.WindowType = windowType == .unknown ? .weekly : windowType

        let rawPercent = JSONNumber.double(from: config["creditUsagePercent"])
        let productUsage = config["productUsage"] as? [[String: Any]] ?? []
        // Unified billing sends a 0...∞ fraction of the weekly pool (1.0 = 100%,
        // 2.0 = 200% overage). Do not treat values like 2.0 as "2 percent".
        let poolPercent: Double = {
            if let rawPercent {
                return min(max(rawPercent, 0), 1.0)
            }
            let maxProduct = productUsage.compactMap { JSONNumber.double(from: $0["usagePercent"]) }.max() ?? 0
            return min(max(maxProduct, 0), 1.0)
        }()

        let (adjusted, reset) = TimeFormatter.resolveWindow(
            percentUsed: poolPercent,
            resetAt: resetAt,
            windowSeconds: TimeFormatter.weeklySeconds
        )

        var poolDetail: String?
        if productUsage.count == 1, let only = productUsage.first {
            poolDetail = friendlyProduct(only["product"] as? String)
        }

        limits.append(UsageLimit(
            name: "Weekly Usage",
            percentUsed: adjusted,
            detail: poolDetail,
            resetAt: reset,
            windowType: resolvedType
        ))

        if productUsage.count > 1 {
            for entry in productUsage {
                let name = friendlyProduct(entry["product"] as? String) ?? "Product"
                let raw = JSONNumber.double(from: entry["usagePercent"]) ?? 0
                let pct = min(max(raw, 0), 1.0)
                limits.append(UsageLimit(
                    name: name,
                    percentUsed: pct,
                    detail: "Share of weekly pool",
                    resetAt: reset,
                    windowType: resolvedType
                ))
            }
        }

        appendExtraCredits(from: config, fallback: plain, resetAt: reset, into: &limits)
        return limits
    }

    // MARK: - Legacy monthly included credits

    static func parseLegacyMonthly(_ creditsConfig: [String: Any], plain: [String: Any]) -> [UsageLimit] {
        var limits: [UsageLimit] = []

        let period = periodDict(creditsConfig) ?? periodDict(plain)
        let resetAt = TimeFormatter.parseResetDate(
            isoString: (period?["end"] as? String)
                ?? (period?["billingPeriodEnd"] as? String)
                ?? (creditsConfig["billingPeriodEnd"] as? String)
                ?? (plain["billingPeriodEnd"] as? String)
        )
        let windowType = TimeFormatter.windowType(fromPeriodType: period?["type"] as? String)
        let resolvedType: UsageLimit.WindowType = windowType == .unknown ? .monthly : windowType

        let rawLimit = JSONNumber.double(from: (plain["monthlyLimit"] as? [String: Any])?["val"] ?? plain["monthlyLimit"])
        let rawUsed = JSONNumber.double(from: (plain["used"] as? [String: Any])?["val"] ?? plain["used"])

        if let limit = rawLimit, let used = rawUsed, limit > 0 {
            let pct = min(used / limit, 1.0)
            limits.append(UsageLimit(
                name: "Build Credits",
                percentUsed: pct,
                detail: String(format: "%.0f / %.0f", used, limit),
                resetAt: resetAt,
                windowType: resolvedType
            ))
        } else if let pct = JSONNumber.double(from: creditsConfig["creditUsagePercent"]) {
            let normalized = pct > 1.0 ? pct / 100.0 : pct
            limits.append(UsageLimit(
                name: "Build Credits",
                percentUsed: min(normalized, 1.0),
                detail: nil,
                resetAt: resetAt,
                windowType: resolvedType
            ))
        }

        appendExtraCredits(from: creditsConfig, fallback: plain, resetAt: resetAt, into: &limits)

        if limits.isEmpty {
            limits.append(UsageLimit(
                name: "Subscription",
                percentUsed: 0,
                detail: "Active",
                resetAt: resetAt,
                windowType: resolvedType
            ))
        }
        return limits
    }

    // MARK: - Extras

    private static func appendExtraCredits(
        from config: [String: Any],
        fallback: [String: Any],
        resetAt: Date?,
        into limits: inout [UsageLimit]
    ) {
        let prepaid = JSONNumber.double(from: config["prepaidBalance"] ?? fallback["prepaidBalance"]) ?? 0
        if prepaid > 0 {
            limits.append(UsageLimit(
                name: "Extra Credits",
                percentUsed: 0,
                detail: String(format: "%.0f remaining", prepaid),
                resetAt: nil,
                windowType: .unknown
            ))
        }

        let cap = JSONNumber.double(from: config["onDemandCap"] ?? fallback["onDemandCap"]) ?? 0
        let used = JSONNumber.double(from: config["onDemandUsed"] ?? fallback["onDemandUsed"]) ?? 0
        if cap > 0 {
            limits.append(UsageLimit(
                name: "On-Demand",
                percentUsed: min(used / cap, 1.0),
                detail: String(format: "%.0f / %.0f", used, cap),
                resetAt: resetAt,
                windowType: .monthly
            ))
        }
    }

    private static func periodDict(_ config: [String: Any]) -> [String: Any]? {
        config["currentPeriod"] as? [String: Any]
    }

    static func friendlyProduct(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw {
        case "GrokBuild", "Build": return "Build"
        case "GrokChat", "Chat": return "Chat"
        case "Imagine", "GrokImagine": return "Imagine"
        case "Voice", "GrokVoice": return "Voice"
        case "API", "GrokAPI": return "API"
        default:
            return raw.replacingOccurrences(of: "Grok", with: "")
                .replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
    }
}
