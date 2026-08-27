import AppKit
import ApplicationServices
import ScreenCoachCore

/// Accessibility-tree extraction: the primary grounding path.
///
/// This is the inversion the whole project rests on. Where a vision grounder
/// is right 58% of the time on dense professional UIs, the AX tree is exact
/// whenever the element is there — real bounds, real roles, no inference.
/// So the job here is narrow and performance-critical: get the frontmost
/// window's labelled elements, with bounds, fast enough to sit inside an
/// 80 ms budget.
///
/// The one optimisation that matters is batching. A naive walk reads eleven
/// attributes per node with eleven separate cross-process calls; every one is
/// a synchronous round trip into another app's main run loop. Reading them in
/// a single `AXUIElementCopyMultipleAttributeValues` collapses that to one
/// round trip per node. `Extractor.strategy` keeps the naive path available
/// precisely so the difference can be measured rather than asserted.
public enum AXExtractor {

    public enum Strategy: String, CaseIterable {
        /// One `AXUIElementCopyMultipleAttributeValues` per node.
        case batched
        /// One `AXUIElementCopyAttributeValue` per attribute per node.
        case perAttribute
    }

    public struct Limits {
        /// Node ceiling. A Xcode or Blender window can expose tens of
        /// thousands of elements; past a couple of thousand the extra nodes
        /// are table cells nobody will ever be told to click.
        public var maxNodes: Int
        public var maxDepth: Int
        /// Wall-clock ceiling for the whole walk. Hitting this returns a
        /// truncated-but-honest tree rather than blowing the budget.
        public var deadlineMs: Double
        /// Per-element AX messaging timeout. The default is effectively
        /// unbounded, which hangs us against a beachballing app.
        public var messagingTimeout: Float
        /// Longest value string kept. An `AXTextArea` holding a whole source
        /// file would otherwise dominate both time and memory for no gain.
        public var maxValueChars: Int

        /// Include the app's menu bar in the walk. On by default because the
        /// built-in lessons teach through menus; costs ~10 nodes while menus
        /// are closed.
        public var includeMenuBar: Bool

        /// Drop nodes identical in role, bounds and label to one already
        /// seen, along with their subtrees.
        ///
        /// Not a micro-optimisation: Chrome returns 159 nodes for a browser
        /// window of which only 61 are distinct — the same group appears up
        /// to twelve times because the tree is a graph reachable by several
        /// paths, and a plain BFS walks each path. Two different controls
        /// cannot occupy identical bounds with identical labels, so this is
        /// safe, and it removes 62% of the traversal cost and 62% of the
        /// duplicate candidates the resolver would otherwise rank.
        public var deduplicate: Bool

        public init(maxNodes: Int = 2500, maxDepth: Int = 40,
                    deadlineMs: Double = 250, messagingTimeout: Float = 0.1,
                    maxValueChars: Int = 120, deduplicate: Bool = true,
                    includeMenuBar: Bool = true) {
            self.maxNodes = maxNodes
            self.maxDepth = maxDepth
            self.deadlineMs = deadlineMs
            self.messagingTimeout = messagingTimeout
            self.maxValueChars = maxValueChars
            self.deduplicate = deduplicate
            self.includeMenuBar = includeMenuBar
        }

        public static let `default` = Limits()
    }

    public enum ExtractError: Error, CustomStringConvertible {
        case notTrusted
        case noFrontmostApp
        case noFocusedWindow(app: String)

        public var description: String {
            switch self {
            case .notTrusted:
                return "Accessibility permission not granted (AXIsProcessTrusted == false)"
            case .noFrontmostApp:
                return "No frontmost application"
            case .noFocusedWindow(let app):
                return "\(app) exposes no focused/main window over AX"
            }
        }
    }

