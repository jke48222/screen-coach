# Phase 0 — Measure the budget

Machine: **Apple M5 Pro, 24 GB unified, macOS 27.0 (26A5378j)**, single
1512×982 @2x display. Swift 6.3.3, MLX 0.32.1.

Everything below is measured on this machine with
`Sources/ScreenCoachBench`. Percentiles are nearest-rank over the stated trial
count, so every figure is a number some trial actually produced.

---

## The headline

| | budget | measured | verdict |
|---|---|---|---|
| **(a) hotkey → frame in hand** | 50 ms | **7.9 ms** p90 (warm stream) | PASS, 6× under |
| **(b) AX tree extraction** | 80 ms | **21 ms** p50 / 22 ms p90 warm (Logic Pro, 352 nodes) | PASS |
| **(c) Holo1.5-7B, one grounding call** | 400–900 ms | **1657 ms** best usable (crop3, 4-bit) | **FAIL, ~2× over** |

Capture and accessibility come in far under budget. Vision does not, and no
amount of quantisation fixes it — the cost is the image, not the weights.

The practical effect is that **Phase 0 strengthens the core thesis rather than
weakening it.** The vision fallback is expensive *and* mediocre (50% at best on
this window), so the value of resolving a query on the accessibility tree —
21 ms and exact — is far higher than the brief assumed. AX-first was the plan;
it is now the plan by a factor of 80× in latency.

---

## Finding 1 — Cold AX extraction blows the budget; warm does not. 6–10×.

This is the most consequential number in Phase 0, and it is not in the brief's
estimate range at all.

| app | cold (first touch) | warm p50 | ratio | nodes | labelled | actionable |
|---|---|---|---|---|---|---|
| Logic Pro | 220 ms | 21 ms | **10.4×** | 352 | 79% | 172 |
| Calendar | 193 ms | 18.5 ms | **10.4×** | 94 | 88% | 37 |
| Messages | 170 ms | 27.5 ms | **6.2×** | 95 | 84% | 39 |
| Google Chrome | 45 ms | 5.7 ms | **8.0×** | 73 | 63% | 40 |
| Finder | 37 ms | 1.0 ms | 37× | 5 | 100% | 3 |

The first walk of an app's tree makes the *target* app build and vend its
accessibility tree. Every walk after that rides a warm path.

**Why it reorders the design:** the coach's exact situation is "user just
switched to an app and pressed the hotkey". That is the cold path. A naive
implementation extracts on hotkey and pays 45–220 ms — over budget, and on
Logic Pro nearly 3× over.

The brief already called for speculative extraction on focus change. Phase 0
upgrades that from an optimisation to a **requirement**.

**And warmth decays.** Left idle, trees drift back toward cold:

| idle | Logic Pro | Calendar |
|---|---|---|
| 0 s | 21 ms | 18.5 ms |
| 1 s | 47 ms | — |
| 5 s | 50 ms | — |
| 10 s | 64 ms | 120 ms (fully cold again) |

So focus-change extraction alone is not enough. The AXObserver-driven cache
needs a low-rate heartbeat to hold the tree warm, not just invalidation on
change.

## Finding 2 — Batching attribute reads is a free 3×.

Reading eleven attributes per node with eleven `AXUIElementCopyAttributeValue`
calls versus one `AXUIElementCopyMultipleAttributeValues`:

| strategy | p50 | p90 |
|---|---|---|
| per-attribute | 2.54 ms | 3.08 ms |
| batched | 0.81 ms | 0.97 ms |
| | **3.12×** | |

Every AX read is a synchronous round trip into another app's run loop, so the
win is round trips, not CPU. `AXExtractor.Strategy` keeps both paths so this
stays a measurement rather than a claim.

Pass `options: 0` (not `.stopOnError`) to the multi-value call: failed
attributes come back as in-band error placeholders instead of aborting the
read, so one missing attribute cannot cost the whole node.

## Finding 3 — Some apps are AX-hostile, and the guard rails are what save the budget.

| app | cold | warm | nodes | labelled |
|---|---|---|---|---|
| Contacts | 2009 ms | 2003 ms | 955 (capped) | **2%** |
| Gemini | 24 ms | 0.5 ms | 1 | 0% |
| Splice | 32 ms | 1.5 ms | 12 | 17% |
| Claude | 18 ms | 0.7 ms | 9 | 22% |

Contacts is the pathological case: it hits a 2-second deadline **both cold and
warm**, and after 955 nodes only 2% carry any label. Expensive *and* useless.

This validates the three independent bounds in `AXExtractor.Limits` (node cap,
depth cap, wall-clock deadline) — without the deadline, Contacts alone would
blow the end-to-end budget by 2×.

It also suggests a cheap policy Phase 1 should adopt: **bail out early**. If
the labelled fraction is still near zero after the first few hundred nodes,
abandon the AX path immediately and go to vision rather than spending the full
deadline proving the tree is useless.

The low-label apps (Gemini, Splice, Claude — all Electron or canvas) are
precisely the population the vision fallback exists for. `labelledFraction` is
the routing signal, and it is cheap to compute.

## Finding 4 — The capture path matters more than the capture API.

| path | p50 | p90 | notes |
|---|---|---|---|
| warm `SCStream` grab | **0.00 ms** | 0.00 ms | newest complete frame already in hand |
| warm grab + `CGImage` | **6.2 ms** | 7.9 ms | this is the real (a) |
| `SCScreenshotManager` | 34.4 ms | 35.9 ms | one-shot, no stream to keep alive |
| `screencapture(1)` | 193 ms | 204 ms | what WindowPet shipped |
| `SCStream` cold start | 52 ms | 88 ms | window scope; display scope p90 396 ms |

Three things worth keeping:

