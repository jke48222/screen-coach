import AppKit
import ScreenCoachCore
import ScreenCoachKit

/// The coach.
///
/// Hold the shortcut and say what you are looking for — or tap it and type —
/// and a cursor flies to the exact control. The accessibility tree answers
/// first, in about a millisecond; Holo1.5 runs locally only when the tree
/// cannot see the control; speech in and out are on-device. No cloud, no
/// network, nothing persisted.
///
/// That is already a different product from the state of the art: pure-vision
/// grounders are right 58% of the time on dense professional UIs, and are
/// confidently wrong the rest. This one either knows, says it is guessing, or
/// declines — and it never looks at an excluded app at all.
@main
final class ScreenCoachApp: NSObject, NSApplicationDelegate {

    private let cache = AXCache()
    private let overlay = OverlayController()
    private let commandBar = CommandBar()
    private var hotkey: HotKeyTap?
    private var statusItem: NSStatusItem?
    private var lastTrace = LatencyTrace()

    private let exclusions = ExclusionStore()
    private let voice = Voice()
    private lazy var lessons = LessonRunner(cache: cache)
    private lazy var recorder = WorkflowRecorder(cache: cache)
    private let lessonStore = LessonStore()
    private var teachSubmenu: NSMenu?
    private var recordItem: NSMenuItem?
    /// When the hold began, so a quick tap can be told from a spoken hold.
    private var holdStartedNs: UInt64 = 0
    private var spokeThisTurn = false
    /// Vision runs off the main thread and strictly serially — one 5.6 GB
    /// model, one query at a time.
    private let visionQueue = DispatchQueue(label: "coach.vision", qos: .userInitiated)
    private lazy var grounding = GroundingService(
        serverScript: Self.toolsDirectory.appendingPathComponent("holo_server.py"),
        modelPath: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("models/holo1.5-7b-4bit").path
    )

    /// Tools live beside the app when bundled, and beside the package when
    /// running from `swift build`. Try the bundle first, then the source tree.
    private static var toolsDirectory: URL {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Tools")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ScreenCoachApp
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Tools")
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = ScreenCoachApp()
        app.delegate = delegate
        // Accessory, not regular: no Dock icon, and summoning the coach never
        // steals frontmost status from the app being taught.
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--lessontest") {
            runLessonTest()
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--idlebench") {
            let seconds = CommandLine.arguments[safe: i + 1].flatMap(Int.init) ?? 60
            runIdleBench(seconds: seconds,
                         forceActive: CommandLine.arguments.contains("--force-active"))
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--selftest") {
            let query = CommandLine.arguments[safe: i + 1] ?? "the close button"
            let app = CommandLine.arguments.firstIndex(of: "--app")
                .flatMap { CommandLine.arguments[safe: $0 + 1] }
            runSelfTest(query: query, appName: app)
            return
        }

