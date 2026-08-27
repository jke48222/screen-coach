import Foundation

/// The latency budget, engineered up front rather than discovered.
///
/// These ceilings come straight from the project brief's allocation table.
/// They exist as code — not as a comment in a design doc — because the plan
/// is to regression-test them in CI. A budget nobody can fail is a wish.
public enum LatencyBudget {

    /// p90 ceiling per stage, in milliseconds. p90 rather than p50: a coach
    /// that feels instant nine times and stalls the tenth is a coach people
    /// stop trusting, and the mean hides exactly that.
    public static let ceilingMs: [CoachStage: Double] = [
        .hotkeyToFrame:    50,
        .frameMaterialize: 40,
        .axExtract:        80,
        .axResolve:        20,
        .visionGround:     900,
        .stt:              300,
        .reasonTTFT:       500,
        .pointerStart:     16,   // one frame at 60 Hz — the arc must start now
        .ttsFirstAudio:    400,
    ]

    /// End-to-end targets the stage budgets have to add up to.
    public static let totalAXHitMs: Double = 900
    public static let totalVisionFallbackMs: Double = 2000

    public struct Violation: Equatable, CustomStringConvertible {
        public let stage: CoachStage
        public let measuredP90: Double
        public let ceiling: Double

        public var overBy: Double { measuredP90 - ceiling }

        public var description: String {
            String(format: "%@ p90 %.1f ms exceeds %.0f ms budget (+%.1f)",
                   stage.label, measuredP90, ceiling, overBy)
        }
    }

    /// Checks measured samples against the budget. Stages with no samples are
    /// skipped rather than passed — an unmeasured stage is not a met budget,
    /// and `unmeasured` reports them so CI can fail on missing coverage too.
    public static func check(_ samples: [LatencySamples])
        -> (violations: [Violation], unmeasured: [CoachStage]) {
        var violations: [Violation] = []
        var measured = Set<CoachStage>()

        for s in samples where !s.isEmpty {
            measured.insert(s.stage)
            guard let ceiling = ceilingMs[s.stage] else { continue }
            if s.p90 > ceiling {
                violations.append(
                    Violation(stage: s.stage, measuredP90: s.p90, ceiling: ceiling)
                )
            }
        }

        let unmeasured = CoachStage.allCases.filter { !measured.contains($0) }
        return (violations, unmeasured)
    }

    /// Sum of p50s for the stages on a given path — the honest "what does a
    /// turn actually cost" number, as opposed to adding up the ceilings.
    public static func pathTotalP50(_ samples: [LatencySamples],
                                    stages: [CoachStage]) -> Double {
        let byStage = Dictionary(uniqueKeysWithValues: samples.map { ($0.stage, $0) })
        return stages.reduce(0) { $0 + (byStage[$1]?.p50 ?? 0) }
    }

    /// The two paths that matter, as ordered stage lists.
    public static let axHitPath: [CoachStage] =
        [.hotkeyToFrame, .frameMaterialize, .axExtract, .axResolve, .reasonTTFT, .pointerStart]

    public static let visionFallbackPath: [CoachStage] =
        [.hotkeyToFrame, .frameMaterialize, .axExtract, .visionGround, .reasonTTFT, .pointerStart]
}