**The warm stream wins by 4×, but the one-shot also fits the budget.**
`SCScreenshotManager` at 34 ms is inside the 50 ms allowance with no stream
lifecycle, no permission-holding background capture, and no staleness. That is
a real simplicity-vs-latency choice rather than a foregone conclusion, and it
is a good fallback when a warm stream cannot be held.

**The session-setup tax is real but smaller than briefed.** 52 ms p50 window
scope, not 300–800 ms — though display-scope p90 hit 396 ms, so the tail is
there.

**Dropping `screencapture(1)` is worth 185 ms on its own.** WindowPet's
approach spawns a process and round-trips a PNG through disk.

### ScreenCaptureKit does not deliver frames on a timer

Display-scope capture of a mostly static screen: **108 complete frames, 96
idle**. An idle frame carries no pixels. A design that waits for the *next*
frame after the hotkey can therefore block indefinitely on a still screen —
which is exactly what a user asking about a UI is looking at.

The correct design keeps the newest `.complete` frame and uses it immediately.
Frame age tracks stillness: **12 ms** p50 on an animating window versus
**291 ms** p50 on a static display.

## Finding 5 — The two capture APIs do not agree on framing. (New trap.)

Given the *same* `SCContentFilter`, `SCStream` and `SCScreenshotManager` place
window content differently inside the output buffer — different origin **and**
different scale. Measured on an idle Logic Pro window: ~32% of pixels differ
raw; correcting for translation only brings it to ~20%, because a shift cannot
fix a scale mismatch.

Both images were 3024×1898 and visibly identical in content — the difference
is entirely framing.

**Consequence:** pixel coordinates are not interchangeable between capture
paths. Whatever image the vision fallback is handed, its coordinate mapping
must come from that image's own geometry (`SCStreamFrameInfo.contentRect` for
a stream frame), never from window bounds assumed to start at image (0,0).

This is the within-window sibling of the multi-display trap the brief warns
about, and it is not documented anywhere I could find.

## Finding 6 — (c) Holo1.5's latency is image tokens, not model weights.

First run, the BF16 weights straight from `mlx-community/holo1.5-7b-mlx`:

| | BF16 (16.6 GB) | 4-bit (5.3 GB) |
|---|---|---|
| load | 6.6 s | 0.5 s |
| weights resident | 16.59 GB | 5.64 GB |
| peak memory | 17.98 GB | 7.13 GB |
| TTFT p50 | 7132 ms | 6017 ms |
| accuracy | 5/10 | 4/10 |

Quantising to 5.44 bits/weight cut the model to a third of its size and bought
**15% of latency**. That rules the weights out.

The real term is the vision encoder. A 2322×1900 window is 3.65 MP, which
Qwen2.5-VL turns into ~4,650 image tokens before a single output token exists.
And the relationship is strikingly linear:

| condition | MP | ~image tokens | TTFT p50 | ms/token | accuracy |
|---|---|---|---|---|---|
| display (whole screen) | 3.67 | 4675 | 6508 ms | 1.39 | 40% |
| window | 3.65 | 4650 | 7310 ms | 1.57 | 40% |
| crop2, native res | 1.71 | 2184 | 3512 ms | 1.61 | 40% |
| window @1.0 MP | 0.98 | 1248 | 2146 ms | 1.72 | 40% |
| **crop3, native res** | **0.77** | **980** | **1657 ms** | **1.69** | **50%** |
| window @0.5 MP | 0.47 | 594 | 1032 ms | 1.74 | **10%** |
| crop4, native res | 0.43 | 546 | 1131 ms | 2.07 | 30% |

**TTFT ≈ 1.7 ms × image tokens** on this machine. That is a usable planning
formula: to hit a 900 ms grounding budget you get ~530 image tokens, or about
0.42 MP.

## Finding 7 — Cropping beats downscaling, and the brief was right about why.

At the *same* token budget, the two ways of spending fewer pixels are not
equivalent:

| ~tokens | by cropping | by downscaling |
|---|---|---|
| ~550–600 | **30%** (crop4) | **10%** (window @0.5 MP) |
| ~980–1250 | **50%** (crop3) | 40% (window @1.0 MP) |

Cropping at native resolution is 3× more accurate than downscaling to the same
cost. The reason is visible in the per-target data: downscaling does not make
the model lost, it makes it *imprecise*. At 0.5 MP the predictions cluster
51–134 px from target centre — approximately right, never exactly right, on
9 of 10 targets.

That is precisely the failure mode the brief describes for pure-vision
grounding: confidently wrong by a small margin. It is worse than being lost,
because a near-miss still looks like an answer.

Cropping fixes the genuinely hard targets rather than nudging the easy ones —
Editors 348 px → hit, Metronome 1099 px → 232 px, Browsers 2086 px → 767 px.

**crop3 is the best condition measured, and it beats the full window on both
axes**: 50% vs 40% accuracy at 4.4× the speed. Feeding the model more image
than it needs makes it both slower and worse.

## Finding 8 — The vision budget as briefed is not reachable with this model.

Best usable configuration is crop3 at **1657 ms** against a 400–900 ms
allowance — roughly 2× over — and it caps at 50% accuracy on this window. The
end-to-end vision-fallback path would land near 2.0–2.4 s against the 1.4–2.0 s
target.

Three ways forward; this is a decision, not something Phase 0 should settle
unilaterally, and Holo1.5-7B is a locked choice:

1. **Accept it.** It is the fallback. If AX resolves the large majority of
   queries at 21 ms, a rare 2 s answer is a reasonable price, and the brief's
   own "1.4–2.0 s acceptable" band is nearly met.
2. **Measure Holo1.5-3B.** 51.49 on ScreenSpot-Pro versus 57.94, and it should
   roughly halve TTFT. The accuracy gap may be smaller in practice than the
   benchmark spread suggests, given the 7B only manages 50% here.
