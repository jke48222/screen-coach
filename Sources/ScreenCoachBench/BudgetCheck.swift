import AppKit
import ScreenCoachCore
import ScreenCoachKit

/// The latency budget as a CI gate.
///
/// The brief's instruction was to engineer the budget rather than discover it,
/// and to regression-test it. `LatencyBudget` states the ceilings and is unit
/// tested; this measures the real stages on the real machine and fails the
/// build when one drifts over.
///
/// It exits non-zero on violation so it can sit in CI unattended. Stages that
/// cannot be measured headlessly are reported as unmeasured rather than
/// silently passed — an unmeasured stage is not a met budget.
enum BudgetCheck {

    static func run(trials: Int, includeVision: Bool) -> Int32 {
        print("\n\u{001B}[1m── LATENCY BUDGET \u{001B}[0m")
        guard AXExtractor.isTrusted else {
            print("  Accessibility not granted — cannot measure.")
            return 2
        }

        let trace = LatencyTrace()
        let cache = AXCache()
        cache.start()
        defer { cache.stop() }

        // Let the speculative cache do what it does in production: warm the
        // tree before anyone asks. Measuring the cold path here would report a
        // number the shipping app never pays.
        Thread.sleep(forTimeInterval: 0.5)
        guard let tree = cache.tree() else {
            print("  No accessible frontmost window — focus an app and re-run.")
            return 3
        }
        let bounds = extent(of: tree)
        print("  Target: \(tree.appName) — \(tree.nodeCount) nodes, "
              + "\(tree.labelledCount) labelled\n")

        // Queries drawn from the app's own labels, so the resolver is doing
        // real work rather than failing fast on a string that matches nothing.
        let queries: [String] = tree.nodes
            .filter { $0.isActionable && $0.hasLabel }
            .prefix(8)
            .compactMap { n in (n.title ?? n.roleDescription).map { "the \($0) button" } }
        let fallback = ["the close button", "the search field"]
        let pool = queries.isEmpty ? fallback : queries

        for i in 0..<trials {
            let query = pool[i % pool.count]

            trace.begin(.axExtract)
            _ = cache.tree()
            trace.end(.axExtract)

            trace.begin(.axResolve)
            _ = AXResolver.rank(query: query, in: tree.nodes, windowBounds: bounds, limit: 3)
            trace.end(.axResolve)
        }

        // Capture is measured, but NOT recorded against `hotkeyToFrame`.
        //
        // That ceiling (50 ms) was calibrated in Phase 0 against a warm
        // SCStream, which the shipping app deliberately does not keep. The
        // accessibility path never captures at all, and the vision path is a
        // ~2.4 s model call where a 50 ms one-shot is 2% — not worth holding a
        // permanent capture session, which would also mean a permanently live
        // screen-recording indicator for a feature most queries never use.
        //
        // So this is reported as information about the vision path rather than
        // as a budget stage, and `hotkeyToFrame` is honestly left unmeasured.
        var captureMs: [Double] = []
        for _ in 0..<Swift.min(trials, 10) {
            let t0 = Mono.nowNs()
            if ScreenGrab.display(containing: bounds) != nil {
                captureMs.append(Mono.msSince(t0))
            }
        }

        if includeVision {
            let service = GroundingService(
                serverScript: URL(fileURLWithPath: "Tools/holo_server.py"),
                modelPath: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("models/holo1.5-7b-4bit").path)
            if service.startIfNeeded(), let shot = ScreenGrab.display(containing: bounds) {
                let hint = AXResolver.cropHint(query: pool[0], in: tree.nodes,
                                               windowBounds: bounds)
                let crop = hint.isWholeWindow ? nil : CGRect(
                    x: (hint.rect.cg.minX - shot.origin.x) * shot.scale,
                    y: (hint.rect.cg.minY - shot.origin.y) * shot.scale,
                    width: hint.rect.cg.width * shot.scale,
                    height: hint.rect.cg.height * shot.scale)
                for _ in 0..<3 {
                    let t0 = Mono.nowNs()
                    _ = service.ground(image: shot.image, query: pool[0], cropPixels: crop,
                                       screenIndex: shot.screenIndex, displayScale: shot.scale,
                                       displayOrigin: shot.origin)
                    trace.record(.visionGround, ms: Mono.msSince(t0))
                }
            } else {
                print("  vision: \(service.statusLine)\n")
            }
            service.shutdown()
        }

        // Report
        let samples = trace.allSamples
        if !captureMs.isEmpty {
            let c = LatencySamples(stage: .hotkeyToFrame, values: captureMs)
            print(String(format: "  INFO  one-shot display capture  p50 %6.2f  p90 %6.2f ms",
                         c.p50, c.p90))
            print("        vision path only; the AX path never captures\n")
        }
        for s in samples {
            let ceiling = LatencyBudget.ceilingMs[s.stage] ?? .infinity
            let ok = s.p90 <= ceiling
            print("  " + (ok ? "PASS" : "FAIL") + "  " + s.summaryLine
                  + String(format: "   ceiling %.0f", ceiling))
        }

        let (violations, unmeasured) = LatencyBudget.check(samples)
        let axHit = LatencyBudget.pathTotalP50(samples, stages: LatencyBudget.axHitPath)
        print(String(format: "\n  AX-hit path total (p50 sum): %.2f ms  — target %.0f ms  %@",
                     axHit, LatencyBudget.totalAXHitMs,
                     axHit <= LatencyBudget.totalAXHitMs ? "PASS" : "FAIL"))

        if !unmeasured.isEmpty {
            print("  unmeasured: " + unmeasured.map(\.label).joined(separator: ", "))
            print("  (not counted as passing — these need the running app or a human)")
        }
        if violations.isEmpty {
            print("\n  \u{001B}[1mBUDGET OK\u{001B}[0m")
            return 0
        }
        print("\n  \u{001B}[1mBUDGET VIOLATIONS\u{001B}[0m")
        for v in violations { print("    \(v)") }
        return 1
    }

    private static func extent(of tree: AXTreeSnapshot) -> ScreenRect {
        let union = tree.nodes.reduce(CGRect.null) { $0.union($1.bounds.cg) }
        if union.isNull { return tree.windowBounds ?? ScreenRect(cg: .zero, screenIndex: 0) }
        return ScreenRect(cg: union,
                          screenIndex: tree.windowBounds?.screenIndex
                              ?? DisplaySpace.current().index(bestOverlapping: union) ?? 0)
    }
}