        buildStatusItem()
        overlay.rebuildForCurrentDisplays()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.overlay.rebuildForCurrentDisplays() }

        commandBar.onQueryChanged = { [weak self] q in self?.preview(q) }
        commandBar.onSubmit = { [weak self] q in self?.resolveAndPoint(q) }
        commandBar.onCancel = { [weak self] in
            self?.commandBar.dismiss()
            self?.overlay.hide()
        }

        guard AXExtractor.isTrusted else {
            promptForAccessibility()
            return
        }
        startServices()
    }

    private func startServices() {
        // Wire the privacy gate in before the cache ever runs, so no excluded
        // app is ever read even once.
        cache.exclusionCheck = { [weak self] bundleID, title in
            guard let self else { return nil }
            let v = self.exclusions.check(bundleID: bundleID, windowTitle: title)
            return v.excluded ? (v.reason ?? "excluded") : nil
        }
        cache.start()
        wireVoice()
        wireLessons()

        let tap = HotKeyTap(binding: .optionSpace)
        tap.onHotKey = { [weak self] eventNs in
            DispatchQueue.main.async { self?.summon(at: eventNs) }
        }
        tap.onHotKeyUp = { [weak self] _ in
            DispatchQueue.main.async { self?.releaseHold() }
        }
        do { try tap.start() } catch {
            NSLog("ScreenCoach: hotkey tap failed — \(error)")
        }
        hotkey = tap
    }

    // MARK: - Teaching

    private func wireLessons() {
        lessons.onStep = { [weak self] progress, step in
            guard let self else { return }
            guard let step else {
                self.overlay.hide()
                self.voice.speak("That's it — \(progress.lesson.title) done.")
                NSLog("ScreenCoach: lesson finished")
                return
            }
            self.showStep(progress, step)
        }
        lessons.onAdvance = { [weak self] number, ms in
            NSLog(String(format: "ScreenCoach: step %d completed by the user in %.1f s",
                         number, ms / 1000))
            _ = self
        }
    }

    /// Point at the step, dim everything else, number it, and say it.
    ///
    /// The scrim is the affordance that turns pointing into teaching: during a
    /// step the rest of the screen recedes and the control you need is the
    /// only lit thing. A one-shot answer never does this — dimming the whole
    /// screen to answer a quick question would be obnoxious.
    private func showStep(_ progress: LessonProgress, _ rawStep: Step) {
        guard let tree = cache.tree() else { return }
        let step = rawStep.resolved(appName: tree.appName)
        let ranked = AXResolver.rank(query: step.target, in: tree.nodes,
                                     windowBounds: extent(of: tree), limit: 1)
        guard let best = ranked.first else {
            // The step's target is not on screen yet — normal at the start of
            // a step whose predecessor opened a menu. Say the instruction and
            // let the watcher catch up.
            commandBar.setStatus(progress.caption)
            voice.speak(step.instruction)
            return
        }
        let confident = best.score >= AXResolver.hitThreshold
        overlay.teach(step: best.node.bounds,
                      caption: progress.caption,
                      stepNumber: progress.stepNumber,
                      confidence: confident ? .exact : .uncertain)
        voice.speak(step.instruction)
    }

    @objc private func startLesson(_ sender: NSMenuItem) {
        guard let lesson = BuiltInLessons.all[safe: sender.tag] else { return }
        commandBar.dismiss()
        lessons.start(lesson)
    }

    @objc private func startSavedLesson(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL,
              let lesson = lessonStore.load(url) else { return }
        // A recording is app-specific in fact even though its steps are
        // semantic — warn rather than block when replayed elsewhere, because
        // re-grounding against a different app is allowed to work and
        // sometimes does (menus and toolbars share vocabulary).
        if let wanted = lesson.bundleID, let current = cache.tree()?.bundleID,
           wanted != current {
            voice.speak("This was recorded in a different app. I'll try anyway.")
        }
        commandBar.dismiss()
        lessons.start(lesson)
    }

    // MARK: - Recording

    @objc private func toggleRecording() {
        if recorder.isRecording {
            stopRecordingAndSave()
            return
        }
        recorder.onStep = { [weak self] recorded, count in
            self?.commandBar.setStatus("recorded \(count): \(recorded.clickedLabel)")
            NSLog("ScreenCoach: recorded step \(count) — \(recorded.step.target)")
        }
        recorder.onSkipped = { reason in
            NSLog("ScreenCoach: click skipped — \(reason)")
        }
        do {
            try recorder.start()
            recordItem?.title = "Stop Recording & Save"
            voice.speak("Recording. Click through the steps, then stop from the menu.")
        } catch {
            NSLog("ScreenCoach: recorder failed — \(error)")
        }
    }

    private func stopRecordingAndSave() {
        recordItem?.title = "Record a Workflow"
        guard let lesson = recorder.finish() else {
            voice.speak("Nothing recorded.")
            return
        }
        do {
            let url = try lessonStore.save(lesson)
            voice.speak("Saved \(lesson.steps.count) steps.")
            NSLog("ScreenCoach: workflow saved to \(url.path)")
        } catch {
            NSLog("ScreenCoach: save failed — \(error)")
        }
    }

    @objc private func stopLesson() {
        lessons.stop()
        overlay.hide()
    }

    // MARK: - Voice

    private func wireVoice() {
        voice.onPartial = { [weak self] text in
            // Live transcript goes straight into the same field typing uses,
            // so the two input paths converge before anything downstream has
            // to care which one produced the query.
            self?.commandBar.setQuery(text)
            self?.preview(text)
        }
        voice.onFinal = { [weak self] text, sttMs in
            guard let self else { return }
            self.lastTrace.record(.stt, ms: sttMs)
            self.spokeThisTurn = true
            self.resolveAndPoint(text)
        }
        voice.onState = { [weak self] state in
            self?.commandBar.setStatus(state)
        }
    }

    /// Hold to speak, tap to type.
    ///
    /// The distinction is made on release rather than by a timer, so a hold
    /// that turns out to be short still delivers whatever was said. Under the
    /// threshold with nothing heard, the bar simply stays open for typing —
    /// which is also the graceful path when the microphone is unavailable.
    private func releaseHold() {
        let heldMs = holdStartedNs == 0 ? 0 : Mono.msSince(holdStartedNs)
        holdStartedNs = 0
        guard voice.isListening else { return }
        if heldMs < 300 {
            voice.cancel()
            commandBar.setStatus("type a target, or hold ⌥Space to speak")
            return
        }
        voice.end()
    }

    // MARK: - The turn

    private func summon(at eventNs: UInt64) {
        lastTrace = LatencyTrace()
        lastTrace.begin(.hotkeyToFrame, at: eventNs)

        // The tree is already warm — this is the payoff for the speculative
        // extraction Phase 0 proved mandatory. Reading it here costs about a
        // millisecond instead of the 45–220 ms a cold walk would.
        lastTrace.begin(.axExtract)
        let tree = cache.tree()
        lastTrace.end(.axExtract)
        lastTrace.end(.hotkeyToFrame)

        guard let tree else {
            commandBar.present(status: "No accessible window in front.")
            return
        }
        let labelled = tree.labelledCount
        let status = String(
            format: "%@ · %d controls · tree %.0f ms old",
            tree.appName, labelled, cache.cachedEntry?.ageMs ?? 0
        )
        commandBar.present(status: status)

        // Start capturing immediately on key-down. Waiting to decide whether
        // this is a hold or a tap would clip the first word, which is usually
        // the one that names the target.
        spokeThisTurn = false
        holdStartedNs = Mono.nowNs()
        if case .ready = voice.availability { voice.begin() }
    }

    /// Live shortlist as the user types. Cheap enough to run on every
    /// keystroke — the resolver is a lexical scan measured at 0.067 ms.
    private func preview(_ query: String) {
        guard query.count >= 2, let tree = cache.cachedEntry?.snapshot else {
            commandBar.showSuggestions([])
            return
        }
        let ranked = AXResolver.rank(query: query, in: tree.nodes,
                                     windowBounds: extent(of: tree), limit: 3)
        commandBar.showSuggestions(ranked.map { c in
            String(format: "%.2f  %@", c.score, c.node.semanticLabel.prefix(64) as CVarArg)
        })
    }

    private func resolveAndPoint(_ query: String) {
        guard let tree = cache.tree() else { return }
        let bounds = extent(of: tree)

        lastTrace.begin(.axResolve)
        let ranked = AXResolver.rank(query: query, in: tree.nodes,
                                     windowBounds: bounds, limit: 3)
        lastTrace.end(.axResolve)
        commandBar.dismiss()

        let axCandidate = ranked.first.map {
            Fusion.AXCandidate(bounds: $0.node.bounds, score: $0.score,
                               label: $0.node.title ?? $0.node.roleDescription
                                      ?? $0.node.humanRole)
        }

        // Does this even need vision? Measured at ~1.7 ms per image token, so
        // the answer is no whenever the tree already answered well — checking
        // a confident hit would trade two seconds for a second opinion that is
        // right 58% of the time.
        let wantsVision = Fusion.needsVision(
            axScore: axCandidate?.score, axHitThreshold: AXResolver.hitThreshold,
            labelledFraction: tree.labelledFraction
        )

        guard wantsVision else {
            present(Fusion.decide(ax: axCandidate, vision: nil,
                                  axHitThreshold: AXResolver.hitThreshold),
                    query: query, tree: tree)
            return
        }

        // The privacy gate comes before the capture, not after. A frame that
        // exists and is then discarded has still existed.
        let verdict = exclusions.check(bundleID: tree.bundleID, windowTitle: tree.windowTitle)
        guard !verdict.excluded else {
            present(Fusion.decide(ax: axCandidate, vision: nil,
                                  axHitThreshold: AXResolver.hitThreshold),
                    query: query, tree: tree,
                    note: "not captured — \(verdict.reason ?? "excluded")")
            return
        }

        // Show the tree's answer immediately rather than making the user wait
        // on the model. The pointer is already flying while vision runs, and
        // the ring is upgraded or downgraded when the second opinion lands.
        present(Fusion.decide(ax: axCandidate, vision: nil,
                              axHitThreshold: AXResolver.hitThreshold),
                query: query, tree: tree,
                note: axCandidate == nil ? "looking…" : "checking…")

        visionQueue.async { [weak self] in
            guard let self else { return }
            let vision = self.runVision(query: query, tree: tree, ax: axCandidate)
            DispatchQueue.main.async {
                guard vision != nil || axCandidate != nil else {
                    self.notify("Nothing in \(tree.appName) matches “\(query)”.")
                    return
                }
                self.present(Fusion.decide(ax: axCandidate, vision: vision,
                                           axHitThreshold: AXResolver.hitThreshold),
                             query: query, tree: tree)
            }
        }
    }

    /// Capture, aim, ground. Runs off the main thread; everything it needs
    /// about the target was captured in `tree` before it started.
    private func runVision(query: String, tree: AXTreeSnapshot,
                           ax: Fusion.AXCandidate?) -> Fusion.VisionCandidate? {
        guard grounding.startIfNeeded() else {
            NSLog("ScreenCoach: \(grounding.statusLine)")
            return nil
        }
        guard let shot = ScreenGrab.display(containing: extent(of: tree)) else { return nil }

        // Aim the crop with the tree even though the tree could not answer.
        // Phase 0 measured this at full-frame accuracy for a third of the
        // latency; the sidecar test above showed 1337 ms versus 9676 ms on the
        // same target.
        let hint = AXResolver.cropHint(query: query, in: tree.nodes,
                                       windowBounds: extent(of: tree))
        let cropPixels = hint.isWholeWindow ? nil : CGRect(
            x: (hint.rect.cg.minX - shot.origin.x) * shot.scale,
            y: (hint.rect.cg.minY - shot.origin.y) * shot.scale,
            width: hint.rect.cg.width * shot.scale,
            height: hint.rect.cg.height * shot.scale
        )

        let started = Mono.nowNs()
        let result = grounding.ground(
            image: shot.image, query: query, cropPixels: cropPixels,
            screenIndex: shot.screenIndex, displayScale: shot.scale,
            displayOrigin: shot.origin
        )
        DispatchQueue.main.async { [weak self] in
            self?.lastTrace.record(.visionGround, ms: Mono.msSince(started))
        }
        guard let result else { return nil }
        NSLog(String(format: "ScreenCoach: vision %.0f ms ttft, %d tokens%@",
                     result.ttftMs, result.imageTokens,
                     cropPixels == nil ? " (full frame)" : " (AX-aimed crop)"))
        return Fusion.VisionCandidate(point: result.point)
    }

    private func present(_ decision: Fusion.Decision?, query: String,
                         tree: AXTreeSnapshot, note: String? = nil) {
        guard let decision else {
            notify("Nothing in \(tree.appName) matches “\(query)”.")
            return
        }
        var caption = decision.label
        if decision.confidence == .uncertain { caption += "?" }
        if let note { caption += "  ·  \(note)" }

        lastTrace.begin(.pointerStart)
        overlay.point(at: decision.target, caption: caption,
                      confidence: decision.confidence == .exact ? .exact : .uncertain)
        lastTrace.end(.pointerStart)

        if let why = decision.explanation { NSLog("ScreenCoach: \(why)") }
        NSLog("ScreenCoach: “\(query)” → \(decision.label) [\(decision.source.rawValue)]")

        // Speak only when spoken to. A voice that answers typed input is
        // startling in a shared office, and note never speaks — a spoken
        // "checking…" would be interrupted by the real answer a beat later.
        if spokeThisTurn && note == nil { voice.speak(spokenAnswer(for: decision)) }
    }

    /// The reference extent is the union of the tree's node bounds, never a
    /// window frame — Phase 0 found apps whose AX window element excludes its
    /// own children, and apps whose one window is three `SCWindow`s.
    private func extent(of tree: AXTreeSnapshot) -> ScreenRect {
        let union = tree.nodes.reduce(CGRect.null) { $0.union($1.bounds.cg) }
        if union.isNull {
            return tree.windowBounds ?? ScreenRect(cg: .zero, screenIndex: 0)
        }
        return ScreenRect(cg: union,
                          screenIndex: tree.windowBounds?.screenIndex
                              ?? DisplaySpace.current().index(bestOverlapping: union) ?? 0)
    }

    private func logTiming(query: String, best: AXResolver.Candidate, tree: AXTreeSnapshot) {
        let ax = lastTrace.samples(for: .axExtract)
        let resolve = lastTrace.samples(for: .axResolve)
        NSLog(String(format:
            "ScreenCoach: “%@” → %@ (%.2f) | tree %d nodes, read %.2f ms, resolve %.3f ms",
            query, best.node.title ?? best.node.role, best.score,
            tree.nodeCount, ax.p50, resolve.p50))
    }

    /// Exercises the teaching loop headlessly.
    ///
    /// Auto-advance is the claim that separates this from a tutorial video, so
    /// it gets verified rather than demoed: build a lesson whose completion
    /// condition is something this process can cause on its own, run the
    /// watcher, and check it fires. No screenshots, no human.
    private func runLessonTest() {
        guard AXExtractor.isTrusted else { print("Accessibility not granted."); exit(2) }
        cache.exclusionCheck = { [weak self] b, t in
            guard let self else { return nil }
            let v = self.exclusions.check(bundleID: b, windowTitle: t)
            return v.excluded ? (v.reason ?? "excluded") : nil
        }
        cache.start()
        overlay.rebuildForCurrentDisplays()
        Thread.sleep(forTimeInterval: 0.6)

        guard let tree = cache.tree(), !tree.nodes.isEmpty else {
            print("No accessible frontmost window."); exit(3)
        }
        print("App        \(tree.appName) — \(tree.nodeCount) nodes")

        // Two synthetic trees standing in for before/after, so the engine is
        // exercised against this app's real labels rather than fixtures.
        let before = tree.nodes
        guard let sample = before.first(where: { $0.isActionable && $0.hasLabel }),
              let label = sample.title ?? sample.roleDescription else {
            print("No labelled actionable element to build a step from."); exit(4)
        }
        let query = "the \(label) button"
        print("Step       “\(query)”")

        var after = before
        if let idx = after.firstIndex(where: { $0.id == sample.id }) {
            // Move it: the engine treats a moved control as evidence a panel
            // opened around it.
            let moved = AXNode(
                id: sample.id, parentID: sample.parentID, depth: sample.depth,
                role: sample.role, subrole: sample.subrole, title: sample.title,
                roleDescription: sample.roleDescription, helpText: sample.helpText,
                valueText: (sample.valueText ?? "") + "-changed",
                identifier: sample.identifier, enabled: sample.enabled,
                bounds: sample.bounds)
            after[idx] = moved
        }

        let unchanged = LessonEngine.isSatisfied(.targetChanges, target: query,
                                                 before: before, after: before)
        let changed = LessonEngine.isSatisfied(.targetChanges, target: query,
                                               before: before, after: after)
        print("Detect     unchanged tree → \(unchanged ? "COMPLETE (wrong)" : "pending (correct)")")
        print("Detect     value changed  → \(changed ? "COMPLETE (correct)" : "pending (WRONG)")")

        // Now the live runner, with a lesson whose only step is manual, to
        // confirm it renders and does not spuriously auto-advance.
        var advanced = false
        lessons.onAdvance = { _, _ in advanced = true }
        lessons.onStep = { [weak self] progress, step in
            guard let step else { print("Lesson     finished"); return }
            print("Lesson     showing \(progress.caption)")
            guard let self, let t = self.cache.tree() else { return }
            if let best = AXResolver.rank(query: step.target, in: t.nodes,
                                          windowBounds: self.extent(of: t), limit: 1).first {
                self.overlay.teach(step: best.node.bounds, caption: progress.caption,
                                   stepNumber: progress.stepNumber,
                                   confidence: best.score >= AXResolver.hitThreshold
                                       ? .exact : .uncertain)
                print(String(format: "Render     scrim + badge %d on %@ (score %.2f)",
                             progress.stepNumber, best.node.title ?? best.node.role, best.score))
            }
        }
        lessons.start(Lesson(title: "Self test", steps: [
            Step(instruction: "Look at this control", target: query, completion: .manual),
        ]))

        // "Watch me" mode, verified without a human clicking: hit-test a real
        // element's own centre (what a click there would resolve to), build
        // the step a recording would produce, round-trip it through disk, and
        // replay the loaded copy. The file is the artifact that travels to
        // another machine, so the file is what gets replayed.
        var watchOK = true
        let centre = CGPoint(x: sample.bounds.cg.midX, y: sample.bounds.cg.midY)
        if let hit = WorkflowInference.hitTest(centre, in: before) {
            let same = hit.id == sample.id
            print("HitTest    centre of “\(label)” → \(hit.title ?? hit.role) "
                  + (same ? "(exact)" : "(different element — acceptable if nested)"))
        } else {
            print("HitTest    FAILED — centre of a labelled element resolved to nothing")
            watchOK = false
        }
        if let recordedQuery = WorkflowInference.semanticQuery(for: sample, in: before) {
            print("Record     synthesized “\(recordedQuery)”")
            let store = LessonStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("coach-lessontest-\(UUID().uuidString)"))
            let lesson = Lesson(title: "Recorded self test", bundleID: tree.bundleID, steps: [
                Step(instruction: "Click \(label)", target: recordedQuery, completion: .manual),
            ])
            if let url = try? store.save(lesson), let loaded = store.load(url) {
                let ranked = AXResolver.rank(query: loaded.steps[0].target, in: before,
                                             windowBounds: extent(of: tree), limit: 1)
                if let best = ranked.first, best.score >= AXResolver.hitThreshold {
                    print(String(format: "Replay     loaded from disk, re-grounded at %.2f — %@",
                                 best.score, best.node.title ?? best.node.role))
                } else {
                    print("Replay     FAILED — saved query did not re-ground")
                    watchOK = false
                }
                try? FileManager.default.removeItem(at: store.directory)
            } else {
                print("Replay     FAILED — save/load round trip broke")
                watchOK = false
            }
        } else {
            print("Record     FAILED — no query for a labelled element")
            watchOK = false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            print("Watcher    \(advanced ? "auto-advanced (WRONG for a .manual step)" : "held on the manual step (correct)")")
            self.lessons.advance()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                print("Manual     advance → \(self.lessons.isRunning ? "still running" : "lesson complete")")
                exit(unchanged || !changed || !watchOK ? 1 : 0)
            }
        }
    }

    // MARK: - Idle bench

    /// What does the coach cost when nobody is using it?
    ///
    /// WindowPet's discipline, inherited: an always-running accessory app has
    /// to know its own idle draw, because "small" background costs are how a
    /// laptop's battery dies of a thousand cuts. The dominant term here is
    /// the AXCache heartbeat — a full tree walk of the frontmost app every
    /// three seconds, forever — so this starts exactly the services the real
    /// app runs at idle (cache, hotkey tap, exclusion gate) and reads its own
    /// rusage over the window. No overlay, no voice, no vision: those all
    /// cost zero until summoned.
    private func runIdleBench(seconds: Int, forceActive: Bool) {
        guard AXExtractor.isTrusted else { print("Accessibility not granted."); exit(2) }
        cache.exclusionCheck = { [weak self] b, t in
            guard let self else { return nil }
            let v = self.exclusions.check(bundleID: b, windowTitle: t)
            return v.excluded ? (v.reason ?? "excluded") : nil
        }
        cache.idleBackoffEnabled = !forceActive
        cache.start()
        let tap = HotKeyTap(binding: .optionSpace)
        try? tap.start()
        hotkey = tap

        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let u = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            let sys = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
            return u + sys
        }

        // Let startup settle so the measurement is steady state, not launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [self] in
            let cpu0 = cpuSeconds()
            let refreshes0 = cache.refreshes
            let t0 = Mono.nowNs()
            print("Measuring \(seconds)s of idle"
                  + (forceActive ? " (backoff disabled — active-user mode)" : "")
                  + " over \(cache.cachedEntry?.snapshot.appName ?? "no app")…")

            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) { [self] in
                let wall = Mono.msSince(t0) / 1000
                let cpu = cpuSeconds() - cpu0
                let beats = cache.refreshes - refreshes0
                print(String(format: "CPU        %.2f%% of one core (%.3fs CPU over %.1fs wall)",
                             cpu / wall * 100, cpu, wall))
                print("Refreshes  \(beats) tree walks in the window")
                print(String(format: "Memory     %.1f MB resident", residentMB()))
                exit(0)
            }
        }
    }

    private func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1e6 : 0
    }

    // MARK: - Self test

    /// End-to-end without a human: warm the cache, resolve a real query
    /// against the frontmost app, print every coordinate the pointer will
    /// use, and draw it. Prints geometry rather than taking a screenshot —
    /// this app exists to look at whatever the user has open, so verifying it
    /// should not mean capturing their screen.
    private func runSelfTest(query: String, appName: String?) {
        guard AXExtractor.isTrusted else {
            print("Accessibility not granted — cannot self-test.")
            exit(2)
        }
        overlay.rebuildForCurrentDisplays()
        cache.exclusionCheck = { [weak self] bundleID, title in
            guard let self else { return nil }
            let v = self.exclusions.check(bundleID: bundleID, windowTitle: title)
            return v.excluded ? (v.reason ?? "excluded") : nil
        }
        cache.start()

        // Targeting a named app is a test affordance, not a product feature:
        // it lets the pipeline be verified against an app that is not
        // frontmost, which matters because some apps stop vending a focused
        // window the moment they lose focus.
        if let appName {
            guard let match = NSWorkspace.shared.runningApplications.first(where: {
                ($0.localizedName ?? "").lowercased().contains(appName.lowercased())
            }) else { print("No running app matching “\(appName)”."); exit(5) }
            cache.pin(to: match.processIdentifier)
            print("Pinned to \(match.localizedName ?? "?") (pid \(match.processIdentifier))")
        }

        print("Warming the tree…")
        var warmTimes: [Double] = []
        for _ in 0..<5 {
            let t0 = Mono.nowNs()
            _ = cache.tree()
            warmTimes.append(Mono.msSince(t0))
            usleep(120_000)
        }
        if let why = cache.lastExclusionReason {
            print("Privacy    EXCLUDED — \(why)")
            print("           No tree read, no frame captured. Nothing to point at.")
            exit(0)
        }
        guard let tree = cache.tree() else {
            // Say *why*, not just that it failed.
            let me = ProcessInfo.processInfo.processIdentifier
            print("No accessible window. Diagnosing:")
            print("  trusted: \(AXExtractor.isTrusted)   self pid: \(me)")
            print("  frontmost: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")"
                  + " pid \(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)")
            for app in NSWorkspace.shared.runningApplications
            where app.activationPolicy == .regular && !app.isTerminated {
                let name = app.localizedName ?? "?"
                do {
                    let t = try AXExtractor.windowTree(
                        pid: app.processIdentifier, appName: name,
                        bundleID: app.bundleIdentifier)
                    print("  \(name): \(t.nodeCount) nodes OK")
                } catch {
                    print("  \(name): \(error)")
                }
            }
            exit(3)
        }
        let serve = LatencySamples(stage: .axExtract, values: warmTimes)

        print(String(format: "App        %@ — %d nodes, %d labelled, %d actionable",
                     tree.appName, tree.nodeCount, tree.labelledCount, tree.actionableCount))
        print(String(format: "Cache      serve p50 %.3f ms, p90 %.3f ms (%d warm / %d cold)",
                     serve.p50, serve.p90, cache.servedWarm, cache.servedCold))

        let bounds = extent(of: tree)
        let t0 = Mono.nowNs()
        let ranked = AXResolver.rank(query: query, in: tree.nodes,
                                     windowBounds: bounds, limit: 3)
        let resolveMs = Mono.msSince(t0)
        print(String(format: "Resolve    %.3f ms for “%@”", resolveMs, query))

        if ranked.isEmpty {
            // Not a failure — this is precisely the case the vision fallback
            // exists for, so the self-test must carry on into it rather than
            // stopping where the accessibility path stops.
            print("Resolve    no accessibility match — this is the AX-miss path")
        }
        for (i, c) in ranked.enumerated() {
            print(String(format: "  %d. %.2f  %@  cg=(%.0f,%.0f %.0f×%.0f) screen %d",
                         i + 1, c.score, c.node.semanticLabel.prefix(52) as CVarArg,
                         c.node.bounds.cg.minX, c.node.bounds.cg.minY,
                         c.node.bounds.cg.width, c.node.bounds.cg.height,
                         c.node.bounds.screenIndex))
        }

        if let best = ranked.first {
        // Show the CG→AppKit→panel-local chain explicitly. This is the
        // conversion that puts the pointer on the wrong monitor when it is
        // wrong, so the self-test prints it rather than trusting it.
        let space = DisplaySpace.current()
        let ak = space.appKitRect(fromCG: best.node.bounds.cg)
        print(String(format: "Convert    cg(%.0f,%.0f) → appkit(%.0f,%.0f)  [primary height %.0f]",
                     best.node.bounds.cg.minX, best.node.bounds.cg.minY,
                     ak.minX, ak.minY, space.primaryHeight))
        if let screen = NSScreen.screens[safe: best.node.bounds.screenIndex] {
            print(String(format: "           → panel-local(%.0f,%.0f) on screen %d %@",
                         ak.minX - screen.frame.minX, ak.minY - screen.frame.minY,
                         best.node.bounds.screenIndex,
                         screen.frame.contains(CGPoint(x: ak.midX, y: ak.midY))
                            ? "✓ inside screen" : "✗ OUTSIDE SCREEN"))
        }
        }

        // Route the self-test through the same fusion policy the product uses,
        // so what it prints is what a real query would do rather than a
        // parallel code path that can drift.
        let axCandidate = ranked.first.map {
            Fusion.AXCandidate(
                bounds: $0.node.bounds, score: $0.score,
                label: $0.node.title ?? $0.node.roleDescription ?? $0.node.humanRole
            )
        }
        let wantsVision = Fusion.needsVision(
            axScore: axCandidate?.score, axHitThreshold: AXResolver.hitThreshold,
            labelledFraction: tree.labelledFraction
        )
        let verdict = exclusions.check(bundleID: tree.bundleID, windowTitle: tree.windowTitle)
        print("Privacy    \(verdict.excluded ? "EXCLUDED — \(verdict.reason ?? "")" : "allowed") "
              + "(\(exclusions.statusLine))")
        switch voice.availability {
        case .ready(let onDevice):
            print("Voice      ready — recognition \(onDevice ? "ON-DEVICE" : "SERVER-BACKED")")
        case .needsPermission(let what):
            print("Voice      \(what) permission not granted yet (\(Voice.permissionSummary))")
        case .unavailable(let why):
            print("Voice      unavailable — \(why)")
        }
        print("Route      \(wantsVision ? "vision fallback would run" : "accessibility only — vision not needed")")

        var visionCandidate: Fusion.VisionCandidate?
        if wantsVision && !verdict.excluded && CommandLine.arguments.contains("--vision") {
            print("Vision     loading model…")
            visionCandidate = runVision(query: query, tree: tree, ax: axCandidate)
            if let v = visionCandidate {
                print(String(format: "           click cg(%.0f,%.0f) screen %d",
                             v.point.cg.x, v.point.cg.y, v.point.screenIndex))
            } else {
                print("           unavailable — \(grounding.statusLine)")
            }
        }

        guard let decision = Fusion.decide(ax: axCandidate, vision: visionCandidate,
                                           axHitThreshold: AXResolver.hitThreshold) else {
            print("No decision."); exit(4)
        }
        print("Fusion     \(decision.source.rawValue) → "
              + "\(decision.confidence == .exact ? "exact — solid ring" : "uncertain — dashed ring")")
        if let why = decision.explanation { print("           \(why)") }

        overlay.point(at: decision.target,
                      caption: decision.label + (decision.confidence == .exact ? "" : "?"),
                      confidence: decision.confidence == .exact ? .exact : .uncertain,
                      dismissAfter: 2.5)
        print("Pointing for 3s…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { exit(0) }
    }

    // MARK: - Chrome

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Screen Coach"
        )
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        let status = NSMenuItem(title: "…", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Point at Something…  ⌥Space",
                                action: #selector(summonFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Refresh Tree Now",
                                action: #selector(refreshNow), keyEquivalent: ""))
        menu.addItem(.separator())
        let teach = NSMenuItem(title: "Teach Me…", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (i, lesson) in BuiltInLessons.all.enumerated() {
            let item = NSMenuItem(title: lesson.title, action: #selector(startLesson(_:)),
                                  keyEquivalent: "")
            item.tag = i
            item.target = self
            sub.addItem(item)
        }
        sub.addItem(.separator())
        let record = NSMenuItem(title: "Record a Workflow",
                                action: #selector(toggleRecording), keyEquivalent: "")
        record.target = self
        sub.addItem(record)
        recordItem = record
        let stop = NSMenuItem(title: "Stop Teaching", action: #selector(stopLesson),
                              keyEquivalent: "")
        stop.target = self
        sub.addItem(stop)
        teach.submenu = sub
        teachSubmenu = sub
        menu.addItem(teach)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Screen Coach",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        for i in menu.items where i.action != nil && i.action != #selector(NSApplication.terminate(_:)) {
            i.target = self
        }
        // Refresh the status line each time the menu opens rather than on a
        // timer — nobody is reading it while it is closed.
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    @objc private func summonFromMenu() { summon(at: Mono.nowNs()) }
    @objc private func refreshNow() { _ = cache.tree() }

    /// What the coach says out loud. Short, and it carries the same
    /// uncertainty the ring does — a confident sentence over a dashed ring
    /// would undo the whole point of drawing the dashes.
    private func spokenAnswer(for decision: Fusion.Decision) -> String {
        switch decision.confidence {
        case .exact:
            return decision.source == .corroborated
                ? "Here. \(decision.label)."
                : "Here's \(decision.label)."
        case .uncertain:
            switch decision.source {
            case .vision:
                return "I can't see this one in the accessibility tree, "
                     + "so this is my best guess."
            case .conflicted:
                return "I think it's \(decision.label), but I'm not certain."
            default:
                return "Maybe \(decision.label). I'm not sure."
            }
        }
    }

    private func notify(_ text: String) {
        commandBar.present(status: text)
    }

    private func promptForAccessibility() {
        let alert = NSAlert()
        alert.messageText = "Screen Coach needs Accessibility access"
        alert.informativeText = """
        The coach reads the accessibility tree of whatever app is in front so \
        it can point at exact controls. That is the whole product — without \
        this permission there is nothing to point at.

        Nothing is recorded, stored, or sent anywhere.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertFirstButtonReturn {
            AXExtractor.requestPermission()
            // Grant-while-running has no notification; poll for it.
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
                guard AXExtractor.isTrusted else { return }
                t.invalidate()
                self?.startServices()
            }
        } else {
            NSApp.terminate(nil)
        }
    }
}

extension ScreenCoachApp: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        menu.items.first?.title = cache.statusLine

        // Repopulate saved workflows each open — recordings made or deleted
        // since the last open should just be there, no restart.
        guard let sub = teachSubmenu else { return }
        sub.items.removeAll { $0.representedObject is URL }
        let saved = lessonStore.list()
        guard !saved.isEmpty,
              let anchor = sub.items.firstIndex(where: { $0.isSeparatorItem }) else { return }
        for (offset, entry) in saved.enumerated() {
            let item = NSMenuItem(title: entry.title,
                                  action: #selector(startSavedLesson(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = entry.url
            sub.insertItem(item, at: anchor + offset)
        }
    }
}
