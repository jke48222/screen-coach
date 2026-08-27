import CoreGraphics
import Foundation

/// Turning watched clicks into teachable steps.
///
/// "Watch me" mode records a workflow by observation: the user clicks through
/// the task once, and each click becomes a `Step` whose target is a *semantic
/// description* of the clicked element — never its coordinates. Replay then
/// re-resolves each description against whatever tree is live at that moment,
/// which is why a recording made on one machine teaches on another with a
/// different window size, theme, or layout. Coordinates would break on the
/// first resize; semantics survive anything short of the app renaming its own
/// controls.
///
/// Everything here is pure — point-in-tree hit-testing, query synthesis, and
/// completion inference are all decisions that are miserable to debug live
/// and trivial to test against synthetic trees, which is exactly the split
/// that has caught every scoring bug in this project so far.
public enum WorkflowInference {

    // MARK: - Hit-testing

    /// Which element did a click at `point` land on?
    ///
    /// Smallest labelled element containing the point, with actionable ones
    /// preferred. "Smallest" is the load-bearing word: every click is also
    /// inside the window, several groups, and a scroll area, and recording
    /// "you clicked the window" teaches nothing. Elements bigger than half
    /// the tree's extent are refused outright for the same reason — if only
    /// a huge container matched, the honest answer is that we do not know
    /// what was clicked.
    public static func hitTest(_ point: CGPoint, in nodes: [AXNode]) -> AXNode? {
        let extent = nodes.reduce(CGRect.null) { $0.union($1.bounds.cg) }
        let extentArea = extent.isNull ? .infinity : extent.width * extent.height

        let candidates = nodes.filter { n in
            let r = n.bounds.cg
            guard r.width > 0, r.height > 0, r.contains(point), n.hasLabel else { return false }
            return (r.width * r.height) < extentArea * 0.5
        }
        guard !candidates.isEmpty else { return nil }

        func area(_ n: AXNode) -> CGFloat { n.bounds.cg.width * n.bounds.cg.height }

        // Actionable beats container, then smaller beats larger, then deeper
        // beats shallower — a stable, explainable preference order.
        return candidates.min { a, b in
            if a.isActionable != b.isActionable { return a.isActionable }
            if area(a) != area(b) { return area(a) < area(b) }
            return a.depth > b.depth
        }
    }

    // MARK: - Query synthesis

    /// Nouns chosen from the resolver's own `roleHints` vocabulary, so a
    /// recorded query earns the role-agreement bonus instead of polluting its
    /// content terms. "pop-up button" was the cautionary case: "pop" and "up"
    /// are not role words, so they would dilute recall against a node whose
    /// title is one word — the query must speak the resolver's language.
    static let nouns: [String: String] = [
        "AXButton": "button", "AXCheckBox": "button", "AXRadioButton": "button",
        "AXToolbarButton": "button", "AXPopUpButton": "popup",
        "AXComboBox": "dropdown", "AXMenuItem": "menu item",
        "AXMenuBarItem": "menu item", "AXTextField": "field",
        "AXTextArea": "field", "AXStaticText": "label", "AXImage": "image",
        "AXLink": "link", "AXTab": "tab", "AXSlider": "slider",
        "AXRow": "row", "AXCell": "cell",
    ]

    public static func bestLabel(_ n: AXNode) -> String? {
        for candidate in [n.title, n.roleDescription, n.helpText] {
            if let c = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
               c.count >= 2 { return c }
        }
        return nil
    }