3. **Crop harder, using AX to aim.** Even on an AX *miss*, the tree usually
   still gives panel-level structure. Using it to pick a tight region rather
   than a fixed grid cell would push well under 980 tokens with the accuracy
   benefit of native resolution.

Option 3 is the one that fits the architecture best — it makes the two
grounding paths cooperate instead of being alternatives — and it costs nothing
to try in Phase 2.

---

## Verified: the coordinate math

`DisplaySpace` carries an explicit screen index on every point and rect, and
26 headless unit tests cover the CG↔AppKit flip, negative-coordinate secondary
displays, straddling windows, and mixed scale factors.

Verified against reality, not just tests: AX bounds for Logic Pro's transport
controls, drawn back onto both the window-scoped and the full-display capture.

Every box lands exactly on its control in both coordinate frames.

One incidental discovery from that check: **AX bounds are correct for occluded
elements**. Logic's metronome button had exact bounds while sitting behind
another window. A vision grounder cannot see an occluded element at all; the
AX tree still knows where it is. That is another point for AX-first — and a
caveat, since the coach should not point confidently at something the user
cannot currently see.

---

## Permissions

Accessibility and Screen Recording are both required, and a bare binary
inherits its parent process's grants — convenient for benchmarking, not a
shipping story.

Two carried-over lessons from WindowPet that apply directly:

- Sign with a **stable identity** (an Apple Development cert is enough) or TCC
  resets grants on every rebuild.
- A bare executable has no window-server connection. Window-scoped
  ScreenCaptureKit queries trip `CGS_REQUIRE_INIT` and abort the process until
  something touches `NSApplication.shared` on the main thread. Display-scoped
  capture works without it, which makes this look like a scope bug rather than
  an initialisation one.

Still to do, and worth starting early because it is slow and may be refused:
apply for `com.apple.developer.persistent-content-capture`.

---

# Phase 0b — Option 3: using AX to aim the vision crop

Finding 8 offered three ways to close the vision-latency gap. This is the
third, built and measured: **let the accessibility tree say where to look,
even when it cannot say what to click.**

Measured on a Chrome window (107 nodes after deduplication, 36 labelled
actionable targets), captured with its AX tree as ground truth in display
pixels. Note these accuracy figures are **not comparable to the Logic Pro
numbers above** — Chrome's toolbar is a far easier target than Logic's dense
professional UI, and the full-frame baseline scores 83% here versus 40% there.
The comparison that matters is between conditions on the *same* window.

## Finding 9 — The AX resolver answers everything, in 0.067 ms.

This is the number the whole architecture rests on and nothing in Phase 0
measured it.

| | |
|---|---|
| exact hits | **12/12 (100%)**, and 12/12 in top-3 |
| resolve cost | **0.067 ms** p50, 0.081 ms p90 |
| budget | 20 ms — **300× under** |

The scorer is lexical, not embedding-based: token coverage over role, title,
description, help and identifier, with role agreement and a size penalty. UI
labels are short and literal, and the words a person says are usually the words
in `AXTitle`, so overlap is a strong signal. At 0.067 ms there is no latency
argument for adding a 600M-parameter embedding model to the hot path — but
`axplan` exists to re-check that if lexical matching plateaus on harder apps.

**On this window the vision fallback is never invoked at all.** That is the
thesis working: 0.067 ms and exact, versus 2359 ms and 83%.

Four scoring rules earned their place by failing first:

- **Size penalty must be multiplicative.** An `AXWindow` whose title matches
  the document name scored a perfect 1.0 and cleared the hit threshold even
  after a flat −0.35. Nothing textual should be able to promote a
  window-sized element into a confident answer.
- **Role disagreement must be multiplicative too.** A static text reading
  "Play" beat the actual Play button on text alone; a flat −0.06 was far too
  weak to separate a control from a label describing it.
- **Containers are exempt from role penalties.** A group is never the answer
  but is a legitimate crop target.
- **A hint that contradicts the requested role is discarded, not trusted.**
  See below.

## Finding 10 — Aimed cropping matches full-frame accuracy at 3× the speed.

| condition | accuracy | TTFT p50 | image tokens | deployable? |
|---|---|---|---|---|
| full frame | 83.3% | 7005 ms | 4675 | yes |
| blind 3×3 grid cell | **100%** | 2016 ms | 1305 | **no** |
| **AX-aimed crop** | 83.3% | **2359 ms** | **1080** | **yes** |

The blind grid looks best and is not a real option: it picks the cell
containing the target, which means the harness had to already know where the
target was — the exact thing grounding exists to determine. It is an upper
bound on what perfect aiming would buy, not a competitor.

Between the two deployable conditions, **AX aiming gives identical accuracy
for a third of the latency and a quarter of the tokens.** That is Option 3
working, and it comes from the tree alone: every crop was computed with the
target element and its whole subtree ablated, so the resolver never saw the
thing it was aiming at.

Both remaining failures are understood:

- *the Jalen button* — no usable hint, so the crop fell back to the whole
  frame and reproduced the full-frame miss exactly. Graceful degradation:
  the aimed path is never worse than the unaimed one.
- *the YouTube button in the Bookmarks* — the page has **two** bookmarks named
  YouTube. Aiming improved the error from 1727 px to 997 px and the crop did
  contain the target, but no crop can resolve which identical twin was meant.
  This is the case for the confidence rendering the brief calls for: a dashed
  uncertain ring, not a confident point.

## Finding 11 — Errors here are asymmetric, so untrusted hints must be discarded.

Cropping too wide costs tokens, about 1.7 ms each. Cropping tight in the
**wrong** place puts the target outside the image, and no model quality
recovers from being shown the wrong region.

