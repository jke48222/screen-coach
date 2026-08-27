import XCTest
@testable import ScreenCoachCore

final class LatencyTests: XCTestCase {

    func testNearestRankPercentileReturnsRealObservations() {
        let s = LatencySamples(stage: .axExtract, values: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        // Nearest-rank, not interpolated: every percentile is a number some
        // trial actually produced.
        XCTAssertEqual(s.p50, 5)
        XCTAssertEqual(s.p90, 9)
        XCTAssertEqual(s.percentile(100), 10)
        XCTAssertEqual(s.percentile(0), 1)
        XCTAssertEqual(s.min, 1)
        XCTAssertEqual(s.max, 10)
    }

    func testEmptySamplesDoNotCrash() {
        let s = LatencySamples(stage: .stt, values: [])
        XCTAssertTrue(s.isEmpty)
        XCTAssertEqual(s.p50, 0)
        XCTAssertEqual(s.mean, 0)
    }

    func testEndWithoutBeginReturnsNilRatherThanZero() {
        let t = LatencyTrace()
        // A stage that was never begun must not silently record 0 ms — that
        // would turn a wiring bug into a suspiciously fast stage.
        XCTAssertNil(t.end(.reasonTTFT))
        XCTAssertTrue(t.samples(for: .reasonTTFT).isEmpty)
    }

    func testTraceRecordsSpans() {
        let t = LatencyTrace()
        t.begin(.axExtract, at: 1_000_000)
        XCTAssertEqual(t.end(.axExtract, at: 6_000_000) ?? 0, 5.0, accuracy: 0.0001)
        XCTAssertEqual(t.samples(for: .axExtract).count, 1)
        XCTAssertEqual(t.recordedStages, [.axExtract])
    }

    // MARK: - Budget

    func testBudgetFlagsOverruns() {
        let samples = [
            LatencySamples(stage: .axExtract, values: Array(repeating: 200, count: 10)),
            LatencySamples(stage: .axResolve, values: Array(repeating: 5, count: 10)),
        ]
        let (violations, _) = LatencyBudget.check(samples)
        XCTAssertEqual(violations.count, 1)
        XCTAssertEqual(violations.first?.stage, .axExtract)
        XCTAssertEqual(violations.first?.overBy ?? 0, 120, accuracy: 0.001)
    }

    /// An unmeasured stage is not a passing stage. CI has to be able to fail
    /// on missing coverage, or the budget quietly stops covering the pipeline
    /// as stages get added.
    func testUnmeasuredStagesAreReportedNotPassed() {
        let (violations, unmeasured) = LatencyBudget.check(
            [LatencySamples(stage: .axExtract, values: [10])]
        )
        XCTAssertTrue(violations.isEmpty)
        XCTAssertFalse(unmeasured.contains(.axExtract))
        XCTAssertTrue(unmeasured.contains(.visionGround))
        XCTAssertEqual(unmeasured.count, CoachStage.allCases.count - 1)
    }

    func testBudgetJudgesOnP90NotMean() {
        // Eight fast turns and two slow ones. The mean lands at 64 ms and
        // sails under the 80 ms ceiling; p90 is 300 ms and does not. This is
        // the whole reason the budget is stated in p90.
        var values = Array(repeating: 5.0, count: 8)
        values.append(contentsOf: [300.0, 300.0])
        let s = LatencySamples(stage: .axExtract, values: values)
        XCTAssertLessThan(s.mean, LatencyBudget.ceilingMs[.axExtract]!)

        let (violations, _) = LatencyBudget.check([s])
        XCTAssertEqual(violations.count, 1, "p90 must catch the tail the mean hides")
    }

    /// The honest limit of the metric, pinned so nobody later "fixes" the
    /// percentile into interpolation and quietly changes what CI enforces:
    /// with ten samples, a single outlier sits *above* p90 by construction
    /// and does not trip the budget. Catching one-in-ten needs p99 and more
    /// trials, not a different p90.
    func testSingleOutlierInTenDoesNotTripP90() {
        var values = Array(repeating: 5.0, count: 9)
        values.append(300)
        let s = LatencySamples(stage: .axExtract, values: values)
        XCTAssertEqual(s.p90, 5)
        XCTAssertEqual(s.max, 300)
        XCTAssertTrue(LatencyBudget.check([s]).violations.isEmpty)
    }

    func testPathTotalsUseP50() {
        let samples: [LatencySamples] = [
            .init(stage: .hotkeyToFrame, values: [10]),
            .init(stage: .frameMaterialize, values: [20]),
            .init(stage: .axExtract, values: [30]),
            .init(stage: .axResolve, values: [5]),
            .init(stage: .reasonTTFT, values: [400]),
            .init(stage: .pointerStart, values: [1]),
        ]
        XCTAssertEqual(
            LatencyBudget.pathTotalP50(samples, stages: LatencyBudget.axHitPath),
            466, accuracy: 0.001
        )
    }

    /// The stage ceilings must actually add up to the end-to-end target they
    /// claim to serve, or the budget is decorative.
    func testStageCeilingsSumWithinEndToEndTargets() {
        let axHit = LatencyBudget.axHitPath.reduce(0.0) {
            $0 + (LatencyBudget.ceilingMs[$1] ?? 0)
        }
        XCTAssertLessThanOrEqual(axHit, LatencyBudget.totalAXHitMs)

        let vision = LatencyBudget.visionFallbackPath.reduce(0.0) {
            $0 + (LatencyBudget.ceilingMs[$1] ?? 0)
        }
        XCTAssertLessThanOrEqual(vision, LatencyBudget.totalVisionFallbackMs)
    }

    func testEveryStageHasACeiling() {
        for stage in CoachStage.allCases {
            XCTAssertNotNil(LatencyBudget.ceilingMs[stage], "\(stage) has no budget")
        }
    }
}

final class AXNodeTests: XCTestCase {

