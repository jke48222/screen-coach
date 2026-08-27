import Foundation

/// What the coach is not allowed to look at.
///
/// This app sees banking, medical records and private messages. The exclusion
/// list is checked **before a frame is ever captured**, not after — a screenshot
/// that exists and is then discarded has still existed, and on a machine with
/// memory pressure it may have reached swap.
///
/// Two independent gates, because they fail differently:
///
///   * **Bundle IDs** cover the obvious: password managers, banking, Messages,
///     Mail, Health. Exact and cheap.
///   * **Window-title patterns** cover the case a bundle list cannot: a browser
///     is not excludable as an app — you want coaching in it — but a tab
///     called "Online Banking" is exactly what must never be captured.
///
/// Everything here is pure so the policy can be tested exhaustively without a
/// screen, and so the decision is auditable rather than buried in a capture
/// callback.
public struct ExclusionList: Equatable, Sendable {

    public struct Rule: Equatable, Sendable {
        public enum Kind: String, Sendable { case bundleID, titleContains }
        public let kind: Kind
        public let pattern: String
        /// Set for defaults so the UI can show what shipped versus what the
        /// user added, and so a user deletion is never silently re-added.
        public let isDefault: Bool

        public init(kind: Kind, pattern: String, isDefault: Bool = false) {
            self.kind = kind
            self.pattern = pattern.lowercased()
            self.isDefault = isDefault
        }
    }

    public private(set) var rules: [Rule]

    public init(rules: [Rule]) { self.rules = rules }

    /// Prefilled with the categories a reasonable person would be alarmed to
    /// find in a screen tool's buffer. Deliberately broad: the cost of
    /// excluding an app that did not need excluding is that one query does not
    /// work, and the cost of the reverse is a screenshot of someone's bank
    /// balance.
    public static let defaults = ExclusionList(rules: [
        // Password managers and keychains
        "com.1password", "com.agilebits", "com.bitwarden", "com.lastpass",
        "com.dashlane", "com.apple.keychainaccess", "com.apple.passwords",
        "org.keepassxc", "in.sinew.enpass",
        // Banking and money
        "com.apple.wallet", "com.intuit", "com.squareup", "com.paypal",
        "com.coinbase", "com.robinhood", "com.chase", "com.bankofamerica",
        // Private correspondence and health
        "com.apple.mobilesms", "com.apple.messages", "com.apple.mail",
        "com.apple.health", "com.apple.medicalid", "com.tinyspeck.slackmacgap",
        "com.apple.facetime", "org.whispersystems.signal-desktop",
        "com.apple.notes",
    ].map { Rule(kind: .bundleID, pattern: $0, isDefault: true) }
     + [
        // Title patterns catch the browser-tab case a bundle list cannot.
        "online banking", "bank of", "account summary", "routing number",
        "credit card", "medical record", "patient portal", "lab results",
        "tax return", "social security", "password", "seed phrase",
        "private key", "recovery phrase", "2fa", "one-time code",
     ].map { Rule(kind: .titleContains, pattern: $0, isDefault: true) })

    // MARK: - Decisions

    public struct Verdict: Equatable, Sendable {
        public let excluded: Bool
        /// The rule that fired, for the visible explanation. A silent refusal
        /// looks like a bug; a stated one looks like a product.
        public let reason: String?

        public static let allowed = Verdict(excluded: false, reason: nil)
    }

    /// Prefix match, not equality: bundle IDs are hierarchical, so
    /// `com.1password` covers `com.1password.1password7` and its helpers
    /// without needing every variant enumerated.
    public func check(bundleID: String?, windowTitle: String?) -> Verdict {
        let bundle = (bundleID ?? "").lowercased()
        let title = (windowTitle ?? "").lowercased()

        for rule in rules {
            switch rule.kind {
            case .bundleID:
                guard !bundle.isEmpty, bundle.hasPrefix(rule.pattern) else { continue }
                return Verdict(excluded: true, reason: "app is excluded (\(rule.pattern))")
            case .titleContains:
                guard !title.isEmpty, title.contains(rule.pattern) else { continue }
                return Verdict(excluded: true,
                               reason: "window title matches “\(rule.pattern)”")
            }
        }
        return .allowed
    }

    // MARK: - Editing

    public mutating func add(_ rule: Rule) {
        guard !rules.contains(where: { $0.kind == rule.kind && $0.pattern == rule.pattern })
        else { return }
        rules.append(rule)
    }

    public mutating func remove(kind: Rule.Kind, pattern: String) {
        let p = pattern.lowercased()
        rules.removeAll { $0.kind == kind && $0.pattern == p }
    }

    // MARK: - Persistence

    /// Plain text, one rule per line, so it can be edited in any editor and
    /// reviewed in a diff. A privacy control the user cannot read is not one.
    ///
    ///     # comment
    ///     bundle: com.example.bank
    ///     title: online banking
    public static func parse(_ text: String) -> ExclusionList {
        var rules: [Rule] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, !parts[1].isEmpty else { continue }
            switch parts[0].lowercased() {
            case "bundle", "bundleid", "app":
                rules.append(Rule(kind: .bundleID, pattern: parts[1]))
            case "title":
                rules.append(Rule(kind: .titleContains, pattern: parts[1]))
            default:
                continue
            }
        }
        return ExclusionList(rules: rules)
    }

    public func serialized() -> String {
        var out = [
            "# Screen Coach exclusion list.",
            "# The coach never captures a frame from anything matching these.",
            "# Checked before capture, not after. Edits apply immediately.",
            "#",
            "#   bundle: com.example.bank     matches the app and its helpers",
            "#   title:  online banking       matches any window whose title contains it",
            "",
        ]
        for rule in rules {
            out.append("\(rule.kind == .bundleID ? "bundle" : "title"): \(rule.pattern)")
        }
        return out.joined(separator: "\n") + "\n"
    }
}
