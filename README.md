# ScreenCoach

Press a hotkey, say or type the name of any control on your screen, and a cursor flies to it and
points. It solves the problem of telling somebody where a button is over the phone.

"It's in the top right." "I don't see it." "Under the three dots." "Which three dots?" That
conversation is the thing this replaces.

## What problem this solves

Helping someone through unfamiliar software remotely is mostly a coordinate problem. You know
exactly which control you mean and you have no way to point at it. Screen sharing helps and is
often unavailable, awkward, or overkill for one button. Written instructions go stale the moment
the app updates its layout. Screenshots with red circles have to be made by hand, one per step.

The natural instinct now is to hand the screen to a vision model and ask it where the button is.
That approach has a measurable ceiling. On ScreenSpot-Pro, the benchmark for dense professional
interfaces, the best open grounding models score in the high fifties to low sixties out of a
hundred. A coach that points at the wrong control four times in ten is worse than nothing,
because the person following it does not know which four.

**The bet here is the inversion: ground on the accessibility tree first, and use vision only when
the tree cannot answer.**

The accessibility tree is the structured description macOS already publishes for screen readers.
Every button, field and menu item, with its real screen rectangle, its role, and usually a label.
It is not inference. When the element is in the tree, its position is exact and it is available in
under a millisecond. Vision is the fallback for the cases the tree genuinely does not cover:
canvases, custom-drawn controls, and apps that vend nothing useful.

That ordering is the whole project, and everything below is what it cost to make it true.

## How it works

```
                      speculative, before you press anything
                 ┌──────────────────────────────────────────┐
                 │  AXCache: extract on focus change,       │
                 │  refresh on AXObserver events,           │
                 │  heartbeat to keep the tree warm         │
                 └────────────────────┬─────────────────────┘
                                      │  warm tree, already in hand
Option Space  ->  CommandBar  ->  AXResolver  ->  score >= 0.62 ?
"the Today button"  live shortlist    lexical rank        │
                    per keystroke                    yes  │  no
                                                          │   │
                                          point immediately   │
                                                              v
                                          AXResolver.cropHint: the tree aims
                                          a crop even though it could not answer
                                                              │
                                                              v
                                          Holo1.5 sidecar, started lazily
                                          on the first miss, never before
                                                              │
                                                              v
                                                Fusion: AX + vision -> one
                                                decision, plus a confidence
                                                the overlay actually renders
```

**The work happens before the hotkey.**
[`AXCache.swift`](Sources/ScreenCoachKit/AXCache.swift) extracts the frontmost app's tree when
focus changes, refreshes it when an `AXObserver` says something moved, and runs a low-rate
heartbeat to keep it warm. By the time you press Option Space the answer is already in memory.
This is not an optimization that was added later. It is load bearing, and the measurement that
made it load bearing is in Results below.

**The resolver is lexical, not learned.**
[`AXResolver.swift`](Sources/ScreenCoachCore/AXResolver.swift) scores your query against the
labels in the tree. It is cheap enough that the command bar re-ranks on **every keystroke** and
shows you a live shortlist of the top three candidates with their scores. A 0.067 millisecond scan
can afford to run while you type.

**Vision is never loaded on a confident hit.** If the top score clears 0.62 the coach points
straight away and the model is never started. The reasoning in the source is blunt: the vision
model costs roughly 1.7 milliseconds per image token, so checking a confident answer would trade
about two seconds for a second opinion that is right 58 percent of the time.

**When vision does run, the tree still helps.** Even when the resolver cannot name the element, it
usually knows roughly where that kind of thing lives, so `cropHint` aims a crop. Fewer pixels means
fewer image tokens means less latency, and image tokens are what this model's latency is made of.

**Fusion is the part that is actually novel.**
[`Fusion.swift`](Sources/ScreenCoachCore/Fusion.swift) has to combine two very different things.
An accessibility candidate has exact bounds, a score and semantics. A vision candidate has a point,
no bounds, no semantics, and usually no confidence at all, because the model emits a click without
a probability. The rule it settles on: **agreement between two independent methods is the only
thing that earns a confident point.** Everything else is rendered as a question, and
[`Overlay.swift`](Sources/ScreenCoachKit/Overlay.swift) draws it differently, a solid ring for an
exact tree answer and a dashed one for uncertainty, with a question mark on the caption.

