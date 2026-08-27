import CoreGraphics
import Foundation

/// Combining the two grounding paths, and admitting when they disagree.
///
/// This is the part of the project that is actually novel. Everyone else ships
/// one grounder and presents its output as fact. The accessibility tree is
/// exact when the element exists; the vision model is right about 58% of the
/// time on dense professional UIs. Those are wildly different kinds of answer
/// and collapsing them into one confident blue dot is how a teaching tool
/// destroys its own credibility.
///
/// So the rule is: **agreement between two independent methods is the only
/// thing that earns a confident point.** Everything else is rendered as a
/// question — a dashed ring — with the reason available. Honest uncertainty is
/// a feature no competitor has, and it is cheap: it costs one enum case and
/// some restraint.
public enum Fusion {

    /// A candidate from the accessibility tree — exact bounds, real semantics.
    public struct AXCandidate: Equatable {
        public let bounds: ScreenRect
        public let score: Double
        public let label: String

        public init(bounds: ScreenRect, score: Double, label: String) {
            self.bounds = bounds
            self.score = score
            self.label = label
        }
    }

    /// A candidate from the vision grounder — a point, no bounds, no semantics.
    public struct VisionCandidate: Equatable {
        public let point: ScreenPoint
        /// The model's own reported confidence, when it gives one. Holo1.5
        /// emits a click without a probability, so this is usually nil and the
        /// decision rests on agreement instead — which is the more trustworthy
        /// signal anyway.
        public let modelConfidence: Double?

        public init(point: ScreenPoint, modelConfidence: Double? = nil) {
            self.point = point
            self.modelConfidence = modelConfidence
        }
    }

    public enum Source: String, Equatable {
        /// Accessibility tree alone, above threshold. Exact.
        case accessibility
        /// Vision alone. Never confident — 58% on dense UIs is a coin flip
        /// with a lean, and presenting that as fact is the failure mode this
        /// project exists to fix.
        case vision
        /// Both agreed. The strongest signal available.
        case corroborated
        /// Both answered and pointed at different things.
        case conflicted
    }

    public enum Confidence: Equatable {
        case exact
        case uncertain
    }

    public struct Decision: Equatable {
        public let target: ScreenRect
        public let confidence: Confidence
        public let source: Source
        public let label: String
        /// Plain-language reason, shown when the answer is uncertain. A
        /// hedge the user cannot interrogate is just a worse answer.
        public let explanation: String?

        public init(target: ScreenRect, confidence: Confidence, source: Source,
                    label: String, explanation: String?) {
            self.target = target
            self.confidence = confidence
            self.source = source
            self.label = label
            self.explanation = explanation
        }
    }

    /// Fallback ring size for a vision-only answer. The model returns a point
    /// with no extent, and drawing a 1-pixel ring would imply a precision the
    /// method does not have; 44pt is the standard minimum touch target, which
    /// is about the honest resolution of a vision click.
    public static let visionRingSize: CGFloat = 44

    /// How far outside its own bounds a vision point may fall and still count
    /// as agreement. Slightly generous because a grounder that aims at a
    /// button's visual centre can land a few points outside a tight AX rect
    /// for controls whose bounds exclude their padding.
    public static let agreementSlackPoints: CGFloat = 6

    // MARK: - The decision

    public static func decide(ax: AXCandidate?, vision: VisionCandidate?,
                              axHitThreshold: Double) -> Decision? {
        switch (ax, vision) {

        case let (.some(a), .none):
            // No vision was run — either the AX match was good enough that it
            // was not needed, or vision was unavailable.
            let confident = a.score >= axHitThreshold
            return Decision(
                target: a.bounds,
                confidence: confident ? .exact : .uncertain,
                source: .accessibility,
                label: a.label,
                explanation: confident ? nil
                    : String(format: "closest match in the accessibility tree, but only %.0f%% sure",
                             a.score * 100)
            )

        case let (.none, .some(v)):
            // Vision alone never gets a solid ring. Nothing corroborates it,
            // and its own base rate does not justify confidence.
            return Decision(
                target: ring(around: v.point),
                confidence: .uncertain,
                source: .vision,
                label: "best visual guess",
                explanation: "the accessibility tree did not expose this control, "
                           + "so this is the vision model's guess"
            )

        case let (.some(a), .some(v)):
            let agrees = agreement(ax: a, vision: v)
            if agrees {
                // Two independent methods, one answer. This is the only case
                // that earns full confidence, and it is stronger than either
                // path alone — including an above-threshold AX match.
                return Decision(
                    target: a.bounds, confidence: .exact, source: .corroborated,
                    label: a.label, explanation: nil
                )
            }
            // They disagree by more than the element's own bounds. Say so.
            //
            // The AX rect is still what gets pointed at: when the element
            // exists its geometry is exact, and the vision model is the one
            // with a 42% error rate. But the ring goes dashed, because the
            // corroboration that would have justified a solid one is absent.
            return Decision(
                target: a.bounds, confidence: .uncertain, source: .conflicted,
                label: a.label,
                explanation: String(
                    format: "the accessibility tree and the vision model disagree "
                          + "by %.0f pt — pointing at the tree's answer",
                    distance(from: v.point.cg, to: a.bounds.cg))
            )

        case (.none, .none):
            return nil
        }
    }

    // MARK: - Geometry

    /// Do the two methods point at the same thing? "Same" means the vision
    /// click lands inside the element the tree identified, within a little
    /// slack. Deliberately not a distance threshold in absolute points: a
    /// 20 pt miss on a toolbar icon is a different control, while the same
    /// miss inside a wide button is still that button.
    public static func agreement(ax: AXCandidate, vision: VisionCandidate) -> Bool {
        guard ax.bounds.screenIndex == vision.point.screenIndex else {
            // Different monitors is not disagreement about which control — it
            // is disagreement about which screen, which is never agreement.
            return false
        }
        let slack = agreementSlackPoints
        return ax.bounds.cg.insetBy(dx: -slack, dy: -slack).contains(vision.point.cg)
    }

    /// Distance from a point to a rect: zero inside, otherwise the shortest
    /// distance to its edge. Used only for the explanation, so the number the
    /// user is told is the real gap and not a centre-to-centre figure that
    /// would overstate a near miss on a wide control.
    public static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    static func ring(around point: ScreenPoint) -> ScreenRect {
        let s = visionRingSize
        return ScreenRect(
            cg: CGRect(x: point.cg.x - s / 2, y: point.cg.y - s / 2, width: s, height: s),
            screenIndex: point.screenIndex
        )
    }

    // MARK: - Routing

    /// Should the vision fallback run at all?
    ///
    /// It costs about 1.7 ms per image token — measured — so the answer is no
    /// whenever the tree already answered well. Running it anyway to
    /// "double-check" a confident AX hit would trade 2 seconds for a
    /// corroboration that is right 58% of the time.
    public static func needsVision(axScore: Double?, axHitThreshold: Double,
                                   labelledFraction: Double) -> Bool {
        guard let axScore else { return true }
        if axScore >= axHitThreshold { return false }
        // A weak match in a well-labelled app usually means the user phrased
        // it unusually, not that the control is invisible to AX — and vision
        // is unlikely to do better on an app whose tree is good.
        if labelledFraction > 0.6 && axScore >= axHitThreshold * 0.75 { return false }
        return true
    }
}