So the resolver refuses to aim on a hint that names the right words but the
wrong kind of thing — a status label reading "Play" when the query wanted a
Play button returns the whole window rather than a confident tight crop. Three
further rules fell out of measured failures:

- **Union every competitive candidate**, not just the best. Ambiguous labels
  otherwise aim at the wrong instance.
- **Union every matching region too**, not the smallest. Picking the smallest
  chose a tiny group labelled "YouTube" over the Bookmarks bar and kept the
  crop on the wrong side of the window.
- **Qualify regions on raw word overlap, not the ranking score.** Field
  weights exist to rank *answers*; Chrome names its Bookmarks bar through
  `AXDescription`, weighted 0.85, so the correct region scored 0.489 against a
  0.5 bar and was skipped. Whether a region shares the query's words does not
  depend on which attribute the app stored its name in.

## Finding 12 — Accessibility trees contain large numbers of duplicates.

Chrome returns **159 nodes for 61 distinct elements** — 62% duplicates, with
one anonymous group appearing twelve times, because the tree is a graph
reachable by several paths and a plain BFS walks each path.

Deduplication is now on by default, and it must key on **labelled nodes only**.
The tempting rule — same role, same bounds, same label — is false for
unlabelled containers: Chrome stacks a dozen anonymous groups at identical
bounds whose *children differ*, and treating those as duplicates collapsed the
tree from 159 nodes to 10 and threw away most of the browser. A label is what
makes identity assertable.

## Finding 13 — Two more app-geometry traps.

Both cost real debugging time and both will recur.

**An AX window element does not necessarily contain its own children.**
Chrome's `kAXFocusedWindowAttribute` returns bounds covering only the web
content; its toolbar and tab strip are descendants at *negative* offsets above
it. Anchoring ground truth to the AX window silently pushed every browser
control out of frame and produced a snapshot with zero usable targets.

**One app window can span several `SCWindow`s.** Chrome's browser window is
three: 1512×827 for the page plus 1512×174 and 1512×81 strips for the tabs and
toolbar, with a single AX tree spanning all of them. Clamping crops to the
largest frame intersected them down to nothing.

The fix for both is the same and is now what the code does: derive the
reference extent from the **union of the AX node bounds**. It needs no window
frame, and it is the only definition that survived every app tested.

The ground-truth frame is likewise now the **display** capture, not the window
capture — AX already reports CG coordinates anchored at the primary display's
top-left, so that mapping is one subtraction and one scale with nothing to get
wrong. Verified pixel-exact on both Logic Pro and Chrome.

---

## What Phase 0 changes about the plan

1. **Speculative AX extraction on focus change is mandatory, plus a
   heartbeat.** Cold is 6–10× warm and decays within 10 s. This moves from
   "optimisation" to "load-bearing".
2. **Route on `labelledFraction`, and bail out early.** It is cheap, it
   predicts groundability, and it stops apps like Contacts (955 nodes, 2%
   labelled, 2 s) from spending the whole budget proving AX is useless.
3. **Use AX to aim the crop, not just to answer.** Finding 7 says native-res
   cropping is worth 3× the accuracy of downscaling at equal cost, and the AX
   tree is the cheapest source of "roughly where to look" even when it cannot
   name the exact element.
4. **Never mix coordinate frames between capture paths.** Finding 5.
5. **Budget the vision path at ~2.4 s, not ~900 ms.** Option 3 (Finding 10)
   brings it from 7.0 s to 2.4 s at no accuracy cost, but it does not reach
   the briefed 400–900 ms. Options 1 and 2 in Finding 8 remain open on top of
   it — measuring Holo1.5-3B is the obvious next lever.
6. **Deduplicate labelled nodes during extraction** (Finding 12) and derive the
   reference extent from the union of AX node bounds, never a window frame
   (Finding 13).
7. **Render uncertainty rather than guessing.** Finding 10's remaining failure
   is two identically-named bookmarks — exactly the case the brief's dashed
   uncertain ring exists for.

## Reproducing

```bash
swift test && swift build -c release
```

```bash
./.build/release/screencoach-bench all --deadline 2000
```

```bash
python3 Tools/holo_sweep.py --data bench-data/logic-pro.json --targets 10
```

```bash
./.build/release/screencoach-bench axplan --data bench-data/google-chrome.json --targets 12
```

```bash
cd Tools && python3 holo_axcrop.py --data ../bench-data/google-chrome.json --plan ../bench-data/axplan-chrome.json
```

Not yet run — needs a human at the keyboard, since it times real key presses
from the hardware event timestamp:

```bash
./.build/release/screencoach-bench hotkey --trials 10
```

Raw results are in `bench-data/`: `holo-7b-bf16.json`, `holo-7b-4bit.json`,
`holo-sweep.json`, plus the Logic Pro capture and its AX ground truth.

---

# Phase 1 — It points, correctly

Built: `ScreenCoachApp` — a menu-bar-only accessory app. Hotkey (⌥Space), type a
target in plain language, and a cursor flies along a bezier arc to the exact
control. **No voice, no vision model, no cloud, no network at all.**

Verified end to end with `--selftest`, which prints every coordinate the
pointer will use rather than taking a screenshot — this app exists to look at
whatever the user has open, so verifying it should not mean capturing their
screen.

```
App        Calendar — 94 nodes, 83 labelled, 37 actionable
Cache      serve p50 0.359 ms, p90 0.396 ms (6 warm / 0 cold)
Resolve    0.510 ms for "the Today button"
  1. 1.17  button · Today · today-button  cg=(1144,308 68×27) screen 0
Convert    cg(1144,308) → appkit(1144,647)  [primary height 982]
           → panel-local(1144,647) on screen 0 ✓ inside screen
Confidence exact — solid ring
```

`982 − 308 − 27 = 647` — the flip is right, and the self-test prints it rather
than trusting it, because this is the conversion that puts the pointer on the
wrong monitor when it is wrong.