**The pointer travels.** The overlay draws a bezier arc rather than teleporting a dot, because a
dot that appears somewhere has to be found before it can be followed.

## Results

Every number here names the file it came from, because two of them are easy to misread and one of
them is not a measurement at all.

| Result | Value | Where it comes from |
| --- | --- | --- |
| Resolver latency | **0.067 ms p50, 0.081 ms p90** | `bench-data/axplan-chrome.json`, same run as the accuracy below |
| Resolver accuracy | **12 of 12 on a Google Chrome window** | Same file, `ax_hit_rate: 1` over 12 plans |
| Unit tests | **96 passing, 0 failures** | `swift test`, run 2026-08-27 |
| Source size | 8,381 lines across 34 Swift files | Sources 7,261, Tests 1,075, Package.swift 45 |

**On the source size:** the figure only clears 8,300 if you count the tests. The application and
library code alone is 7,261 lines. Both numbers are in the table for that reason.

### The 12 of 12 is one Chrome window, and that matters

All twelve targets are in a single Google Chrome window, and **seven of the twelve are buttons on
the bookmarks bar**, which is to say seven instances of the same kind of control.

[`PHASE-0-FINDINGS.md`](PHASE-0-FINDINGS.md) says so itself, and the comparison it draws is the
important one: Chrome's toolbar is "a far easier target than Logic's dense professional UI," and
the full-frame vision baseline scores **83 percent on Chrome against 40 percent on Logic Pro**.
The accessibility tree is more robust than vision across that gap, but nobody should read
12 of 12 on a browser toolbar as a general result. The honest phrasing is the one in the table:
twelve of twelve on a Chrome window.

### The 0.07 ms in `live-eval.json` is not a measurement

This trap is documented here because the file will otherwise mislead a reader.

`bench-data/live-eval.json` reports `p50_ms: 0.07` for both the `ax_only` and `hybrid` conditions.
That number was **not timed**. [`Tools/live_eval.py`](Tools/live_eval.py) writes `"ms": 0.07` as a
literal at lines 128 and 147, re-reading precomputed hit and score fields from the plan file rather
than running the resolver. Every `ax_only` row reads 0.07 because it was stamped in.

**The real measurement is `bench-data/axplan-chrome.json`**, produced by the Swift benchmark
(`screencoach-bench axplan`), which records `resolve_p50_ms: 0.067166` and
`resolve_p90_ms: 0.080708` from the same run that produced the 12 of 12. Cite that file. What
remains genuinely unmeasured is the hybrid's **end to end** latency: it was composed from a
constant plus separately measured vision timings, never run and timed once as a whole.

### Aimed crops: two runs that disagree

An earlier version of this README claimed that letting the tree aim the vision crop matched
full-frame accuracy at three times the speed. That is true of the first run and **contradicted by
the second**, so both are here.

| Run | Condition | Accuracy | p50 | Speedup |
| --- | --- | ---: | ---: | ---: |
| `holo-axcrop.json` (Aug 21, 07:06) | full frame | 10 of 12 | 7,005 ms | |
| | AX-aimed crop | 10 of 12 | 2,359 ms | **2.97x, accuracy matched** |
| `live-eval.json` (Aug 21, 11:54) | full frame | **11 of 12** (91.7%) | 7,317 ms | |
| | AX-aimed crop | 10 of 12 (83.3%) | 1,204 ms | **6.1x, one target lost** |

The later run is faster and **less accurate**: the full frame beats the crop by one query out of
twelve. With n = 12 a single query is worth 8.3 percentage points, so this is not a large
difference, but it is the wrong direction to claim the crop is free. The defensible statement is
that aimed cropping buys a three to six times speedup at an accuracy cost somewhere between zero
and one target in twelve, on this one Chrome window.

## Measurement-driven architecture

