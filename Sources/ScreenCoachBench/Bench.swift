import AppKit
import ImageIO
import UniformTypeIdentifiers
import ScreenCaptureKit
import ScreenCoachCore
import ScreenCoachKit

/// Phase 0: measure the budget before designing anything.
///
/// Three numbers decide this architecture, and none of them exist as a
/// published figure for this combination of machine and APIs:
///   (a) hotkey → frame in hand
///   (b) AX tree extraction of a real window
///   (c) Holo1.5-7B grounding one cropped window
///
/// Everything here reports p50/p90/p99 rather than an average, because the
/// felt experience of a coach is set by its slow turns, not its median one.
@main
struct Bench {

    static func main() async {
        // Touch NSApplication on the main thread before anything else.
        //
        // A bare executable has no window-server connection until something
        // asks AppKit for one, and window-scoped ScreenCaptureKit queries
        // need it. Without this, enumerating windows trips
        // `CGS_REQUIRE_INIT` and aborts the process — display-scoped capture
        // happens to work, which makes it look like a scope bug rather than
        // an initialisation one. The real app gets this for free from
        // NSApplicationMain.
        _ = NSApplication.shared

        let args = Array(CommandLine.arguments.dropFirst())
        let cmd = args.first.flatMap { $0.hasPrefix("--") ? nil : $0 } ?? "all"
        let opts = Options(args)

        switch cmd {
        case "doctor":  doctor()
        case "ax":      await benchAX(opts)
        case "coldwarm": benchColdWarm(opts)
        case "snap":    await snap(opts, args: args)
        case "staleness": await benchStaleness(opts)
        case "budget":
            exit(BudgetCheck.run(trials: opts.trials,
                                 includeVision: args.contains("--vision")))
        case "exclusions":
            // Proves the live watcher, not just that the file parses: a
            // running process must pick up an edit before the next query, or
            // "excluding your bank" realistically means "restart the coach",
            // which nobody does.
            header("EXCLUSION LIST — LIVE RELOAD")
            let store = ExclusionStore()
            print("  file: \(store.url.path)")
            print("  \(store.statusLine)")
            var seen = 0
            store.onChange = { list in
                seen += 1
                print("  reload #\(seen): \(list.rules.count) rules — "
                      + (list.check(bundleID: "com.apple.iCal", windowTitle: nil).excluded
                         ? "Calendar now EXCLUDED" : "Calendar allowed"))
            }
            print("  watching for 8s — edit the file now…")
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            }
            print("  \(seen) live reload(s) observed")
        case "windows":
            // Which windows ScreenCaptureKit will actually hand over — not
            // the same set as "apps with an AX window", as Calendar proved.
            if let content = try? await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true) {
                header("SHAREABLE WINDOWS")
                for w in content.windows.sorted(by: {
                    $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height
                }) where w.frame.width >= 120 && w.frame.height >= 60 {
                    print("  " + (w.owningApplication?.applicationName ?? "?").clipped(22).pad(24)
                          + String(format: "%5.0f×%-5.0f at (%5.0f,%5.0f)  onScreen=%@  ",
                                   w.frame.width, w.frame.height, w.frame.minX, w.frame.minY,
                                   w.isOnScreen ? "y" : "n")
                          + (w.title ?? "untitled").clipped(40))
                }
            }
        case "axplan":
            AXPlan.run(dataPath: args.firstIndex(of: "--data").map { args[$0 + 1] }
                                 ?? "bench-data/logic-pro.json",
                       outPath: args.firstIndex(of: "--out").map { args[$0 + 1] }
                                ?? "bench-data/axplan.json",
                       count: opts.targets)
        case "dump":    dumpTree(opts)
        case "apps":    surveyApps(opts)
        case "capture": await benchCapture(opts)
        case "hotkey":  await benchHotkey(opts)
        case "all":
            doctor()
            await benchAX(opts)
            surveyApps(opts)
            await benchCapture(opts)
        default:
            print("""
            screencoach-bench — Phase 0 latency harness

            USAGE
              screencoach-bench <command> [options]

            COMMANDS
              doctor    Permissions and environment
              ax        AX tree extraction timing (batched vs per-attribute)
              coldwarm  First-touch vs steady-state AX cost, and how fast
                        warmth decays — decides speculative extraction
              apps      Survey every running app: groundability + extraction cost
              dump      Print the frontmost window's AX tree with bounds
              capture   Compare screencapture(1), SCScreenshotManager, warm SCStream
              hotkey    Interactive: real key press → frame in hand
              snap      Save the frontmost window as PNG + its AX tree as JSON,
                        for the vision-grounding benchmark to work against
              axplan    Resolver hit rate + AX-aimed crop plans, from a snapshot
              budget    Measure every stage against LatencyBudget; non-zero exit
                        on violation, so it can gate CI. --vision includes the
                        model (slow, and loads 5.6 GB)
              exclusions  Watch the privacy list reload live
              all       doctor + ax + apps + capture

            OPTIONS
              --trials N     Trials per measurement (default 30)
              --app NAME     Target a named running app instead of the frontmost
              --delay SEC    Countdown before measuring, to go focus something
              --scope S      capture scope: display | window   (default window)
              --max-nodes N  AX node cap (default 2500)
              --deadline MS  AX walk deadline (default 250)
              --targets N    Targets to measure in axplan (default 10)
              --data PATH    Snapshot JSON for axplan
              --out PATH     Output path
              --verbose      Per-trial detail
            """)
        }
    }

    // MARK: - Options

    struct Options {
        var trials = 30
        var app: String?
        var delay = 0
        var scope = "window"
        var maxNodes = 2500
        var targets = 10
        var verbose = false

        init(_ args: [String]) {
            var i = 0
            while i < args.count {
                switch args[i] {
                case "--trials":    trials = args.int(at: i + 1) ?? trials; i += 1
                case "--app":       app = args.string(at: i + 1); i += 1
                case "--delay":     delay = args.int(at: i + 1) ?? delay; i += 1
                case "--scope":     scope = args.string(at: i + 1) ?? scope; i += 1
                case "--max-nodes": maxNodes = args.int(at: i + 1) ?? maxNodes; i += 1
                case "--deadline":  deadline = args.int(at: i + 1).map(Double.init) ?? deadline; i += 1
                case "--targets":   targets = args.int(at: i + 1) ?? targets; i += 1
                case "--verbose":   verbose = true
                default: break
                }
                i += 1
            }
        }

        var deadline = 250.0

        var limits: AXExtractor.Limits {
            var l = AXExtractor.Limits.default
            l.maxNodes = maxNodes
            l.deadlineMs = deadline
            return l
        }
    }

    // MARK: - Doctor

    static func doctor() {
        header("ENVIRONMENT")
        let pi = ProcessInfo.processInfo
        print("  macOS              \(pi.operatingSystemVersionString)")
        print("  Cores              \(pi.processorCount) (\(pi.activeProcessorCount) active)")
        print(String(format: "  Memory             %.1f GB", Double(pi.physicalMemory) / 1e9))
        print("  Process            \(Bundle.main.bundleIdentifier ?? "no bundle id (bare binary)")")

        header("PERMISSIONS")
        let ax = AXExtractor.isTrusted
        print("  Accessibility      \(ax ? "GRANTED" : "DENIED — AX grounding and the event tap are both blocked")")
        print("  Screen Recording   \(CGPreflightScreenCaptureAccess() ? "GRANTED" : "DENIED — capture will fail")")

        header("DISPLAYS")
        let space = DisplaySpace.current()
        print(space.describeLayout)
        print(String(format: "  primary height     %.0f pt (the one number every CG↔AppKit flip needs)",
                     space.primaryHeight))

        if let front = NSWorkspace.shared.frontmostApplication {
            header("FRONTMOST")
            print("  \(front.localizedName ?? "?")  \(front.bundleIdentifier ?? "")  pid \(front.processIdentifier)")
        }
    }

    // MARK: - (b) AX extraction

    static func benchAX(_ o: Options) async {
        countdown(o.delay)
        header("(b) AX TREE EXTRACTION")

        guard AXExtractor.isTrusted else {
            print("  SKIPPED — Accessibility not granted.")
            print("  Grant it to this binary, then re-run. Without it there is no")
            print("  primary grounding path and the whole thesis is untested.")
            return
        }

        guard let target = resolveTarget(o) else {
            print("  No target app.")
            return
        }
        print("  Target: \(target.name) (pid \(target.pid))\n")

        let space = DisplaySpace.current()
        var results: [(AXExtractor.Strategy, LatencySamples, AXTreeSnapshot?)] = []

        for strategy in AXExtractor.Strategy.allCases {
            var values: [Double] = []
            var last: AXTreeSnapshot?
            // One untimed warm-up: the first walk of a window pays for the
            // other process faulting in its accessibility machinery, and
            // that cost is not what a running coach experiences.
            _ = try? AXExtractor.windowTree(pid: target.pid, appName: target.name,
                                            bundleID: target.bundle, strategy: strategy,
                                            limits: o.limits, displays: space)
            for _ in 0..<o.trials {
                guard let snap = try? AXExtractor.windowTree(
                    pid: target.pid, appName: target.name, bundleID: target.bundle,
                    strategy: strategy, limits: o.limits, displays: space
                ) else { continue }
                values.append(snap.extractionMs)
                last = snap
            }
            results.append((strategy, LatencySamples(stage: .axExtract, values: values), last))
        }

        for (strategy, samples, snap) in results {
            guard !samples.isEmpty, let snap else {
                print("  \(strategy.rawValue): no successful extraction")
                continue
            }
            print("  \(strategy.rawValue)")
            print("    " + samples.summaryLine)
            print("    nodes \(snap.nodeCount)  labelled \(snap.labelledCount) "
                  + String(format: "(%.0f%%)", snap.labelledFraction * 100)
                  + "  actionable+labelled \(snap.actionableCount)  depth \(snap.maxDepthReached)")
            if snap.truncated { print("    TRUNCATED: \(snap.truncationReason ?? "?")") }
        }

        if let batched = results.first(where: { $0.0 == .batched })?.1,
           let naive = results.first(where: { $0.0 == .perAttribute })?.1,
           !batched.isEmpty, !naive.isEmpty, batched.p50 > 0 {
            print(String(format: "\n  Batching win: %.2fx faster at p50 (%.1f → %.1f ms)",
                         naive.p50 / batched.p50, naive.p50, batched.p50))
        }

        if let s = results.first(where: { $0.0 == .batched })?.1, !s.isEmpty {
            let ceiling = LatencyBudget.ceilingMs[.axExtract] ?? 80
            print(String(format: "\n  Budget: %.0f ms  →  %@ (p90 %.1f ms)",
                         ceiling, s.p90 <= ceiling ? "PASS" : "FAIL", s.p90))
        }
    }

    // MARK: - Snapshot for the vision benchmark

    /// Writes a window capture and its accessibility tree side by side.
    ///
    /// The pairing is the point. The vision grounder gets the PNG; the AX
    /// tree is the ground truth to score it against. Because both come from
    /// the same instant and the same window, every element's true pixel box
    /// is known exactly — which turns "is Holo1.5 pointing at the right
    /// thing" from a human judgement into an arithmetic one, and is the
    /// basis of the Phase 4 eval.
    static func snap(_ o: Options, args: [String]) async {
        countdown(o.delay)
        header("SNAPSHOT")
        var outDir = "./snap"
        if let i = args.firstIndex(of: "--out"), i + 1 < args.count { outDir = args[i + 1] }
        try? FileManager.default.createDirectory(atPath: outDir,
                                                 withIntermediateDirectories: true)

        guard CGPreflightScreenCaptureAccess() else { print("  Screen Recording not granted."); return }
        guard let w = try? await WarmCapture.frontmostWindow(named: o.app) else {
            print("  No capturable window\(o.app.map { " matching \"\($0)\"" } ?? "")."); return
        }
        let appName = w.owningApplication?.applicationName ?? "unknown"
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let config = WarmCapture.configuration(for: filter)

        guard let image = try? await OneShotCapture.screenshot(filter: filter, config: config) else {
            print("  Capture failed."); return
        }

        let slug = appName.replacingOccurrences(of: " ", with: "-").lowercased()
        let pngPath = "\(outDir)/\(slug).png"
        guard let dest = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: pngPath) as CFURL, "public.png" as CFString, 1, nil
        ) else { print("  Could not open \(pngPath)"); return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        print("  \(pngPath)  \(image.width)×\(image.height) px")

        guard let pid = w.owningApplication?.processID else { return }
        let space = DisplaySpace.current()
        guard let tree = try? AXExtractor.windowTree(
            pid: pid, appName: appName, bundleID: w.owningApplication?.bundleIdentifier,
            strategy: .batched, limits: o.limits, displays: space
        ) else { print("  AX extraction failed — PNG saved without ground truth."); return }

        // Ground truth lives in DISPLAY pixels, not window-relative pixels.
        //
        // Window-relative mapping needs a trustworthy window origin, and not
        // every app has one. Chrome reports a focused "window" covering only
        // the web content, with its own toolbar and tab strip as descendants
        // at NEGATIVE offsets above it — an AX window element is not
        // guaranteed to contain its own children. Anchoring to it silently
        // pushed all the browser chrome out of frame and produced a snapshot
        // with zero usable targets.
        //
        // Display space has no such ambiguity: AX already reports CG
        // coordinates anchored at the primary display's top-left, so the
        // mapping is one subtraction and one scale, with nothing to get wrong.
        // It is also the mapping verified pixel-exact against Logic Pro.
        var displayInfo: [String: Any] = [:]
        var displayImageSize: [Int] = []
        var scale = 0.0
        var origin = CGPoint.zero

        if let d = try? await WarmCapture.mainDisplay() {
            origin = CGPoint(x: d.frame.minX, y: d.frame.minY)
            let dFilter = SCContentFilter(display: d, excludingWindows: [])
            let dConfig = WarmCapture.configuration(for: dFilter)
            if let dImage = try? await OneShotCapture.screenshot(filter: dFilter, config: dConfig) {
                let dPath = "\(outDir)/\(slug)-display.png"
                if let dest = CGImageDestinationCreateWithURL(
                    URL(fileURLWithPath: dPath) as CFURL, "public.png" as CFString, 1, nil
                ) {
                    CGImageDestinationAddImage(dest, dImage, nil)
                    CGImageDestinationFinalize(dest)
                    scale = Double(dImage.width) / Double(d.width)
                    displayImageSize = [dImage.width, dImage.height]
                    displayInfo = ["image": "\(slug)-display.png",
                                   "image_size": displayImageSize,
                                   "scale": scale]
                    print("  \(dPath)  \(dImage.width)×\(dImage.height) px (full display, canonical frame)")
                }
            }
        }
        guard scale > 0, displayImageSize.count == 2 else {
            print("  Display capture failed — cannot build ground truth."); return
        }

        func toDisplayPx(_ r: CGRect) -> [Double] {
            [(r.minX - origin.x) * scale, (r.minY - origin.y) * scale,
             r.width * scale, r.height * scale]
        }
        let dw = Double(displayImageSize[0]), dh = Double(displayImageSize[1])
        func onScreen(_ px: [Double]) -> Bool {
            px[0] >= 0 && px[1] >= 0 && px[0] + px[2] <= dw + 1 && px[1] + px[3] <= dh + 1
        }

        var items: [[String: Any]] = []
        for n in tree.nodes where n.hasLabel && n.isActionable {
            let r = n.bounds.cg
            guard r.width > 0, r.height > 0 else { continue }
            let px = toDisplayPx(r)
            guard onScreen(px) else { continue }
            items.append([
                "id": n.id, "role": n.role, "label": n.semanticLabel,
                "title": n.title ?? "", "screen": n.bounds.screenIndex,
                "px": px, "center": [px[0] + px[2] / 2, px[1] + px[3] / 2],
            ])
        }

        // Every node, not just the pointable ones. The resolver needs the
        // containers too: on an AX miss they are what aims the vision crop,
        // and exporting them here makes the whole plan a pure function of
        // this snapshot rather than of whatever the app looks like later.
        var allNodes: [[String: Any]] = []
        for n in tree.nodes {
            let r = n.bounds.cg
            guard r.width > 0, r.height > 0 else { continue }
            let px = toDisplayPx(r)
            guard onScreen(px) else { continue }
            allNodes.append([
                "id": n.id, "parent": n.parentID ?? -1, "depth": n.depth,
                "role": n.role, "title": n.title ?? "",
                "desc": n.roleDescription ?? "", "help": n.helpText ?? "",
                "identifier": n.identifier ?? "", "enabled": n.enabled,
                "px": px,
            ])
        }

        let winRect = w.frame
        let payload: [String: Any] = [
            "app": appName,
            "nodes": allNodes,
            "window_title": tree.windowTitle ?? "",
            "image": "\(slug)-display.png",
            "image_size": displayImageSize,
            "window_image": "\(slug).png",
            "window_image_size": [image.width, image.height],
            "window_rect_px": toDisplayPx(winRect),
            "window_bounds_cg": [winRect.minX, winRect.minY, winRect.width, winRect.height],
            "ax_nodes_total": tree.nodeCount,
            "ax_extract_ms": tree.extractionMs,
            "display": displayInfo,
            "targets": items,
        ]
        let jsonPath = "\(outDir)/\(slug).json"

        // Refuse to overwrite a usable snapshot with an empty one.
        //
        // Learned the hard way: re-snapping Chrome while a video was
        // fullscreen produced an 8-node tree with zero targets and destroyed
        // the 107-node capture an evaluation depended on. Snapshots are eval
        // inputs, and a zero-target one is never the better version.
        if items.isEmpty {
            print("  REFUSING TO WRITE — 0 usable targets (tree has \(tree.nodeCount) nodes).")
            print("  The window is probably fullscreen or has no exposed chrome.")
            if FileManager.default.fileExists(atPath: jsonPath) {
                print("  Kept the existing \(jsonPath).")
            }
            return
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: jsonPath))
            print("  \(jsonPath)  \(items.count) labelled actionable targets as ground truth")
        }
    }

    // MARK: - Cold vs warm

    /// The finding that reorders the architecture.
    ///
    /// Walking an app's AX tree for the first time is one to two orders of
    /// magnitude slower than walking it again a moment later — the first
    /// query makes the target app build and vend its accessibility tree, and
    /// everything after that rides a warm path. Since the coach's job is
    /// precisely "user just switched to an app and pressed a key", the cold
    /// number is the one a naive implementation would ship with.
    ///
    /// So this measures three things: first touch, steady state, and how long
    /// warmth survives idleness. That last number decides whether extracting
    /// speculatively on focus change is enough, or whether the tree also has
    /// to be kept alive with a heartbeat.
    static func benchColdWarm(_ o: Options) {
        countdown(o.delay)
        header("AX COLD vs WARM")
        guard AXExtractor.isTrusted else { print("  Accessibility not granted."); return }
        guard let target = resolveTarget(o) else { print("  No target app."); return }

        let space = DisplaySpace.current()
        func walk() -> AXTreeSnapshot? {
            try? AXExtractor.windowTree(pid: target.pid, appName: target.name,
                                        bundleID: target.bundle, strategy: .batched,
                                        limits: o.limits, displays: space)
        }

        print("  Target: \(target.name) (pid \(target.pid))\n")

        guard let cold = walk() else { print("  No focused window over AX."); return }
        print(String(format: "  cold (first touch)      %8.2f ms   %d nodes",
                     cold.extractionMs, cold.nodeCount))

        var warm: [Double] = []
        for _ in 0..<o.trials {
            if let s = walk() { warm.append(s.extractionMs) }
        }
        let w = LatencySamples(stage: .axExtract, values: warm)
        print(String(format: "  warm (n=%d)              %8.2f ms p50   %8.2f ms p90",
                     w.count, w.p50, w.p90))
        if w.p50 > 0 {
            print(String(format: "  cold/warm ratio         %8.1fx", cold.extractionMs / w.p50))
        }

        print("\n  Decay — does the tree go cold again if left alone?")
        for pause in [1, 2, 5, 10] {
            Thread.sleep(forTimeInterval: Double(pause))
            guard let s = walk() else { continue }
            let verdict = s.extractionMs > w.p50 * 5 ? "COLD AGAIN" : "still warm"
            print(String(format: "    after %2ds idle        %8.2f ms   %@", pause, s.extractionMs, verdict))
        }

        print("""

          If warmth decays, the AXObserver-driven cache needs a heartbeat as
          well as focus-change invalidation. If it does not, extracting once
          on focus change is enough — which is the cheaper design.
        """)
    }

    // MARK: - App survey

    static func surveyApps(_ o: Options) {
        header("GROUNDABILITY SURVEY")
        guard AXExtractor.isTrusted else {
            print("  SKIPPED — Accessibility not granted.")
            return
        }
        print("  Which apps can be grounded from the accessibility tree alone.")
        print("  'labelled' is the number that predicts it: elements with no")
        print("  title, description, help or identifier are invisible to")
        print("  semantic matching and force the vision fallback.\n")
        print("  Cold is first touch; warm is the p50 of five further walks —")
        print("  what the coach actually pays if it extracts speculatively on")
        print("  focus change instead of waiting for the hotkey.\n")
        print("  " + "APP".pad(24) + "cold ms".padLeft(9) + "warm ms".padLeft(9)
              + "nodes".padLeft(7) + "label%".padLeft(8) + "action".padLeft(8)
              + "electron".padLeft(10) + "  NOTE")

        let space = DisplaySpace.current()
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

        for app in apps {
            let name = app.localizedName ?? "pid \(app.processIdentifier)"
            guard let snap = try? AXExtractor.windowTree(
                pid: app.processIdentifier, appName: name,
                bundleID: app.bundleIdentifier, strategy: .batched,
                limits: o.limits, displays: space
            ) else {
                print("  " + name.clipped(24).pad(24) + "—".padLeft(9) + "—".padLeft(9)
                      + "—".padLeft(7) + "—".padLeft(8) + "—".padLeft(8) + "—".padLeft(10)
                      + "  no focused window over AX")
                continue
            }
            var warmValues: [Double] = []
            for _ in 0..<5 {
                if let w = try? AXExtractor.windowTree(
                    pid: app.processIdentifier, appName: name,
                    bundleID: app.bundleIdentifier, strategy: .batched,
                    limits: o.limits, displays: space
                ) { warmValues.append(w.extractionMs) }
            }
            let warm = LatencySamples(stage: .axExtract, values: warmValues)
            let note = snap.truncated ? (snap.truncationReason ?? "truncated")
                     : (snap.labelledFraction < 0.33 ? "sparse labels — expect vision fallback" : "")
            print("  " + name.clipped(24).pad(24)
                  + String(format: "%.1f", snap.extractionMs).padLeft(9)
                  + (warm.isEmpty ? "—" : String(format: "%.1f", warm.p50)).padLeft(9)
                  + "\(snap.nodeCount)".padLeft(7)
                  + String(format: "%.0f%%", snap.labelledFraction * 100).padLeft(8)
                  + "\(snap.actionableCount)".padLeft(8)
                  + (snap.forcedManualAccessibility ? "forced" : "—").padLeft(10)
                  + "  " + note)
        }
    }

    // MARK: - Tree dump

    static func dumpTree(_ o: Options) {
        countdown(o.delay)
        guard AXExtractor.isTrusted else { print("Accessibility not granted."); return }
        guard let target = resolveTarget(o) else { print("No target app."); return }
        let space = DisplaySpace.current()
        guard let snap = try? AXExtractor.windowTree(
            pid: target.pid, appName: target.name, bundleID: target.bundle,
            strategy: .batched, limits: o.limits, displays: space
        ) else { print("Extraction failed for \(target.name)"); return }

        header("AX TREE — \(snap.appName)")
        print("  window: \(snap.windowTitle ?? "untitled")")
        if let b = snap.windowBounds {
            print(String(format: "  bounds: (%.0f, %.0f) %.0f×%.0f  screen %d",
                         b.cg.minX, b.cg.minY, b.cg.width, b.cg.height, b.screenIndex))
        }
        print(String(format: "  %d nodes in %.1f ms, %.0f%% labelled",
                     snap.nodeCount, snap.extractionMs, snap.labelledFraction * 100))
        if snap.truncated { print("  TRUNCATED: \(snap.truncationReason ?? "?")") }
        print("")

        for n in snap.nodes {
            let indent = String(repeating: "  ", count: n.depth)
            let box = String(format: "(%.0f,%.0f %.0f×%.0f s%d)",
                             n.bounds.cg.minX, n.bounds.cg.minY,
                             n.bounds.cg.width, n.bounds.cg.height, n.bounds.screenIndex)
            print("  \(indent)\(n.semanticLabel)  \(box)")
        }

        header("ROLE HISTOGRAM")
        for (role, count) in snap.roleHistogram.prefix(20) {
            print("  " + role.pad(28) + "\(count)")
        }
    }

    // MARK: - (a) Capture

    static func benchCapture(_ o: Options) async {
        header("(a) CAPTURE")
        guard CGPreflightScreenCaptureAccess() else {
            print("  SKIPPED — Screen Recording not granted.")
            print("  Run `screencoach-bench doctor` after granting it.")
            return
        }

        let filter: SCContentFilter
        let scopeLabel: String
        do {
            if o.scope == "display" {
                let d = try await WarmCapture.mainDisplay()
                filter = SCContentFilter(display: d, excludingWindows: [])
                scopeLabel = "display \(d.width)×\(d.height)"
            } else {
                let w = try await WarmCapture.frontmostWindow()
                filter = SCContentFilter(desktopIndependentWindow: w)
                scopeLabel = "window \"\(w.title ?? "untitled")\" of \(w.owningApplication?.applicationName ?? "?")"
            }
        } catch {
            print("  Could not build a content filter: \(error)")
            return
        }

        let config = WarmCapture.configuration(for: filter)
        print("  Scope: \(scopeLabel)")
        print("  Output: \(config.width)×\(config.height) px\n")

        // --- 1. Cold SCStream start: the tax the warm design exists to dodge.
        var coldValues: [Double] = []
        let coldTrials = Swift.max(3, Swift.min(o.trials / 5, 8))
        for _ in 0..<coldTrials {
            let cap = WarmCapture()
            if let ms = try? await cap.start(filter: filter, config: config) {
                coldValues.append(ms)
            }
            await cap.stop()
        }
        printRow("SCStream cold start", coldValues,
                 note: "session setup + first complete frame")

        // --- 2. The warm stream: what the real pipeline does.
        let warm = WarmCapture()
        guard (try? await warm.start(filter: filter, config: config)) != nil else {
            print("  Warm stream failed to start.")
            return
        }
        defer { Task { await warm.stop() } }

        // Let the stream settle so we measure steady state, not startup.
        try? await Task.sleep(nanoseconds: 400_000_000)

        var grabValues: [Double] = []
        var materializeValues: [Double] = []
        var ageValues: [Double] = []
        for _ in 0..<o.trials {
            let t0 = Mono.nowNs()
            guard let frame = try? warm.latestFrame() else { continue }
            grabValues.append(Mono.msSince(t0))
            ageValues.append(frame.ageMs)

            let t1 = Mono.nowNs()
            if (try? warm.materialize(frame)) != nil {
                materializeValues.append(Mono.msSince(t1))
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        printRow("warm grab", grabValues, note: "retrieve newest complete frame")
        printRow("warm materialize", materializeValues, note: "CVPixelBuffer → CGImage")
        printRow("frame staleness", ageValues,
                 note: "age of newest frame — the cost of not waiting")

        // --- 3. One-shot SCScreenshotManager.
        var shotValues: [Double] = []
        for _ in 0..<Swift.min(o.trials, 20) {
            let t0 = Mono.nowNs()
            if (try? await OneShotCapture.screenshot(filter: filter, config: config)) != nil {
                shotValues.append(Mono.msSince(t0))
            }
        }
        printRow("SCScreenshotManager", shotValues, note: "one-shot, no stream to keep alive")

        // --- 4. The baseline WindowPet shipped.
        var toolValues: [Double] = []
        for _ in 0..<Swift.max(3, Swift.min(o.trials / 3, 10)) {
            let t0 = Mono.nowNs()
            if OneShotCapture.viaScreencaptureTool() != nil {
                toolValues.append(Mono.msSince(t0))
            }
        }
        printRow("screencapture(1)", toolValues, note: "subprocess + PNG round trip (WindowPet's path)")

        print("\n  Stream delivered \(warm.completeFrames) complete / \(warm.idleFrames) idle frames.")
        print("  Idle frames are why the design keeps the newest complete frame")
        print("  instead of awaiting the next one: on a still screen — which is")
        print("  exactly what a user asking about a UI is looking at — the next")
        print("  frame may never arrive.")

        let grab = LatencySamples(stage: .hotkeyToFrame, values: grabValues)
        let mat = LatencySamples(stage: .frameMaterialize, values: materializeValues)
        if !grab.isEmpty && !mat.isEmpty {
            let total = grab.p90 + mat.p90
            print(String(format: "\n  Budget: hotkey→frame 50 ms  →  %@ (grab+materialize p90 = %.1f ms)",
                         total <= 50 ? "PASS" : "FAIL", total))
        }
    }

    // MARK: - Is a stale frame a wrong frame?

    /// Tests the assumption the warm-stream design rests on.
    ///
    /// Each trial takes the newest warm frame and, immediately after, a fresh
    /// one-shot capture of the same window, then measures how much of the
    /// image actually differs. If old frames are still identical to fresh
    /// ones, staleness is evidence of stillness and costs nothing. If they
    /// diverge, the design has to pay for freshness and the budget changes.
    static func benchStaleness(_ o: Options) async {
        header("IS A STALE FRAME A WRONG FRAME?")
        guard CGPreflightScreenCaptureAccess() else { print("  Screen Recording not granted."); return }
        guard let w = try? await WarmCapture.frontmostWindow(named: o.app) else {
            print("  No capturable window."); return
        }
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let config = WarmCapture.configuration(for: filter)
        let warm = WarmCapture()
        guard (try? await warm.start(filter: filter, config: config)) != nil else {
            print("  Warm stream failed to start."); return
        }
        defer { Task { await warm.stop() } }
        try? await Task.sleep(nanoseconds: 400_000_000)

        print("  Window: \(w.title ?? "untitled") of \(w.owningApplication?.applicationName ?? "?")")
        print("  Each trial: newest warm frame vs a fresh capture taken right after.\n")
        print("  aligned = content difference; raw = before correcting for the")
        print("  fact that SCStream and SCScreenshotManager frame a window")
        print("  differently. shift is the grid offset alignment needed.\n")
        print("  " + "age ms".padLeft(9) + "aligned".padLeft(10) + "raw".padLeft(10)
              + "  shift    verdict")

        var pairs: [(age: Double, diff: Double)] = []
        for _ in 0..<Swift.min(o.trials, 20) {
            guard let frame = try? warm.latestFrame(),
                  let stale = try? warm.materialize(frame) else { continue }
            let age = frame.ageMs
            guard let fresh = try? await OneShotCapture.screenshot(filter: filter, config: config),
                  let raw = FrameCompare.differenceFraction(stale, fresh),
                  let aligned = FrameCompare.alignedDifference(stale, fresh) else { continue }
            let diff = aligned.fraction
            if pairs.isEmpty {
                print("  [warm \(stale.width)×\(stale.height)  one-shot \(fresh.width)×\(fresh.height)"
                      + "  contentRect \(Int(frame.contentRect.width))×\(Int(frame.contentRect.height))"
                      + " @\(frame.contentScale)]")
                dumpPair(stale: stale, fresh: fresh)
            }
            pairs.append((age, diff))
            let verdict = diff < 0.01 ? "identical"
                        : diff < 0.05 ? "minor change (cursor, caret, meters)"
                        : "CONTENT CHANGED"
            print("  " + String(format: "%.0f", age).padLeft(9)
                  + String(format: "%.2f%%", diff * 100).padLeft(10)
                  + String(format: "%.1f%%", raw * 100).padLeft(10)
                  + String(format: "  (%+d,%+d)  ", aligned.shift.x, aligned.shift.y) + verdict)
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        guard !pairs.isEmpty else { print("\n  No samples."); return }
        let ages = LatencySamples(stage: .hotkeyToFrame, values: pairs.map(\.age))
        let diffs = pairs.map(\.diff)
        let identical = diffs.filter { $0 < 0.01 }.count
        print(String(format: "\n  frame age      p50 %.0f ms   p90 %.0f ms   max %.0f ms",
                     ages.p50, ages.p90, ages.max))
        print(String(format: "  unchanged      %d/%d trials under 1%% pixel difference",
                     identical, pairs.count))
        print("""

          READ THIS CAREFULLY — the raw column does not mean the screen is
          changing 30% per frame.

          SCStream and SCScreenshotManager place window content differently
          inside the output buffer for the SAME SCContentFilter: different
          origin AND different scale. So a large raw difference on an idle
          window is the two APIs disagreeing about framing, not content
          moving. Correcting for translation (the aligned column) removes
          part of it; the residual is the scale mismatch, which a shift
          cannot fix.

          The consequence for the coach is concrete: pixel coordinates are
          NOT interchangeable between capture paths. Whatever the vision
          fallback is handed, its coordinate mapping has to be derived from
          that same image's own geometry — SCStreamFrameInfo.contentRect for
          a stream frame — and never from window bounds assumed to start at
          image (0,0).

          What this run does NOT settle is whether an old warm frame is an
          accurate picture of the screen at hotkey time; the framing mismatch
          confounds the comparison. The indirect evidence is good — frame age
          tracks stillness, ~12 ms on an animating window versus ~291 ms on a
          static display — which is the self-correcting behaviour the design
          assumes. Worth a same-stream A/B before Phase 2 leans on it.
        """)
    }

    /// Writes both captures to disk so a suspicious difference can be looked
    /// at instead of guessed at.
    static func dumpPair(stale: CGImage, fresh: CGImage) {
        for (name, img) in [("warm-stale", stale), ("oneshot-fresh", fresh)] {
            let path = "/tmp/coach-\(name).png"
            guard let dest = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil
            ) else { continue }
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
            print("  wrote \(path)")
        }
    }

    // MARK: - Interactive end-to-end

    static func benchHotkey(_ o: Options) async {
        header("(a) HOTKEY → FRAME, END TO END")
        guard AXExtractor.isTrusted else {
            print("  Accessibility not granted — an event tap cannot be created.")
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            print("  Screen Recording not granted.")
            return
        }

        guard let w = try? await WarmCapture.frontmostWindow() else {
            print("  No capturable window.")
            return
        }
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let config = WarmCapture.configuration(for: filter)
        let warm = WarmCapture()
        guard (try? await warm.start(filter: filter, config: config)) != nil else {
            print("  Warm stream failed to start.")
            return
        }

        let trials = Swift.min(o.trials, 10)
        print("  Press Option-Space \(trials) times. Timing starts at the hardware")
        print("  event timestamp, so what you see includes event delivery.\n")

        let box = Box()
        let tap = HotKeyTap()
        tap.onHotKey = { eventNs in
            guard let frame = try? warm.latestFrame() else { return }
            let grabbed = Mono.nowNs()
            let img = try? warm.materialize(frame)
            let done = Mono.nowNs()
            let n = box.append(
                keyToFrame: Mono.ms(from: eventNs, to: grabbed),
                keyToImage: Mono.ms(from: eventNs, to: done),
                age: frame.ageMs
            )
            print(String(format: "  #%-2d  key→frame %6.2f ms   key→image %6.2f ms   frame age %6.1f ms  %@",
                         n, Mono.ms(from: eventNs, to: grabbed),
                         Mono.ms(from: eventNs, to: done), frame.ageMs,
                         img != nil ? "" : "(materialize failed)"))
            _ = n
        }
        do { try tap.start() } catch { print("  \(error)"); return }

        // The tap listens on its own thread, so waiting here is just waiting —
        // no run loop to keep spinning. Bail out after two minutes so an
        // unattended run cannot hang forever.
        let deadline = Mono.nowNs() + 120_000_000_000
        while box.count < trials && Mono.nowNs() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        tap.stop()
        await warm.stop()
        if box.count < trials { print("\n  Timed out after \(box.count)/\(trials) presses.") }

        print("")
        printRow("key→frame", box.keyToFrame, note: "hardware event → newest frame in hand")
        printRow("key→image", box.keyToImage, note: "…including CGImage materialisation")
        printRow("frame staleness", box.ages, note: "how old that frame was")
    }

    /// Samples cross a thread boundary — the tap fires on its own thread and
    /// the bench reads from the async side — so every touch takes the lock.
    final class Box {
        private let lock = NSLock()
        private var _keyToFrame: [Double] = []
        private var _keyToImage: [Double] = []
        private var _ages: [Double] = []

        var keyToFrame: [Double] { lock.lock(); defer { lock.unlock() }; return _keyToFrame }
        var keyToImage: [Double] { lock.lock(); defer { lock.unlock() }; return _keyToImage }
        var ages: [Double] { lock.lock(); defer { lock.unlock() }; return _ages }
        var count: Int { lock.lock(); defer { lock.unlock() }; return _keyToFrame.count }

        func append(keyToFrame f: Double, keyToImage i: Double, age a: Double) -> Int {
            lock.lock(); defer { lock.unlock() }
            _keyToFrame.append(f); _keyToImage.append(i); _ages.append(a)
            return _keyToFrame.count
        }
    }

    // MARK: - Helpers

    struct Target { let pid: pid_t; let name: String; let bundle: String? }

    static func resolveTarget(_ o: Options) -> Target? {
        let running = NSWorkspace.shared.runningApplications
        if let wanted = o.app?.lowercased() {
            guard let app = running.first(where: {
                ($0.localizedName ?? "").lowercased().contains(wanted)
                    || ($0.bundleIdentifier ?? "").lowercased().contains(wanted)
            }) else {
                print("  No running app matching \"\(o.app!)\".")
                return nil
            }
            return Target(pid: app.processIdentifier,
                          name: app.localizedName ?? "pid \(app.processIdentifier)",
                          bundle: app.bundleIdentifier)
        }
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        return Target(pid: front.processIdentifier,
                      name: front.localizedName ?? "pid \(front.processIdentifier)",
                      bundle: front.bundleIdentifier)
    }

    static func countdown(_ seconds: Int) {
        guard seconds > 0 else { return }
        for s in stride(from: seconds, to: 0, by: -1) {
            print("  measuring in \(s)…")
            Thread.sleep(forTimeInterval: 1)
        }
    }

    static func header(_ title: String) {
        print("\n\u{001B}[1m── \(title) " + String(repeating: "─", count: Swift.max(0, 58 - title.count)) + "\u{001B}[0m")
    }

    static func printRow(_ name: String, _ values: [Double], note: String) {
        guard !values.isEmpty else {
            print("  " + name.pad(22) + "  no samples")
            return
        }
        let s = LatencySamples(stage: .hotkeyToFrame, values: values)
        print("  " + name.pad(22) + " n=" + "\(s.count)".pad(4)
              + String(format: "p50 %8.2f  p90 %8.2f  max %8.2f ms   ", s.p50, s.p90, s.max)
              + note)
    }
}

/// Column padding done in Swift.
///
/// The obvious route — `String(format: "%-20s", (str as NSString).utf8String!)`
/// — hands `String(format:)` a pointer into an autoreleased NSString that is
/// already gone by the time it is read. It prints fine for a while and then
/// segfaults, which is precisely what it did here.
private extension String {
    func pad(_ width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
    func padLeft(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
    func clipped(_ width: Int) -> String {
        count <= width ? self : String(prefix(width - 1)) + "…"
    }
}

private extension Array where Element == String {
    func string(at i: Int) -> String? { indices.contains(i) ? self[i] : nil }
    func int(at i: Int) -> Int? { string(at: i).flatMap(Int.init) }
}