## The measured turn

| stage | budget | measured |
|---|---|---|
| tree read (warm cache) | 80 ms | **0.34–0.36 ms** p50 |
| resolve | 20 ms | **0.51–1.14 ms** |
| pointer start | 16 ms | next frame |

Two orders of magnitude under budget, because the cache did the expensive work
before the hotkey was pressed. That is Finding 1 paying off exactly as designed.

## Confidence is rendered, not hidden

The threshold produces a sensible gradient on real queries against Calendar:

| query | best match | score | rendering |
|---|---|---|---|
| "search" | `button · Search` | 0.90 | solid ring |
| "the add event control" | `button · Add Event` | 0.66 | solid ring |
| "the day view" | `radio button · Day` | 0.54 | **dashed ring** |
| "that thingy on the side" | — | — | **declines to point** |

"the day view" *is* the Day button, but the query said "view" and the role
disagrees, so the coach hedges instead of asserting. And a genuinely vague
query returns nothing rather than a guess. That is the behaviour the whole
project is arguing for: a teacher that admits doubt gets trusted, one that is
confidently wrong gets uninstalled.

## Finding 14 — Some apps stop vending an AX window when they lose focus.

Chrome, VS Code and Logic Pro all reported "no focused/main window over AX"
while inactive, having read fine moments earlier while frontmost — confirmed
identically from both the app and the bench, so it is the apps' behaviour, not
ours. Calendar, Messages, Finder and Terminal keep vending regardless.

This makes the speculative cache load-bearing for a second, independent
reason. It is not only that a cold walk costs 45–220 ms (Finding 1) — for some
apps, **the moment the coach could ask is the moment the answer disappears.**
Extracting on activation and holding it is the only design that works for them.

## Finding 15 — The coach must never resolve against itself.

`NSWorkspace.frontmostApplication` answers "who is in front *right now*", and
once this process has an `NSApplication` that is briefly us — at launch, and
whenever the command bar takes keyboard focus. Asking about ourselves returns
a process with no window, so the tree came back empty exactly when the user is
typing their question.

`AXCache` now remembers the last frontmost application that was not this
process. That is also the semantically correct answer: the query is about the
app the user was working in, not the input box they are typing into.

## Running it

```bash
bash Tools/make-app.sh && open build/ScreenCoach.app
```

Then ⌥Space. Grant Accessibility when asked — it is the entire product; without
it there is nothing to point at.

```bash
./build/ScreenCoach.app/Contents/MacOS/ScreenCoach --selftest "the Today button" --app Calendar
```

Sign with a **stable identity**. Accessibility is TCC-keyed to the code
signature, so an ad-hoc build re-asks on every rebuild; the script prefers
Developer ID, then Apple Development, and warns when it falls back to ad-hoc.

---

# Phase 2 (in progress) — It sees

The hybrid is built and working end to end: accessibility first, Holo1.5 as
fallback, fusion that renders confidence honestly, and a privacy gate that runs
before anything is read or captured.

## The hybrid, demonstrated

Three routes, all verified with `--selftest`:

**Strong AX match — vision never runs.**
```
App      Calendar — 94 nodes, 83 labelled, 37 actionable
Resolve  0.388 ms   1. 1.17  button · Today · today-button
Route    accessibility only — vision not needed
Fusion   accessibility → exact — solid ring
```

**AX miss — vision runs, and the answer is marked as a guess.**
```
App      Gemini — 245 nodes, 17 labelled, 12 actionable
Resolve  no accessibility match — this is the AX-miss path
Vision   click cg(429,957) screen 0
Fusion   vision → uncertain — dashed ring
         the accessibility tree did not expose this control, so this is
         the vision model's guess
```

**Excluded app — nothing is read at all.**
```
Privacy  EXCLUDED — app is excluded (com.apple.mobilesms)
         No tree read, no frame captured. Nothing to point at.
```

## Finding 16 — Gating the screenshot is not enough. The AX tree *is* the content.

The exclusion list originally gated capture only. Testing it against Messages
produced this candidate list:

```
1. 0.25  [redacted: a real Messages thread. The row showed a contact name and message text, which is the entire point of this finding.]
```

No frame was ever captured, and a private conversation leaked anyway — an
accessibility tree carries the content, not merely the controls.

So exclusion now means excluded: **no capture and no tree**, checked before the
first AX call. Title-pattern rules are evaluated against the window title from
`CGWindowList` rather than AX, so testing whether an app is excluded never
requires reading the app.

The trade is real and correct: the coach cannot help you inside your password
manager.

## The sidecar

Holo1.5 runs as a long-running Python process spoken to in JSON lines over
stdio, started **lazily on the first AX miss** — the weights cost ~5.6 GB
resident, and a user whose apps all expose good trees should never pay that.

The coordinate inverse (crop → `smart_resize` → model → undo both) lives in the
sidecar, next to the resize that creates it. Every place that inverse has been
re-derived in this project it has been a bug.

Verified against AX ground truth, same target, same model:

| input | result | TTFT | tokens |
|---|---|---|---|
| full frame | HIT | 9676 ms | 4675 |
| **AX-aimed crop** | **HIT** | **1337 ms** | **648** |

**7.2× faster, same answer** — Finding 10 holding up in the live pipeline.

Vision failure is survivable by design: no Python, no MLX or no weights all
degrade to accessibility-only rather than breaking.

## Fusion, and what earns a solid ring

Agreement between two independent methods is the only thing that earns
confidence. 16 tests pin the policy:

| tree | vision | result |
|---|---|---|
| strong | not run | **exact** |
| weak | not run | uncertain, with the reason |
| none | answered | **uncertain — always**, 58% is not a fact |
| any | agrees (click inside the element) | **exact — corroborated** |
| strong | disagrees | **uncertain**, points at the tree, states the gap in points |
| strong, screen 0 | same coords, screen 1 | conflicted, never agreement |