This is the part of the project I would most want read. Four findings from
[`PHASE-0-FINDINGS.md`](PHASE-0-FINDINGS.md) each changed the design rather than confirming it.

### Finding 1: reading a cold accessibility tree is 6 to 10 times slower than a warm one

| App | Cold, first touch | Warm p50 | Ratio |
| --- | ---: | ---: | ---: |
| Logic Pro | 220 ms | 21 ms | 10.4x |
| Calendar | 193 ms | 18.5 ms | 10.4x |
| Messages | 170 ms | 27.5 ms | 6.2x |
| Google Chrome | 45 ms | 5.7 ms | 8.0x |

The first walk of an app's tree makes that app build and vend it. Every walk afterwards rides a
warm path. Finder's 37x is excluded from the headline because its tree is five nodes, which makes
the ratio arithmetic rather than informative.

**And warmth decays within ten seconds.** Left idle, Logic Pro drifts 21 to 47 to 50 to 64 ms, and
Calendar goes from 18.5 ms back to 120 ms, which is fully cold again.

The coach's exact situation is "the user just switched apps and pressed the hotkey," which is the
cold path. Extracting on the hotkey would cost 45 to 220 ms and blow the budget. This is why
[`AXCache.swift`](Sources/ScreenCoachKit/AXCache.swift) exists, why it is driven by an
`AXObserver`, and why it needs a heartbeat rather than only invalidating on change. The finding
promoted speculative extraction from an optimization to a requirement.

### Finding 2: batching attribute reads is a free 3.12x

Reading eleven attributes per node as eleven separate `AXUIElementCopyAttributeValue` calls, versus
one `AXUIElementCopyMultipleAttributeValues`:

| Strategy | p50 | p90 |
| --- | ---: | ---: |
| One call per attribute | 2.54 ms | 3.08 ms |
| Batched | **0.81 ms** | 0.97 ms |

**This is per-node attribute reading, not end to end extraction.** Every accessibility read is a
synchronous round trip into another application's run loop, so what is being saved is round trips,
not CPU. Both paths are kept in the code as a selectable strategy so this stays a measurement
rather than a claim.

### Finding 4: the capture path matters more than the capture API

| Path | p50 | p90 |
| --- | ---: | ---: |
| Warm ScreenCaptureKit stream, plus `CGImage` | 6.2 ms | **7.9 ms** |
| `SCScreenshotManager` one shot | 34.4 ms | 35.9 ms |
| `screencapture(1)` command line tool | 193 ms | **204 ms** |

The raw warm-grab row in the source data reads 0.00 ms, because the newest complete frame is
already in hand and reading a pointer is not a capture. The findings document rejects that row as
the headline and marks the "plus CGImage" row as the real cost, which is the number quoted above.
Dropping the command line tool is worth about 185 milliseconds on its own.

A related trap in the same finding: ScreenCaptureKit does not deliver frames on a timer. On a
mostly static screen, 96 of 108 frames were idle and carried no pixels. A design that waits for the
*next* frame after the hotkey can block indefinitely on a still screen, which is exactly what a
user asking about a control is looking at. The correct design keeps the newest complete frame and
uses it immediately.

## The privacy gate

Excluded apps are **not read and not captured**, and the ordering of those two words is the whole
point.

The exclusion list originally gated the screenshot only. Testing it against Messages produced a
candidate list that included a real private conversation, with a contact's name and a fragment of
the message body, **with no frame ever captured**. The accessibility tree carries the content, not
merely the controls. That is Finding 16 in
[`PHASE-0-FINDINGS.md`](PHASE-0-FINDINGS.md), and it is a genuine discovery rather than a
hypothetical.

The fix has a property worth spelling out.
[`AXCache.swift`](Sources/ScreenCoachKit/AXCache.swift) checks the exclusion rules **before the
first accessibility call**, on the bundle identifier alone. Title-pattern rules need a window
title, and reading a title through the accessibility API would mean reading the app you are trying
not to read, so the title comes from `CGWindowList` instead. **Testing whether an app is excluded
therefore never requires touching it through the accessibility API.**

