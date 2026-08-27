import Foundation

/// The stages of one coach turn, hotkey to spoken answer. Named as an enum
/// rather than free strings so the budget table below cannot drift out of
/// sync with what the pipeline actually reports.
public enum CoachStage: String, CaseIterable, Sendable {
    case hotkeyToFrame       = "hotkey→frame"
    case frameMaterialize    = "frame→image"
    case axExtract           = "ax-extract"
    case axResolve           = "ax-resolve"
    case visionGround        = "vision-ground"
    case stt                 = "stt"
    case reasonTTFT          = "reason-ttft"
    case pointerStart        = "pointer-start"
    case ttsFirstAudio       = "tts-first-audio"

    /// Short human label for tables.
    public var label: String { rawValue }
}

/// One timed sample set. Milliseconds throughout — the whole project's unit.
public struct LatencySamples: Sendable {
    public let stage: CoachStage
    public let values: [Double]

    public init(stage: CoachStage, values: [Double]) {
        self.stage = stage
        self.values = values
    }

    public var count: Int { values.count }
    public var isEmpty: Bool { values.isEmpty }

    private var sorted: [Double] { values.sorted() }

    public var min: Double { sorted.first ?? 0 }
    public var max: Double { sorted.last ?? 0 }
    public var mean: Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Nearest-rank percentile. Deliberately not interpolated: with the small
    /// trial counts a latency harness actually runs (20–100), interpolation
    /// invents a number that no run produced.
    public func percentile(_ p: Double) -> Double {
        let s = sorted
        guard !s.isEmpty else { return 0 }
        let clamped = Swift.min(Swift.max(p, 0), 100)
        let rank = Int((clamped / 100 * Double(s.count)).rounded(.up))
        return s[Swift.min(Swift.max(rank - 1, 0), s.count - 1)]
    }

    public var p50: Double { percentile(50) }
    public var p90: Double { percentile(90) }
    public var p99: Double { percentile(99) }

    /// Padding is done in Swift rather than via `%s`. Passing
    /// `(str as NSString).utf8String!` to `String(format:)` hands it a pointer
    /// into an autoreleased object that is already gone — it prints correctly
    /// for a while and then segfaults.
    public var summaryLine: String {
        let name = stage.label.padding(toLength: Swift.max(16, stage.label.count),
                                       withPad: " ", startingAt: 0)
        let n = "\(count)".padding(toLength: 4, withPad: " ", startingAt: 0)
        return name + " n=" + n
            + String(format: " p50 %7.2f  p90 %7.2f  p99 %7.2f  min %7.2f  max %7.2f ms",
                     p50, p90, p99, min, max)
    }
}

/// Accumulates timed stages across trials. Not thread-safe by design — one
/// trace per turn, owned by the turn.
public final class LatencyTrace {
    private var samples: [CoachStage: [Double]] = [:]
    private var open: [CoachStage: UInt64] = [:]

    public init() {}

    public func begin(_ stage: CoachStage, at ns: UInt64 = Mono.nowNs()) {
        open[stage] = ns
    }

    /// Closes an open stage. Returns the elapsed ms, or nil if never begun —
    /// a silent no-op here would turn a wiring bug into a missing row that
    /// looks like a fast stage.
    @discardableResult
    public func end(_ stage: CoachStage, at ns: UInt64 = Mono.nowNs()) -> Double? {
        guard let start = open.removeValue(forKey: stage) else { return nil }
        let ms = Mono.ms(from: start, to: ns)
        samples[stage, default: []].append(ms)
        return ms
    }

    public func record(_ stage: CoachStage, ms: Double) {
        samples[stage, default: []].append(ms)
    }

    public func samples(for stage: CoachStage) -> LatencySamples {
        LatencySamples(stage: stage, values: samples[stage] ?? [])
    }

    public var recordedStages: [CoachStage] {
        CoachStage.allCases.filter { !(samples[$0] ?? []).isEmpty }
    }

    public var allSamples: [LatencySamples] {
        recordedStages.map { samples(for: $0) }
    }
}