    private func node(role: String, title: String? = nil, desc: String? = nil,
                      help: String? = nil, id: String? = nil) -> AXNode {
        AXNode(id: 0, parentID: nil, depth: 0, role: role, title: title,
               roleDescription: desc, helpText: help, identifier: id,
               bounds: ScreenRect(cg: .zero, screenIndex: 0))
    }

    func testHumanRoleReadsLikeSpeech() {
        XCTAssertEqual(node(role: "AXButton").humanRole, "button")
        XCTAssertEqual(node(role: "AXMenuBarItem").humanRole, "menu bar item")
        XCTAssertEqual(node(role: "AXPopUpButton").humanRole, "pop up button")
    }

    /// AX apps routinely repeat the same text in title, description and help.
    /// Left unchecked that triples a token and skews similarity toward
    /// whichever app is most redundant, not whichever element matches best.
    func testSemanticLabelDeduplicatesRepeatedText() {
        let n = node(role: "AXButton", title: "Preferences",
                     desc: "Preferences", help: "Opens Preferences")
        XCTAssertEqual(n.semanticLabel, "button · Preferences · Opens Preferences")
    }

    func testUnlabelledNodeIsDetected() {
        XCTAssertFalse(node(role: "AXGroup").hasLabel)
        XCTAssertTrue(node(role: "AXGroup", id: "sidebar-container").hasLabel)
    }

    func testLabelledFractionPredictsGroundability() {
        let nodes = (0..<10).map { i in
            AXNode(id: i, parentID: nil, depth: 0, role: "AXButton",
                   title: i < 3 ? "Save" : nil,
                   bounds: ScreenRect(cg: .zero, screenIndex: 0))
        }
        let snap = AXTreeSnapshot(nodes: nodes, appName: "T", bundleID: nil, pid: 1,
                                  windowTitle: nil, windowBounds: nil, extractionMs: 1,
                                  truncated: false, truncationReason: nil,
                                  forcedManualAccessibility: false, maxDepthReached: 0)
        XCTAssertEqual(snap.labelledFraction, 0.3, accuracy: 0.0001)
        XCTAssertEqual(snap.actionableCount, 3)
    }
}