[`ExclusionStore.swift`](Sources/ScreenCoachKit/ExclusionStore.swift) keeps the list at
`~/.config/screencoach/exclusions.conf` as plain text, seeds it on first run so you can read what
is excluded rather than trust a claim, fails closed (an empty or unparseable file falls back to
defaults, never to "allow everything"), and hot reloads on save. It re-arms its file watch after a
delete or rename, because editors replace files rather than writing in place and the watch would
otherwise die after the first save.

The live configuration on this machine holds **26 bundle rules and 16 title patterns**. The title
patterns are generic keyword rules: `online banking`, `routing number`, `medical record`,
`seed phrase`, `2fa`, and similar.

The trade is real and it is the correct one: the coach cannot help you inside your password
manager.

Nothing is persisted by default. Frames are deleted as soon as the answer comes back. Speech
recognition runs on device and the app refuses rather than sending audio to a server.

## Why headless testing is possible here

`ScreenCoachCore` imports only Foundation, CoreGraphics and Darwin. **No AppKit, no
ApplicationServices, no ScreenCaptureKit.** That is enforced by what the module is allowed to
contain rather than by convention, and it is why 96 tests run in nine milliseconds with no
permissions, no windows and no hardware.

The parts most likely to be silently wrong live there deliberately: the multi-display coordinate
conversion, the latency budget arithmetic, the resolver's scoring, and the fusion rules.

| Test file | Count | What it covers |
| --- | ---: | --- |
| `FusionTests` | 24 | Combining tree and vision candidates, and the confidence rules |
| `LessonTests` | 17 | Steps, completion conditions, tree-diff detection |
| `WorkflowInferenceTests` | 16 | Click hit-testing and turning clicks into semantic steps |
| `LatencyTests` | 15 | Stage timing, percentiles, the budget as code |
| `AXResolverTests` | 13 | Query to element ranking, and crop aiming on a miss |
| `DisplaySpaceTests` | 11 | The multi-display coordinate trap, at the type level |

The system-facing half (`ScreenCoachKit`) and the app itself have no unit tests. That is the real
coverage gap.

## Running it

Requires macOS 14 or newer on Apple silicon and the Swift toolchain from Xcode. No third party
Swift dependencies.

```bash
swift build -c release
swift test                                  # 96 tests, headless, no permissions needed
./.build/release/screencoach-bench doctor    # environment and permission preflight
```

`doctor` exits 0 and prints four sections: environment, permissions (Accessibility and Screen
Recording, granted or denied), display layout, and the frontmost app. Run it first, because
everything except `swift test` needs Accessibility.

Build and launch the menu bar app:

```bash
bash Tools/make-app.sh && open build/ScreenCoach.app
```

It has no Dock icon. Press Option Space, type the name of a control in the app behind it, and the
pointer arcs to it.

Reproduce the measurements:

```bash
./.build/release/screencoach-bench coldwarm --app "Logic Pro" --deadline 2000   # Finding 1
./.build/release/screencoach-bench ax                                          # Finding 2
./.build/release/screencoach-bench capture --scope window                       # Finding 4
./.build/release/screencoach-bench axplan                                       # the 0.067 ms number
./.build/release/screencoach-bench budget                                       # exits non-zero on violation
```

Test the whole turn without a human:

```bash
./.build/release/ScreenCoachApp --selftest "the close button" --app "Google Chrome"
```

**The vision fallback needs a model that is not in this repository.** A Holo1.5 checkpoint is
expected at `~/models/holo1.5-7b-4bit`, about 5.6 GB resident, plus Python with MLX and PIL. The
accessibility path works without any of that, which is most of the point, but a fresh clone cannot
run the vision half.

## Project layout