Corroboration outranks either path alone: a *weak* AX match that vision
independently lands inside is promoted to exact, while a strong AX match that
vision contradicts is demoted to dashed.

## Live reload, verified rather than asserted

`screencoach-bench exclusions` watches the file in a running process:

```
26 apps, 16 title patterns excluded
reload #1: 43 rules — Calendar now EXCLUDED
reload #2: 43 rules — Calendar now EXCLUDED
reload #3: 42 rules — Calendar allowed
```

An edit takes effect before the next query, with no restart. A privacy control
that needs a relaunch is one nobody uses. The file is plain text at
`~/.config/screencoach/exclusions.conf`, seeded with the defaults on first run
so what is excluded can be read rather than trusted. An empty or unparseable
file falls back to the defaults, never to "allow everything".

## Still open in Phase 2

Not yet built, and not claimed: push-to-talk with streaming STT/TTS,
POINT-first streaming, and the ScreenSpot-Pro eval harness against the hybrid.
On-device pre-redaction before cloud calls is moot so far — there are no cloud
calls yet; the coach is entirely local.

---

# Phase 2 (continued) — It speaks, and it is measured

## Voice: push-to-talk, entirely on-device

Hold ⌥Space and say what you are looking for; tap it and type instead. The
microphone runs only between key-down and key-up — no wake word, no always-on
listening, no permanent recording indicator. For an app that already needs
permission to read your screen, a live microphone is one ask too many.

`requiresOnDeviceRecognition` is set whenever the locale supports it, and when
it does not the feature **refuses rather than falling back to Apple's servers**.
"Zero bytes leave the machine" is a property of the code, not a claim.

Two details that matter:

- **Capture starts on key-down, before we know if this is a hold or a tap.**
  Waiting to decide would clip the first word, which is usually the one that
  names the target. A release under 300 ms with nothing heard just leaves the
  bar open for typing.
- **Key-up matches on the key code alone.** Releasing Option before Space
  changes the modifier flags, so requiring the full combination would drop the
  release and leave the microphone running — the worst possible failure here.

The spoken answer carries the same uncertainty the ring does. "Here's the Today
button" for a corroborated hit; "I think it's the Day button, but I'm not
certain" for a dashed one. A confident sentence over a dashed ring would undo
the point of drawing the dashes.

## Finding 17 — The latency budget as a CI gate, and an honest unmeasured list

`screencoach-bench budget` measures each stage against `LatencyBudget` and
exits non-zero on violation:

```
Target: Google Chrome — 85 nodes, 43 labelled

INFO  one-shot display capture  p50  49.74  p90  54.47 ms
      vision path only; the AX path never captures

PASS  ax-extract   n=40  p50 0.00  p90 0.00  p99 0.08 ms   ceiling 80
PASS  ax-resolve   n=40  p50 0.17  p90 0.21  p99 0.42 ms   ceiling 20

AX-hit path total (p50 sum): 0.17 ms  — target 900 ms  PASS
unmeasured: hotkey→frame, frame→image, vision-ground, stt, reason-ttft,
            pointer-start, tts-first-audio
```

The first version of this reported a **false failure**: it timed a one-shot
capture against the 50 ms `hotkey→frame` ceiling, which Phase 0 calibrated
against a *warm SCStream*. The app deliberately keeps no warm stream — the
accessibility path never captures at all, and on the vision path a 50 ms grab
is 2% of a 2.4 s model call, not worth a permanently held capture session and
its permanently live recording indicator.

So capture is reported as information, and `hotkey→frame` is listed as
**unmeasured** rather than passed. An unmeasured stage is not a met budget.

## Finding 18 — The hybrid cannot be evaluated on ScreenSpot-Pro. Structurally.

This changes the Phase 4 launch plan, so it is worth stating plainly.

ScreenSpot-Pro is 3.38 GB of static PNGs captured on other people's machines
(2.43 GB of it macOS). An accessibility tree is **live process state**. There is
no AX tree for a screenshot, so an AX-first grounder run against ScreenSpot-Pro
scores exactly its vision-only number — the benchmark is structurally incapable
of seeing the contribution.

The plan of "run the hybrid on ScreenSpot-Pro and beat 63.25" cannot be
executed as written. What remains valid:

1. **ScreenSpot-Pro still calibrates the vision path.** Reproducing Holo1.5-7B's
   published 57.94 with our harness would validate it as a component. Worth
   doing; it is a download, not a redesign.
2. **The hybrid needs a live-machine eval**, which is what `Tools/live_eval.py`
   is. Ground truth is AX bounds — verified pixel-exact against both Logic Pro
   and Chrome — and a hit is a predicted point inside the element's real box,
   the same criterion ScreenSpot-Pro uses. Comparable in kind, different target
   set.

## First live-eval numbers

Chrome, 12 targets, four conditions:

| condition | accuracy | p50 latency | image tokens |
|---|---|---|---|
| **ax_only** | **12/12 = 100%** | **0.1 ms** | 0 |
| vision_full | 11/12 = 91.7% | 7317 ms | 4675 |
| vision_axcrop | 10/12 = 83.3% | 1204 ms | 756 |
| **hybrid** | **12/12 = 100%** | **0.1 ms** | 0 |

The hybrid resolved **12/12 on the tree alone** and never loaded the model.

**These numbers are not comparable to 57.94 or 63.25.** One app, twelve
targets, and Chrome's toolbar is a far easier target set than ScreenSpot-Pro's
dense professional UIs — the same Holo1.5 scored 40% on Logic Pro earlier in
this document and 91.7% here. The honest claim is narrower and still
interesting: *on an app that exposes a good accessibility tree, the hybrid is
exact and effectively free, and vision is never invoked.* Establishing anything
broader needs many apps, including deliberately AX-hostile ones.

