import Foundation

/// Multi-step teaching, and knowing when a step is actually done.
///
/// The difference between a coach and a search box is that a coach watches.
/// Pointing at one control answers a question; teaching means "now do this,
/// and I'll wait — and I'll know when you've done it." Every step therefore
/// carries a **completion condition** expressed against the accessibility
/// tree, so advancing is evidence-driven rather than a timer or a Next button.
///
/// This matters more than it sounds. A tutorial that advances on a timer is
/// wrong for anyone slower than its author; one that advances on a Next button
/// cannot tell whether you did the thing or just clicked Next. The tree can
/// see the dialog open and the value change, so the coach can too — and it is
/// nearly free, because the cache is already re-reading on AXObserver events.
public struct Step: Equatable, Sendable, Codable {

    /// What has to become true for this step to count as done.
    public enum Completion: Equatable, Sendable {
        /// Something that was not resolvable before now is — a sheet opened,
        /// a panel revealed, a menu dropped down.
        case elementAppears(String)
        /// The opposite: a dialog dismissed, a popover closed.
        case elementDisappears(String)
        /// A named element's value changed — a checkbox toggled, a field
        /// filled, a slider moved.
        case valueChanges(String)
        /// The step's own target changed state. The common case for a
        /// checkbox or toggle, and it saves repeating the query.
        case targetChanges
        /// Nothing observable; the user says when. Honest for steps whose
        /// effect the tree cannot see — a canvas edit, a colour choice.
        case manual
    }

    public let instruction: String
    /// Resolver query for the thing to point at.
    public let target: String
    public let completion: Completion

    public init(instruction: String, target: String, completion: Completion = .targetChanges) {
        self.instruction = instruction
        self.target = target
        self.completion = completion
    }

    /// Substitute `{app}` with the app the lesson is running against.
    ///
    /// Exists for exactly one hard case: macOS puts Settings in a menu named
    /// after the app, so a lesson written once cannot name that menu
    /// statically — it is "Calendar" in Calendar and "Logic Pro" in Logic.
    /// Recordings never emit templates; only hand-written lessons use this.
    public func resolved(appName: String) -> Step {
        func sub(_ s: String) -> String {
            s.replacingOccurrences(of: "{app}", with: appName)
        }
        let completion: Completion
        switch self.completion {
        case .elementAppears(let q): completion = .elementAppears(sub(q))
        case .elementDisappears(let q): completion = .elementDisappears(sub(q))
        case .valueChanges(let q): completion = .valueChanges(sub(q))
        case .targetChanges: completion = .targetChanges
        case .manual: completion = .manual
        }
        return Step(instruction: sub(instruction), target: sub(target),
                    completion: completion)
    }
}

public struct Lesson: Equatable, Sendable, Codable {
    public let title: String
    /// Bundle ID this lesson is written for, when it is app-specific.
    public let bundleID: String?
    public let steps: [Step]

    public init(title: String, bundleID: String? = nil, steps: [Step]) {
        self.title = title
        self.bundleID = bundleID
        self.steps = steps
    }
}

/// Decides whether a step is done, by comparing two accessibility trees.
///
/// Pure on purpose: "did the dialog open" is exactly the kind of logic that is
/// miserable to debug live and trivial to test against two synthetic trees.
public enum LessonEngine {

    /// A step's completion is judged against the tree as it was when the step
    /// *started*, not the previous poll. Otherwise a slow change spread over
    /// several observer events never registers as a change at all — each poll
    /// looks identical to the one before it.
    public static func isSatisfied(_ completion: Step.Completion,
                                   target: String,
                                   before: [AXNode], after: [AXNode],
                                   windowBounds: ScreenRect? = nil,
                                   threshold: Double = AXResolver.hitThreshold) -> Bool {
        switch completion {
        case .manual:
            return false

        case .elementAppears(let query):
            return !resolves(query, in: before, windowBounds, threshold)
                && resolves(query, in: after, windowBounds, threshold)

        case .elementDisappears(let query):
            return resolves(query, in: before, windowBounds, threshold)
                && !resolves(query, in: after, windowBounds, threshold)

        case .valueChanges(let query):
            return changed(query, before: before, after: after,
                           windowBounds: windowBounds, threshold: threshold)

        case .targetChanges:
            return changed(target, before: before, after: after,
                           windowBounds: windowBounds, threshold: threshold)
        }
    }

