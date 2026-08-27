import CoreGraphics
import Foundation

/// One element of an accessibility tree, flattened. Pure model — the
/// extraction lives in ScreenCoachKit, so matching and scoring can be tested
/// against synthetic trees with no app running.
public struct AXNode: Equatable, Sendable {
    public let id: Int
    public let parentID: Int?
    public let depth: Int

    public let role: String
    public let subrole: String?
    public let title: String?
    public let roleDescription: String?
    public let helpText: String?
    public let valueText: String?
    public let identifier: String?
    public let enabled: Bool
    /// `kAXSelected` — for menu bar items this means "my menu is open right
    /// now", which is the fact the extractor's menu gating runs on.
    public let selected: Bool

    /// Bounds in CG space with the owning display index attached.
    public let bounds: ScreenRect

    public init(id: Int, parentID: Int?, depth: Int, role: String,
                subrole: String? = nil, title: String? = nil,
                roleDescription: String? = nil, helpText: String? = nil,
                valueText: String? = nil, identifier: String? = nil,
                enabled: Bool = true, selected: Bool = false, bounds: ScreenRect) {
        self.id = id
        self.parentID = parentID
        self.depth = depth
        self.role = role
        self.subrole = subrole
        self.title = title
        self.roleDescription = roleDescription
        self.helpText = helpText
        self.valueText = valueText
        self.identifier = identifier
        self.enabled = enabled
        self.selected = selected
        self.bounds = bounds
    }

    /// Roles a user can actually be told to click. Containers are kept in the
    /// tree for structure but should not win a match on their own — pointing
    /// at "the group containing the button" is the classic near-miss.
    public static let actionableRoles: Set<String> = [
        "AXButton", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXTextField", "AXTextArea", "AXSlider", "AXIncrementor",
        "AXLink", "AXTab", "AXDisclosureTriangle", "AXColorWell", "AXComboBox",
        "AXSegmentedControl", "AXStepper", "AXSwitch", "AXToolbarButton",
        "AXCell", "AXRow", "AXOutline", "AXImage", "AXStaticText",
    ]

    public var isActionable: Bool { Self.actionableRoles.contains(role) }

    /// Roles that hold other elements. A container is never the answer to
    /// "where do I click", but it is the best thing to aim a vision crop at
    /// when the exact element is not exposed — which is the whole basis of
    /// the AX-assisted fallback.
    public static let containerRoles: Set<String> = [
        "AXGroup", "AXToolbar", "AXSplitGroup", "AXScrollArea", "AXTabGroup",
        "AXOutline", "AXTable", "AXList", "AXDrawer", "AXSheet", "AXWindow",
        "AXLayoutArea", "AXMenuBar", "AXMenu", "AXBrowser", "AXMatte",
    ]

    public var isContainer: Bool { Self.containerRoles.contains(role) }

    /// Does this node carry any human-readable identity at all? A node with
    /// bounds but no label is invisible to semantic matching — counting these
    /// is how we measure whether an app is groundable via AX.
    public var hasLabel: Bool {
        !(title?.isEmpty ?? true)
            || !(roleDescription?.isEmpty ?? true)
            || !(helpText?.isEmpty ?? true)
            || !(identifier?.isEmpty ?? true)
    }

    /// Human role name: "AXButton" → "button". What a person would say, which
    /// is what the reasoning model will name the target with.
    public var humanRole: String {
        var r = role
        if r.hasPrefix("AX") { r.removeFirst(2) }
        var out = ""
        for (i, ch) in r.enumerated() {
            if ch.isUppercase && i > 0 { out.append(" ") }
            out.append(Character(ch.lowercased()))
        }
        return out
    }

    /// The string that gets embedded and matched against the model's
    /// semantic target description. Deduplicated because AX commonly repeats
    /// the same text across title/description/help, and a tripled token would
    /// skew any similarity score toward whichever app is most redundant.
    public var semanticLabel: String {
        var parts: [String] = [humanRole]
        var seen = Set<String>([humanRole.lowercased()])
        for candidate in [title, roleDescription, helpText, valueText, identifier] {
            guard let c = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !c.isEmpty else { continue }
            let key = c.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            parts.append(c)
        }
        return parts.joined(separator: " · ")
    }
}

/// A whole extracted tree plus the facts about how extraction went. The
/// diagnostics are not decoration: "how many nodes have labels" is the number
/// that predicts whether AX-first grounding will work for a given app, and
/// `truncated` is how we avoid quietly reporting a partial tree as complete.
public struct AXTreeSnapshot: Sendable {
    public let nodes: [AXNode]
    public let appName: String
    public let bundleID: String?
    public let pid: pid_t
    public let windowTitle: String?
    public let windowBounds: ScreenRect?

    public let extractionMs: Double
    public let truncated: Bool
    public let truncationReason: String?
    public let forcedManualAccessibility: Bool
    public let maxDepthReached: Int
    /// Duplicate subtrees skipped during the walk. Chrome-class browsers
    /// expose the same elements by several paths; this is how many.
    public let duplicatesDropped: Int

    public init(nodes: [AXNode], appName: String, bundleID: String?, pid: pid_t,
                windowTitle: String?, windowBounds: ScreenRect?,
                extractionMs: Double, truncated: Bool, truncationReason: String?,
                forcedManualAccessibility: Bool, maxDepthReached: Int,
                duplicatesDropped: Int = 0) {
        self.nodes = nodes
        self.appName = appName
        self.bundleID = bundleID
        self.pid = pid
        self.windowTitle = windowTitle
        self.windowBounds = windowBounds
        self.extractionMs = extractionMs
        self.truncated = truncated
        self.truncationReason = truncationReason
        self.forcedManualAccessibility = forcedManualAccessibility
        self.maxDepthReached = maxDepthReached
        self.duplicatesDropped = duplicatesDropped
    }

    public var nodeCount: Int { nodes.count }
    public var labelledCount: Int { nodes.filter(\.hasLabel).count }
    public var actionableCount: Int { nodes.filter { $0.isActionable && $0.hasLabel }.count }

    /// Fraction of nodes carrying usable identity. Below roughly a third and
    /// the app is a canvas wearing an accessibility tree — expect to spend
    /// most queries in the vision fallback.
    public var labelledFraction: Double {
        nodeCount == 0 ? 0 : Double(labelledCount) / Double(nodeCount)
    }

    public var roleHistogram: [(role: String, count: Int)] {
        Dictionary(grouping: nodes, by: \.role)
            .map { (role: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }
}