    /// The phrase a person — or the replay resolver — would use for this
    /// element: "the Gmail button in the Bookmarks".
    ///
    /// The container clause follows the hard-won rules from Phase 0b: it must
    /// name a PLACE, so window titles are excluded (they name the document),
    /// as is any label that is long or covers most of the tree's extent.
    /// Feeding "the Back button in the Delivery Driver Shorts" to the
    /// resolver once cost 5 of 12 exact hits.
    public static func semanticQuery(for node: AXNode, in nodes: [AXNode]) -> String? {
        guard let label = bestLabel(node) else { return nil }
        let noun = nouns[node.role] ?? node.humanRole
        var query = "the \(label) \(noun)"

        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let extent = nodes.reduce(CGRect.null) { $0.union($1.bounds.cg) }
        let extentArea = extent.isNull ? 0 : extent.width * extent.height

        var cursor = node.parentID
        var hops = 0
        while let id = cursor, hops < 6, let parent = byID[id] {
            if parent.isContainer, parent.role != "AXWindow",
               let place = bestLabel(parent), place.count >= 3, place.count <= 24,
               !label.lowercased().contains(place.lowercased()) {
                let a = parent.bounds.cg.width * parent.bounds.cg.height
                if extentArea <= 0 || a / extentArea < 0.6 {
                    query += " in the \(place)"
                    break
                }
            }
            cursor = parent.parentID
            hops += 1
        }
        return query
    }

    // MARK: - Completion inference

    /// What observable thing did this click cause? That becomes the recorded
    /// step's completion condition, so replay advances when the learner's
    /// click has the same effect the author's did.
    ///
    /// Checked in order of evidential strength:
    ///  1. the clicked element vanished (a menu item closing its menu),
    ///  2. its value or enabled state changed (a toggle),
    ///  3. something labelled appeared (a sheet, panel, or menu opened),
    ///  4. the element merely moved (weak — usually a panel opening nearby),
    ///  5. nothing we can see — `.manual`, the honest fallback.
    ///
    /// Node ids are BFS order and NOT stable across snapshots, so the clicked
    /// element is re-found in the after-tree by its query, exactly the way
    /// `LessonEngine` will re-find it at replay time. Inference and replay
    /// deliberately share their means of identification — if they diverged,
    /// a recording could encode a condition replay can never observe.
    public static func inferCompletion(clickedQuery: String,
                                       before: [AXNode],
                                       after: [AXNode]) -> Step.Completion {
        let inAfter = AXResolver.rank(query: clickedQuery, in: after, limit: 1).first
        let inBefore = AXResolver.rank(query: clickedQuery, in: before, limit: 1).first

        if inBefore != nil, inAfter == nil || (inAfter?.score ?? 0) < AXResolver.hitThreshold {
            if let label = extractLabel(from: clickedQuery) {
                return .elementDisappears(label)
            }
        }

        if let b = inBefore, let a = inAfter,
           b.score >= AXResolver.hitThreshold, a.score >= AXResolver.hitThreshold {
            if b.node.valueText != a.node.valueText || b.node.enabled != a.node.enabled {
                return .targetChanges
            }
        }

        if let appeared = newestArrival(before: before, after: after) {
            return .elementAppears(appeared)
        }

        if let b = inBefore, let a = inAfter,
           b.score >= AXResolver.hitThreshold, a.score >= AXResolver.hitThreshold,
           b.node.bounds.cg != a.node.bounds.cg {
            return .targetChanges
        }

        return .manual
    }

    /// The most prominent labelled element present after but not before —
    /// by area, because when a sheet opens the sheet itself is the event, not
    /// the dozen buttons that arrived inside it.
    static func newestArrival(before: [AXNode], after: [AXNode]) -> String? {
        let beforeLabels = Set(before.compactMap { bestLabel($0)?.lowercased() })
        let fresh = after.filter { n in
            guard let l = bestLabel(n) else { return false }
            return !beforeLabels.contains(l.lowercased())
        }
        let biggest = fresh.max { a, b in
            (a.bounds.cg.width * a.bounds.cg.height)
                < (b.bounds.cg.width * b.bounds.cg.height)
        }
        return biggest.flatMap(bestLabel)
    }

    /// "the Gmail button in the Bookmarks" → "Gmail" — the bare label, for
    /// building presence queries out of pointing queries.
    static func extractLabel(from query: String) -> String? {
        var s = query
        if s.lowercased().hasPrefix("the ") { s.removeFirst(4) }
        if let range = s.range(of: " in the ") { s = String(s[..<range.lowerBound]) }
        // Strip the trailing noun we appended, if it is one of ours.
        for noun in Set(nouns.values).sorted(by: { $0.count > $1.count }) {
            if s.lowercased().hasSuffix(" " + noun) {
                s = String(s.dropLast(noun.count + 1))
                break
            }
        }
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