```
Sources/
├── ScreenCoachCore/        Pure. Foundation, CoreGraphics and Darwin only
│   ├── AXResolver.swift        Query to element ranking, and crop aiming on a miss
│   ├── Fusion.swift            Tree plus vision to one decision, with honest confidence
│   ├── DisplaySpace.swift      The multi-display coordinate trap, at the type level
│   ├── AXNode.swift            Element model and semantic label fusion
│   ├── ExclusionList.swift     What the coach is never allowed to look at
│   ├── Lesson.swift            Steps, completion conditions, tree-diff detection
│   ├── WorkflowInference.swift Clicks to semantic steps
│   ├── LatencyBudget.swift     The budget as code, checkable automatically
│   ├── LatencyTrace.swift      Stage timing, p50, p90, p99
│   └── Mono.swift              One monotonic clock for every stage
├── ScreenCoachKit/        System facing
│   ├── AXCache.swift           Speculative extraction, AXObserver, heartbeat, privacy gate
│   ├── AXTree.swift            Tree extraction, batched attribute reads, limits
│   ├── ExclusionStore.swift    The hot-reloading privacy list
│   ├── WarmCapture.swift       Warm ScreenCaptureKit stream and one-shot paths
│   ├── ScreenGrab.swift        Display capture with origin, scale and index
│   ├── GroundingService.swift  The vision sidecar, started lazily on the first miss
│   ├── Overlay.swift           All-Spaces click-through panel, bezier-arc pointer
│   ├── HotKeyTap.swift         Listen-only event tap on its own thread
│   ├── Voice.swift             On-device push-to-talk speech, and speech out
│   ├── LessonRunner.swift      Multi-step teaching with evidence-driven advance
│   └── WorkflowRecorder.swift  "Watch me": clicks to steps to JSON on disk
├── ScreenCoachApp/        Menu bar app, hotkey, command bar, the resolve and point turn
└── ScreenCoachBench/      screencoach-bench, 14 subcommands, every number in the findings

Tests/ScreenCoachCoreTests/  96 tests, headless
Tools/                       The Python vision harnesses and the app packaging script
bench-data/                  Committed benchmark output, the source of every figure above
PHASE-0-FINDINGS.md          The engineering log, 23 findings across phases 0 to 4
```

## Status

**Working:** accessibility-first grounding, the warm cache, the overlay and pointer, on-device
push-to-talk voice, the privacy gate, the vision fallback with aimed crops, fusion with rendered
confidence, and multi-step lessons. The app builds, launches and points.

Shipping state: `build/ScreenCoach.app`, thin arm64, bundle `com.funproject.screencoach`, version
0.1.0, a menu bar only app (`LSUIElement`), signed with an Apple Development certificate.

**Not done, stated plainly:**

- **This project is not in version control.** There is no git repository, no history and no
  backup. 8,381 lines of Swift, a 1,066 line engineering log and every benchmark artifact exist
  on exactly one machine. This is the first thing to fix.
- **There is no CI**, so the latency budget gate is CI-ready rather than gating anything.
  `screencoach-bench budget` exits non-zero correctly, and nothing runs it automatically.
- **Idle CPU and memory are unmeasured.** The harness exists at
  [`App.swift`](Sources/ScreenCoachApp/App.swift) (`--idlebench`, `getrusage` for CPU over a
  settled idle window, `task_info` for resident memory) and it prints to standard output, but **no
  result was ever committed**, so there is no idle CPU or memory figure in this README. The
  comparison worth making is with the sibling WindowPet project, which publishes a generated
  `ENERGY.md` with per-phase budgets. This project has the harness and not the number, and the
  findings document's own principle applies: an unmeasured stage is not a met budget.
- **The packaged app cannot run the vision path.** `Contents/Resources/` is empty and
  `Tools/make-app.sh` never copies `Tools/`, so the bundled app only finds the Python sidecar when
  it happens to be running beside its own source tree.
- **Not notarized**, and the build has no hardened runtime, because the signing script fell back
  from Developer ID to an Apple Development identity. Gatekeeper will reject it on another Mac.
- **`ScreenCoachKit` and the app have no unit tests.** All 96 are against the pure core.
- **Every headline accuracy figure comes from one Chrome window with twelve targets.** A second
  app, ideally a dense one, is the highest-value next measurement.
- **No screenshot or demo clip exists.** For a project whose entire output is a cursor arcing to a
  control, that is the most valuable missing asset.

---

Jalen Edusei, [jalenedusei.com](https://www.jalenedusei.com),
[github.com/jke48222](https://github.com/jke48222)