    // Attribute order is fixed and shared by both strategies so the decoder
    // is identical for each — otherwise the "batched vs per-attribute"
    // comparison would be measuring two different amounts of work.
    private static let attributes: [String] = [
        kAXRoleAttribute as String,
        kAXSubroleAttribute as String,
        kAXTitleAttribute as String,
        kAXDescriptionAttribute as String,
        kAXHelpAttribute as String,
        kAXValueAttribute as String,
        kAXIdentifierAttribute as String,
        kAXEnabledAttribute as String,
        kAXPositionAttribute as String,
        kAXSizeAttribute as String,
        kAXChildrenAttribute as String,
        kAXSelectedAttribute as String,
    ]

    private enum Attr: Int {
        case role = 0, subrole, title, desc, help, value, identifier,
             enabled, position, size, children, selected
    }

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    public static func requestPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    // MARK: - Entry point

    /// Extract the frontmost app's focused window. `forceElectron` sets
    /// `AXManualAccessibility` when the tree comes back suspiciously empty —
    /// Electron ships with its renderer's accessibility off until something
    /// asks, and this is the documented ask.
    public static func frontmostWindowTree(
        strategy: Strategy = .batched,
        limits: Limits = .default,
        displays: DisplaySpace = .current(),
        forceElectron: Bool = true
    ) throws -> AXTreeSnapshot {
        guard isTrusted else { throw ExtractError.notTrusted }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw ExtractError.noFrontmostApp
        }
        return try windowTree(pid: app.processIdentifier,
                              appName: app.localizedName ?? "pid \(app.processIdentifier)",
                              bundleID: app.bundleIdentifier,
                              strategy: strategy, limits: limits,
                              displays: displays, forceElectron: forceElectron)
    }

    public static func windowTree(
        pid: pid_t, appName: String, bundleID: String?,
        strategy: Strategy = .batched,
        limits: Limits = .default,
        displays: DisplaySpace = .current(),
        forceElectron: Bool = true
    ) throws -> AXTreeSnapshot {
        let started = Mono.nowNs()
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, limits.messagingTimeout)

        var forced = false
        var window = focusedWindow(of: appElement)

        // Empty AX tree from a running app is the Electron signature. Force
        // it once, then retry — the flip is not instantaneous, so a short
        // bounded wait beats reporting the window as ungroundable.
        if window == nil, forceElectron {
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            forced = true
            let deadline = Date().addingTimeInterval(0.25)
            while window == nil && Date() < deadline {
                usleep(20_000)
                window = focusedWindow(of: appElement)
            }
        }

        guard let win = window else { throw ExtractError.noFocusedWindow(app: appName) }

        let windowTitle = copyString(win, kAXTitleAttribute as String, maxChars: 200)
        let windowBounds = copyBounds(win).map { displays.attribute($0) }

        var nodes: [AXNode] = []
        nodes.reserveCapacity(Swift.min(limits.maxNodes, 1024))

        // Breadth-first on purpose. If the node cap bites, BFS leaves us the
        // shallow, high-value controls — toolbar buttons, menu items — rather
        // than a deep excursion into one table's cells.
        //
        // The menu bar goes into the queue FIRST, so a heavy window hitting
        // the deadline can never starve it — the built-in lessons teach
        // through menus, and a tree with no menu bar breaks their first step.
        var queue: [(element: AXUIElement, parentID: Int?, depth: Int)] = []
        if limits.includeMenuBar {
            var mb: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString,
                                             &mb) == .success,
               let m = mb, CFGetTypeID(m) == AXUIElementGetTypeID() {
                queue.append(((m as! AXUIElement), nil, 0))
            }
        }
        queue.append((win, nil, 0))
        var head = 0
        var truncated = false
        var reason: String?
        var maxDepth = 0
        var seen = Set<String>()
        var duplicatesDropped = 0

        while head < queue.count {
            if nodes.count >= limits.maxNodes {
                truncated = true
                reason = "node cap \(limits.maxNodes) reached"
                break
            }
            if Mono.msSince(started) > limits.deadlineMs {
                truncated = true
                reason = String(format: "deadline %.0f ms reached", limits.deadlineMs)
                break
            }

            let item = queue[head]
            head += 1
            maxDepth = Swift.max(maxDepth, item.depth)

            guard let read = readNode(item.element, strategy: strategy, limits: limits) else {
                continue
            }

            let rect = read.frame ?? .zero

            // Deduplicate LABELLED nodes only.
            //
            // The tempting rule — same role, same bounds, same label means the
            // same element — is false for unlabelled containers. Chrome stacks
            // a dozen anonymous AXGroups at identical bounds whose *children*
            // differ, so treating them as duplicates collapsed a 159-node tree
            // to 10 and threw away most of the browser. A label is what makes
            // identity assertable: two distinct controls do not share a role,
            // a pixel-identical frame, and a name.
            let label = (read.title ?? "") + "|" + (read.desc ?? "")
            if limits.deduplicate, label.count > 1 {
                let key = "\(read.role)|\(Int(rect.minX)),\(Int(rect.minY)),"
                    + "\(Int(rect.width)),\(Int(rect.height))|\(label)"
                if seen.contains(key) {
                    duplicatesDropped += 1
                    continue
                }
                seen.insert(key)
            }

            let id = nodes.count
            nodes.append(AXNode(
                id: id, parentID: item.parentID, depth: item.depth,
                role: read.role, subrole: read.subrole, title: read.title,
                roleDescription: read.desc, helpText: read.help,
                valueText: read.value, identifier: read.identifier,
                enabled: read.enabled, selected: read.selected,
                bounds: displays.attribute(rect)
            ))

            // Menu gating: AX exposes the ENTIRE menu hierarchy even while
            // every menu is closed. Extracting it all would make "Settings"
            // present before the menu ever opens, so an
            // `elementAppears("Settings")` step could never fire — the
            // already-present rule would veto it forever. `kAXSelected` on a
            // menu bar item means "my menu is open right now", so closed
            // menus contribute exactly one pointable node (the item in the
            // bar) and open menus contribute their real, on-screen contents.
            // The same gate on AXMenuItem keeps closed submenus shut.
            let menuGated = (read.role == "AXMenuBarItem" || read.role == "AXMenuItem")
                && !read.selected
            if menuGated {
                // fall through — node recorded above, children withheld
            } else if item.depth < limits.maxDepth {
                for child in read.children {
                    queue.append((child, id, item.depth + 1))
                }
            } else if !read.children.isEmpty {
                truncated = true
                reason = reason ?? "depth cap \(limits.maxDepth) reached"
            }
        }

        return AXTreeSnapshot(
            nodes: nodes, appName: appName, bundleID: bundleID, pid: pid,
            windowTitle: windowTitle, windowBounds: windowBounds,
            extractionMs: Mono.msSince(started),
            truncated: truncated, truncationReason: reason,
            forcedManualAccessibility: forced, maxDepthReached: maxDepth,
            duplicatesDropped: duplicatesDropped
        )
    }

    // MARK: - Window lookup

    /// Focused window, then main window, then the first of `AXWindows`.
    /// Apps disagree about which of these they populate; a coach that only
    /// checked the first would be blind to a good third of the Mac.
    private static func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, attr as CFString, &value) == .success,
               let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() {
                return (v as! AXUIElement)
            }
        }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
           let arr = value as? [AXUIElement], let first = arr.first {
            return first
        }
        return nil
    }

    // MARK: - Node reading

    private struct RawNode {
        var role: String
        var subrole: String?
        var title: String?
        var desc: String?
        var help: String?
        var value: String?
        var identifier: String?
        var enabled: Bool
        var selected: Bool
        var frame: CGRect?
        var children: [AXUIElement]
    }

    private static func readNode(_ element: AXUIElement, strategy: Strategy,
                                 limits: Limits) -> RawNode? {
        switch strategy {
        case .batched:     return readBatched(element, limits: limits)
        case .perAttribute: return readPerAttribute(element, limits: limits)
        }
    }

    /// One cross-process round trip for all eleven attributes.
    private static func readBatched(_ element: AXUIElement, limits: Limits) -> RawNode? {
        var out: CFArray?
        // Options 0 (not .stopOnError): failed attributes come back as an
        // AXValue carrying an error rather than aborting the whole read, so
        // one missing attribute cannot cost us the node.
        let err = AXUIElementCopyMultipleAttributeValues(
            element, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &out
        )
        guard err == .success, let values = out as? [CFTypeRef],
              values.count == attributes.count else { return nil }

        func at(_ a: Attr) -> CFTypeRef? { unwrap(values[a.rawValue]) }

        guard let role = at(.role) as? String else { return nil }
        return RawNode(
            role: role,
            subrole: at(.subrole) as? String,
            title: clip(at(.title) as? String, limits.maxValueChars),
            desc: clip(at(.desc) as? String, limits.maxValueChars),
            help: clip(at(.help) as? String, limits.maxValueChars),
            value: clip(stringify(at(.value)), limits.maxValueChars),
            identifier: clip(at(.identifier) as? String, limits.maxValueChars),
            enabled: (at(.enabled) as? NSNumber)?.boolValue ?? true,
            selected: (at(.selected) as? NSNumber)?.boolValue ?? false,
            frame: rect(position: at(.position), size: at(.size)),
            children: (at(.children) as? [AXUIElement]) ?? []
        )
    }

    /// The naive path, kept so the batching win is a measurement.
    private static func readPerAttribute(_ element: AXUIElement, limits: Limits) -> RawNode? {
        func read(_ attr: String) -> CFTypeRef? {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attr as CFString, &v) == .success else {
                return nil
            }
            return v
        }
        guard let role = read(kAXRoleAttribute as String) as? String else { return nil }
        return RawNode(
            role: role,
            subrole: read(kAXSubroleAttribute as String) as? String,
            title: clip(read(kAXTitleAttribute as String) as? String, limits.maxValueChars),
            desc: clip(read(kAXDescriptionAttribute as String) as? String, limits.maxValueChars),
            help: clip(read(kAXHelpAttribute as String) as? String, limits.maxValueChars),
            value: clip(stringify(read(kAXValueAttribute as String)), limits.maxValueChars),
            identifier: clip(read(kAXIdentifierAttribute as String) as? String, limits.maxValueChars),
            enabled: (read(kAXEnabledAttribute as String) as? NSNumber)?.boolValue ?? true,
            selected: (read(kAXSelectedAttribute as String) as? NSNumber)?.boolValue ?? false,
            frame: rect(position: read(kAXPositionAttribute as String),
                        size: read(kAXSizeAttribute as String)),
            children: (read(kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
        )
    }

    // MARK: - Decoding helpers

    /// Multi-value reads return error placeholders in-band; treat those as
    /// "attribute absent" rather than letting an AXValue-wrapped error code
    /// leak downstream as if it were data.
    private static func unwrap(_ v: CFTypeRef?) -> CFTypeRef? {
        guard let v else { return nil }
        if CFGetTypeID(v) == AXValueGetTypeID(),
           AXValueGetType(v as! AXValue) == .axError {
            return nil
        }
        return v
    }

    private static func stringify(_ v: CFTypeRef?) -> String? {
        guard let v else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    private static func clip(_ s: String?, _ maxChars: Int) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        return t.count <= maxChars ? t : String(t.prefix(maxChars)) + "…"
    }

    private static func rect(position: CFTypeRef?, size: CFTypeRef?) -> CGRect? {
        guard let p = position, let s = size,
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var dims = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &dims) else { return nil }
        // AX hands back CG space already: top-left origin, spanning displays.
        return CGRect(origin: point, size: dims)
    }

    private static func copyString(_ element: AXUIElement, _ attr: String,
                                   maxChars: Int) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &v) == .success else {
            return nil
        }
        return clip(v as? String, maxChars)
    }

    private static func copyBounds(_ element: AXUIElement) -> CGRect? {
        var p: CFTypeRef?
        var s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &s) == .success
        else { return nil }
        return rect(position: p, size: s)
    }
}