## Finding 19 — A zero-target snapshot must never overwrite a good one

Re-snapping Chrome while a video was fullscreen produced an 8-node tree with
zero usable targets and destroyed the 107-node capture an evaluation depended
on. Snapshots are eval inputs; `snap` now refuses to write when it finds no
targets and says why.

## Phase 2 status

Built and verified: Holo1.5 fallback, fusion with confidence rendering,
push-to-talk on-device STT, on-device TTS, latency instrumentation with a CI
gate, window/display capture, hot-reloading exclusion list that blocks reading
as well as capture, and a live-machine eval harness.

Not built: POINT-first *streaming* in the LLM sense — there is no streaming
reasoning model in the loop yet, so the current equivalent is showing the tree's
answer immediately and upgrading the ring when vision lands. Full permission
onboarding is partial (Accessibility has a proper prompt; microphone and speech
rely on the system's first-use dialogs). ScreenSpot-Pro calibration of the
vision path is not run.

---

# Phase 3 (in progress) — It teaches

The difference between a coach and a search box is that a coach **watches**.
Pointing answers a question; teaching means "now do this, and I'll wait — and
I'll know when you've done it."

Every step carries a completion condition expressed against the accessibility
tree, so advancing is evidence-driven. A tutorial that advances on a timer is
wrong for anyone slower than its author; one that advances on a Next button
cannot tell whether you did the thing or just clicked Next. The tree can see
the dialog open and the value change, so the coach can too.

```
App        Google Chrome — 78 nodes
Step       "the New Tab button"
Detect     unchanged tree → pending (correct)
Detect     value changed  → COMPLETE (correct)
Lesson     showing 1/1  Look at this control
Render     scrim + badge 1 on AXButton (score 0.96)
Watcher    held on the manual step (correct)
Manual     advance → lesson complete
```

Completion conditions: `elementAppears`, `elementDisappears`, `valueChanges`,
`targetChanges`, and `manual`. The last one is the honest option for steps the
tree cannot observe — a brush stroke, a colour pick — and it never
auto-advances rather than inventing a condition that fires at random.

Watching is nearly free: `AXCache` already re-reads on AXObserver events, which
are exactly the events that accompany "the user did the thing", so the runner
polls the cache and compares trees. The poll is well under a millisecond.

**Comparison is against the step's *starting* tree, not the previous poll.** A
change spread over several observer events never looks like a change between
consecutive polls — each is identical to the last — so a step that took a
moment would never complete.

## Finding 20 — Presence needs a different *measure* than pointing, not a different threshold.

Two attempts failed before this landed, and both were instructive.

**Attempt 1 — reuse the pointing score.** A correctly-detected Preferences
sheet scored **0.609** against the 0.62 hit threshold and never fired. The
cause is the size penalty that stops containers winning as *pointing* targets:
"did a dialog appear" is a question about a container by definition, and a
sheet is legitimately sheet-sized. The calibration that makes pointing correct
makes presence detection impossible.

**Attempt 2 — keep the score, lower the bar to 0.50.** Now a "Preferences"
*button* satisfied a check for a "Preferences Window" at 0.625. The dialog
looked open before it had opened, so the step auto-advanced instantly and the
lesson raced to the end without the user doing anything.

**The fix is recall, not a threshold.** Presence requires the element's label
to contain essentially all of the query's content words (≥ 0.8). Partial credit
is correct for ranking — "which of these is most likely what you meant" — and
wrong for existence, where the question is "is this thing here yet".

## Annotation vocabulary

- **Dimming scrim with the target cut out** — one `CAShapeLayer` with
  `fillRule = .evenOdd`, the outer rect and the target rect in one path so the
  overlap cancels. The single most effective "look here" affordance there is.
- **Numbered step badge**, offset outside the target so it never covers the
  thing it points at.
- The bezier arc and confidence ring from Phase 1, unchanged.

A one-shot answer never dims the screen — doing that to answer a quick question
would be obnoxious — and `point()` explicitly clears any scrim a previous
lesson left behind.

## Built-in lessons, and why there are only two

`BuiltInLessons` ships "Open this app's settings" and "Find something in this
app". Per-app knowledge packs are the eventual shape, but a pack for an app the
user does not own is dead weight, and one written from memory rather than from
the app's real accessibility tree will confidently name controls that do not
exist. The two that ship name targets identically across essentially every Mac
app.

## Phase 3 status

Built: multi-step lessons, AXObserver-driven auto-advance with tree-diff
completion detection, scrim, numbered badges, spoken instructions, manual
advance and step-back, and a 120 s per-step timeout that stops watching rather
than spinning.

Not built: traced paths across a sequence, per-app knowledge packs. **Local-only
mode is already complete and is not a mode** — there is no cloud path in the
product at all, which also makes on-device pre-redaction moot: there is nothing
to redact *for*. Both become real work only if a cloud reasoning model is added
for the teaching-explanation step the brief describes.

---

# Phase 4 (in progress) — "Watch me" mode

Record a workflow by doing it once; the coach teaches it later — or on a
different machine — by re-grounding every step against the live accessibility
tree. Nothing in a recording refers to the machine that made it: no
coordinates, no window sizes, no display geometry. Only names. **Moving the
JSON file is the whole cross-machine story**, and it is only possible because
grounding is semantic — the Phase 4 premise from the brief, now running.

```
HitTest    centre of "New Tab" → AXButton (exact)
Record     synthesized "the New Tab button"
Replay     loaded from disk, re-grounded at 0.96 — AXButton
```

## How a click becomes a step

1. **Hit-test** the click against the warm tree: smallest labelled element
   containing the point, actionable preferred. Smallest is the load-bearing
   word — every click is also inside the window, a group, and a scroll area,
   and "you clicked the window" teaches nothing. If only a huge container
   matches, the click is skipped rather than misrecorded.
2. **Synthesize the query** in the resolver's own vocabulary — nouns drawn
   from `roleHints` so the recording earns the role-agreement bonus instead of
   polluting its content terms ("pop-up button" would have leaked "pop" and
   "up" into recall). The container clause follows the Phase 0b place-name
   rules; window titles never appear in queries.
3. **Wait for the UI to settle, then diff** the before/after trees to learn
   what the click *did* — vanished element → `elementDisappears`; value or
   enabled flipped → `targetChanges`; something labelled appeared → 
   `elementAppears` (largest arrival: the sheet is the event, not the dozen
   buttons inside it); nothing observable → `.manual`, honestly.
4. If the **next click arrives before the settle timer**, that click's
   before-tree closes the previous step. The state of the world when the
   author moved on is by definition the state their step produced — fast
   clickers record correctly instead of racing a timer.

## Finding 21 — Inference and replay must identify elements the same way.

Node ids are BFS order and **not stable across snapshots**, so the recorder
re-finds the clicked element in the after-tree by its query — exactly how
`LessonEngine` will re-find it at replay time. A test pins the property
directly: every completion the recorder infers must actually fire when the
engine watches the same transition. If the two ever diverged, recordings would
encode conditions replay can never observe, and every recorded lesson would
stall on step one looking correct.

## Serialization is part of the product

Recordings are pretty-printed JSON with hand-written enum coding —
`{"kind": "appears", "query": "Share Options"}`, not synthesized
`{"elementAppears":{"_0":…}}` soup. Someone will open one of these files to
audit what a shared workflow does before running it; for a tool that watches
clicks, a file a person can read is a property, not polish. Unknown completion
kinds fail loudly at load. Saving never silently replaces an existing
recording.

## Verified, and honestly not verified

Verified headlessly: hit-testing against the live tree (exact on a real
element's centre), query synthesis round-tripping through the real resolver,
completion inference in all five cases, engine/inference agreement, disk
round-trip, and replay of the loaded file re-grounding at 0.96. 93 tests.

Not verified: a full recording session driven by real human clicks — the
`MouseTap` is the same proven listen-only-tap-on-its-own-thread pattern as the
hotkey, but nobody has clicked through a workflow yet. And a real limitation:
**the recorder cannot see menu-bar interactions**, because the extractor walks
the focused window's subtree and `AXMenuBar` (and open menus) are siblings of
the window, not children. In-window workflows — toolbars, panels, sheets,
bookmarks — record fully; "open the File menu" does not, yet. Fixing it means
extracting from the app element during recording, which is a scoped follow-up,
not a redesign.

---

# Phase 4 (continued) — Menus, and un-breaking the built-in lessons

Finding 36's limitation turned out to be a live defect, not a future one: the
built-in lessons shipped in Phase 3 teach *through menus* ("Open the app menu,
choose Settings") — and the extractor walked only the focused window's
subtree, where the menu bar does not live. The lessons could not resolve their
own first step.

## Finding 22 — Menu extraction must be gated on `kAXSelected`, or appears-conditions die.

AX exposes the **entire menu hierarchy even while every menu is closed** —
every item of every menu, always present. Extract it all and "Settings" exists
before the menu ever opens, so `elementAppears("Settings")` can never fire:
the already-present rule (itself protecting against instant auto-advance)
vetoes it forever.

The gate: menu bar items are always extracted; a menu's *contents* enter the
tree only while `kAXSelected` is true on its menu bar item — which is AX for
"my menu is open right now". The same gate on `AXMenuItem` keeps closed
submenus shut. Closed menus contribute exactly one pointable node each; open
menus contribute their real, on-screen items. `kAXSelected` rides in the same
batched read as everything else — twelve attributes, still one round trip.

The menu bar enters the BFS queue **first**, so a heavy window hitting the
walk deadline can never starve it.

## Finding 23 — A background app's menu bar has junk geometry.

Pinned to background Calendar, its menu bar items reported bounds of
`(-1,33 1×0)` — zero-size, off-screen. Frontmost, the same items report real
bounds (`Calendar` at 43,0 79×33). macOS only lays out the menu bar of the
active app. Harmless in production — the coach targets the frontmost app —
but any test pinned to a background app will see menu items that exist and
cannot be pointed at. The zero-area guard in the resolver already keeps them
from winning.

## The `{app}` template

macOS puts Settings in a menu named after the app — "Calendar" in Calendar,
"Logic Pro" in Logic — so a lesson written once cannot name that menu
statically. Steps may now say `{app}`, substituted at run time everywhere it
matters (instruction, target, completion query). Recordings never emit
templates; only hand-written lessons use them.

Verified live on the adversarial case: the app is named "Google Chrome" but
its menu is titled "Chrome", so the substituted query only half-matches —

```
1. 0.74  menu bar item · Chrome  cg=(43,0 72×33)   ← solid ring
2. 0.32  pop up button · Chrome  cg=(716,78 34×34)  ← in-window impostor
```

The role-agreement bonus ("menu" implies `AXMenuBarItem`) carries the true
target over the threshold and past an identically-labelled in-window control —
precisely the disambiguation it was calibrated for in Phase 0b.

Also fixed by this: **the recorder can now see menu-bar clicks**, and the
pointer can land on items inside an open menu — when step 1 of the Settings
lesson completes, step 2's pointer lands on the actual Settings item in the
open menu, because the open menu's contents are in the tree at that moment.

One honest lag note: menu-open detection reaches the cache via AXObserver
events (focused-element-changed fires on menu tracking) with the 3 s heartbeat
as the backstop, so a step watcher can trail a menu opening by up to a few
seconds in the worst case.