    /// Presence asks a different question from pointing, and needs a
    /// different measure — not merely a different threshold.
    ///
    /// Two attempts failed first, both instructive. Using the pointing score
    /// and its hit threshold made a correctly-detected Preferences sheet score
    /// 0.609 against a 0.62 bar, because the size penalty that stops
    /// containers winning as pointing targets punishes a dialog for being
    /// dialog-sized. Simply lowering that bar then let a "Preferences"
    /// *button* satisfy a check for a "Preferences Window" — the dialog
    /// looked open before it had opened, so the step auto-advanced instantly.
    ///
    /// Recall is the right measure: the element's label must contain
    /// essentially all of the query's content words. Partial credit is
    /// correct for ranking and wrong for existence.
    public static let presenceRecall = 0.8

    static func resolves(_ query: String, in nodes: [AXNode],
                         _ windowBounds: ScreenRect?, _ threshold: Double) -> Bool {
        nodes.contains { AXResolver.presenceRecall(query: query, node: $0) >= presenceRecall }
    }

    /// Did the element this query names change in a way a person would call
    /// "I did it"? Value first, then enabled state, then its own bounds —
    /// a control that moved is usually a panel that opened around it.
    static func changed(_ query: String, before: [AXNode], after: [AXNode],
                        windowBounds: ScreenRect?, threshold: Double) -> Bool {
        guard let b = AXResolver.rank(query: query, in: before,
                                      windowBounds: windowBounds, limit: 1).first,
              let a = AXResolver.rank(query: query, in: after,
                                      windowBounds: windowBounds, limit: 1).first,
              b.score >= threshold, a.score >= threshold
        else { return false }
        if b.node.valueText != a.node.valueText { return true }
        if b.node.enabled != a.node.enabled { return true }
        if b.node.bounds.cg != a.node.bounds.cg { return true }
        return false
    }
}

/// Where the learner is in a lesson.
public struct LessonProgress: Equatable {
    public let lesson: Lesson
    public private(set) var index: Int
    public private(set) var completed: [Int]

    public init(lesson: Lesson) {
        self.lesson = lesson
        self.index = 0
        self.completed = []
    }

    public var current: Step? { lesson.steps[safeIndex: index] }
    public var isFinished: Bool { index >= lesson.steps.count }
    public var stepNumber: Int { index + 1 }
    public var totalSteps: Int { lesson.steps.count }

    public mutating func advance() {
        guard !isFinished else { return }
        completed.append(index)
        index += 1
    }

    /// Going back re-opens the step but keeps the record that it was done
    /// once — a learner stepping back to look again has not un-learned it.
    public mutating func back() {
        index = Swift.max(0, index - 1)
    }

    public var caption: String {
        guard let current else { return "\(lesson.title) — done" }
        return "\(stepNumber)/\(totalSteps)  \(current.instruction)"
    }
}

extension Array {
    subscript(safeIndex index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Hand-written coding, because these files are meant to be read.
///
/// A recorded workflow is the artifact "watch me" mode produces and shares —
/// someone will open one in an editor to see what it does or to fix a step's
/// wording. Swift's synthesized enum encoding (`{"elementAppears":{"_0":…}}`)
/// is machine-fine and human-hostile; `{"kind":"appears","query":…}` is a
/// file a person can audit, which for a tool that watches clicks is a
/// property, not polish.
extension Step.Completion: Codable {
    private enum K: String, CodingKey { case kind, query }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "appears":
            self = .elementAppears(try c.decode(String.self, forKey: .query))
        case "disappears":
            self = .elementDisappears(try c.decode(String.self, forKey: .query))
        case "valueChanges":
            self = .valueChanges(try c.decode(String.self, forKey: .query))
        case "targetChanges":
            self = .targetChanges
        case "manual":
            self = .manual
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "unknown completion kind “\(kind)”")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .elementAppears(let q):
            try c.encode("appears", forKey: .kind)
            try c.encode(q, forKey: .query)
        case .elementDisappears(let q):
            try c.encode("disappears", forKey: .kind)
            try c.encode(q, forKey: .query)
        case .valueChanges(let q):
            try c.encode("valueChanges", forKey: .kind)
            try c.encode(q, forKey: .query)
        case .targetChanges:
            try c.encode("targetChanges", forKey: .kind)
        case .manual:
            try c.encode("manual", forKey: .kind)
        }
    }
}
