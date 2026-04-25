# Recording Analysis

This document is the recording-first triage doctrine for `swarm-full-flow`. The agent does not have a visual cortex. It must consume the `.mov` mechanically using the recipes, thresholds, and act-anchored ground truth in this file.

## Investigation order

1. The recording first: startup, shutdown, retries, relaunches, visible UI state, disabled surfaces, wrong states, stalls, pauses, layout/readability issues, interaction failures.
2. Then the supporting artifacts: screenshots, hierarchy dumps, logs, `xcresult` exports, persisted state.
3. Order is fixed: video first, everything else second. A finding sourced only from a log without a recording timestamp is not promoted.

## Ground truth per act

For every act marker the lane already produces three pieces of truth at a known wall-clock:

- `act-driver.log` line for `actReady("actN", ...)` is the wall-clock anchor for the act window. The matching `actAck("actN")` line closes the window.
- `ui-snapshots/<actN>.png` is what the Monitor app rendered when the XCUITest asserted the act state.
- `ui-snapshots/<actN>.txt` is the SwiftUI hierarchy and accessibility-identifier tree at that same moment.

Triage compares the recording frame at the matching wall-clock against this ground truth. Discrepancies are findings:

- If the `.png` shows the badge as `AwaitingReview` and the recording frame at the same timestamp shows `Open`, that is a render-pipeline finding.
- If the `.txt` shows a button is `enabled=true` and the recording frame shows it greyed out, that is either a styling bug or a hierarchy lie. Either way it is a finding.
- If the `.txt` lists an accessibility identifier that has no visible affordance in the recording frame, that is a missing-surface finding.

The full per-act expected surface is documented in [act-marker-matrix.md](act-marker-matrix.md). Read it before promoting any act-bound finding.

## Detection recipes

Bake these into [recording-triage scripts](../../../../scripts/e2e/recording-triage/) when they are run more than once. Run them ad-hoc when triaging a specific window.

### Per-act keyframes

```
ffmpeg -ss <ts> -i swarm-full-flow.mov -frames:v 1 -y <act>.png
```

Extract three frames per act: at `actReady`, at `actAck`, and 250 ms before each transition. Compare each frame against `ui-snapshots/<actN>.png` via per-pixel histogram or perceptual hash. Hash distance above the calibrated threshold is a render-mismatch finding.

### Frame freezes and stalls

```
ffprobe -show_frames -of compact=p=0 swarm-full-flow.mov \
  | awk -F= '/pkt_pts_time=/ {print $NF}'
```

Compute inter-frame gaps:

- Gap > 50 ms during expected motion is a hitch.
- Gap > 250 ms without a clear cause is a stall.
- Gap > 2 s mid-run outside known waits is a freeze.
- Idle gap > 5 s outside act boundaries with no `act-driver.log` activity is a stall finding.

Three or more hitches in a single segment is a perf finding even when no individual gap crosses 250 ms.

### Dead head and dead tail

Compare the `.mov` first-frame timestamp against the daemon-log app-launch line, and the `.mov` last-frame against the test `terminate` line. Either side > 5 s is a recording-artifact finding. Re-evaluate the recorder window and start handshake when this fires.

### Animation thrash

Sample 10 fps across 2 s windows. In each window count the frames whose perceptual hash differs from the previous frame above the calibrated delta. If a screen region changes more than 3 times in any 500 ms window without user input, flag flicker.

### Layout drift

Compare the bounding box of every accessibility-identified element across consecutive keyframes from `ui-snapshots/<actN>.txt` hierarchy dumps. The same element shifting more than 2 pt between adjacent acts without a user action is layout drift.

### Black or blank frames

A frame whose mean luminance is below 5 or whose unique-color count is below 10 is suspect. Allow during known transitions only.

## Per-launch checklist

One recording segment maps to one app launch. Apply this checklist to every segment in the iteration. The post-analysis proof pass in [recording-checklist.md](recording-checklist.md) drives the verdict for each item; this section explains the threshold behind each verdict.

### A. Process and lifecycle

- Time-to-first-frame from process spawn target ≤ 2 s on M-series. Anything ≥ 4 s is a finding.
- Time-to-populated-dashboard from first frame target ≤ 1 s. Anything ≥ 2 s is a finding.
- Daemon-manifest pickup latency: gap between first frame and first daemon-confirmed UI state > 1 s when manifest already exists on disk is a finding.
- Cold vs warm start: when the lane relaunches in one iteration the warm start must be measurably faster than the cold start.
- Termination cleanliness: orderly `NSApplication.terminate`, not `SIGTERM`, and never a crash dialog. Hung windows or beachballs in the last 5 s of a segment are findings.
- Window-restore noise: with `-ApplePersistenceIgnoreState YES` set, no prior-session window state may reappear. If it does the launch arg is wired wrong - finding.

### B. First-frame state

- Loading vs empty vs populated must be visually distinguishable at a glance. Three states must use three different surface treatments. Any pair that look alike is a communication-failure finding.
- Disabled vs enabled controls must reflect the underlying capability, not the sequencing. A button that should be enabled but renders disabled is a state-lie finding.
- Sidebar or list selection must have a visible highlight when selection is non-nil. A non-nil selection without highlight is a focus finding.
- Glass and material regressions: sidebar opaque flashes, toolbar Liquid Glass loss after inspector toggle, detail backdrop bleeding, and glass-on-glass stacks are visible-design findings.

### C. State transitions between acts

- Every state transition must be animated, never a snap. Transition animations must complete within 200 ms.
- Transitions must terminate. A transition still in motion 500 ms after the trigger is a finding.
- Controls inside a moving region must remain hit-testable or visibly disabled. Phantom controls that are visible but not hittable are interaction findings.
- Toast queue: new toasts must enqueue, not stack. Two toasts visually overlapping for more than one frame is a finding.
- Modal sheet flow: sheet must center, present in < 200 ms, dismiss in < 200 ms, no flicker either way.

### D. Idle behavior between acts

- Outside known live-data fields (timestamps, counters, progress bars), idle frames must be pixel-stable for ≥ 2 s.
- No animations on always-visible chrome. Repeating animations during idle are a perf and attention-thrash finding.
- No unexplained re-renders. Pixels changing while no input was given and no live data was expected is a finding.
- CPU smell: visible jank during otherwise idle frames suggests a render loop. Cross-reference `act-driver.log` for the same window. Silence in the log plus motion on screen is a smell.

### E. Animation, performance, hitches

- Inter-frame gap > 50 ms during animation is a hitch. Three or more in a single segment is a perf finding.
- Inter-frame gap > 250 ms without a clear cause is a stall.
- First-frame layout thrash: bounds-box changes > 3 within 500 ms after a navigation is a finding.
- Toolbar quantization stutter on FocusedValue updates: rapid back-and-forth size changes in the toolbar are a finding.

### F. Readability and accessibility

- Truncation that hides the primary affordance is a finding. Truncation of secondary metadata is acceptable when a tooltip or detail surface is reachable.
- Text contrast: foreground vs background WCAG ratio < 4.5:1 for body text and < 3:1 for large text is a finding. Sample from the `ui-snapshots` PNG.
- Tap targets < 24 × 24 pt for primary actions are a finding. < 32 × 32 pt for primary actions on macOS is a smell.
- Cmd+/- font scaling regressions: the `Font.scaled(by:)` system must propagate. Views that ignore it are findings.
- Density spikes: count visible interactive elements per region per frame. A spike that exceeds surrounding density by 2× is clutter.

### G. Interaction fidelity

- Click-to-feedback latency must be < 100 ms. A click that produces no visible response within 100 ms is a finding.
- Hover gating: hover-revealed affordances must appear within 50 ms of pointer entry and disappear within 50 ms of exit.
- Drag-drop: every drag must show a drag preview within 100 ms. Every drop on a valid target must produce immediate state change, not a round-trip.
- Keyboard shortcuts: every shortcut firing must produce visible feedback within 100 ms.

### H. Swarm-specific UI (cross-reference act-marker-matrix.md)

- Agents card runtime icon must be correct for every joined role per [act-marker-matrix.md](act-marker-matrix.md) `act2`: leader/claude, worker/codex, worker/claude, reviewer/claude, reviewer/codex, reviewer/claude duplicate (must be visibly rejected, not silently accepted), observer/claude, improver/codex, plus optional gemini/copilot/vibe.
- Review-state badge transitions must be visible and timestamped: `Open -> AwaitingReview -> InReview -> Done`. A badge skipping an intermediate state is a finding.
- Arbitration banner must appear on entry into round-3 arbitration (`act13` window) and dismiss on the final approve.
- Heuristic issue cards: one card per injected code at `act5`. The ten codes are listed in [act-marker-matrix.md](act-marker-matrix.md). Missing cards or wrong code labels are findings.
- `workerRefusal` toast must fire at `act11`. Missing toast or stale label is a finding.
- `signalCollision` toast must fire at `act14`. Missing toast or duplicate stack with `act11` is a finding.
- Auto-spawn-reviewer indicator must appear after the reviewer-removal cascade in `act10`.
- Round-counter pill must increment 1 -> 2 -> 3 across the three request-changes rounds in `act12` and `act13`.
- Partial-agreement chip must appear when the worker disputes `p2`/`p3`.
- Daemon-health indicator must remain green throughout a passing run. Any flap is a finding.

### I. Recording artifact verification

- `.mov` starts within 5 s of process spawn and ends within 5 s of process exit. Anything outside the 5 s band is a dead-head or dead-tail finding.
- No frame freezes > 2 s mid-run except known waits (daemon manifest pickup, model selection).
- No black frames except known transitions.
- File size in the expected band: > 5 MB and < 2 GB for a typical run. Truncated captures are findings.
- One segment per launch. Multi-launch iterations yield multi-segment captures with no dead time across launches.

## Suite-speed lens

Treat any wait that could have started the next safe action as a finding on the loop, even when the app state itself is correct.

- Look for dead head, dead tail, relaunch gaps, delayed assertions, slow handoffs, and repeated waits that lengthen the run or recording.
- Prefer fixes that shrink the capture or remove pointless waiting over fixes that only explain the delay.
- When the lane is correct but slow, record the opportunity as a suite-speed finding. Use the same ledger schema; severity reflects user-visible impact.

## UX heuristics translated to mechanical signals

The agent applies UX qualities only through observable signals.

- **Communication failure** - the user cannot tell what state the app is in. *Detection:* loading vs empty vs error visually identical (perceptual-hash distance between the three below threshold); status badge that does not change color or shape on transition; progress feedback absent during operations the log shows took > 1 s.
- **Attention thrash** - UI moves or changes when the user did nothing. *Detection:* layout-shift count > 0 per second of idle; animations on always-visible chrome; pixel changes outside live-data regions in idle frames.
- **Trust erosion** - UI shows stale, wrong, or contradictory info. *Detection:* badge says state X but content area shows state Y at the same timestamp; daemon-health green but agent roster empty; review counts disagree across surfaces (sidebar count vs inspector count vs metrics card).
- **Friction** - user cannot accomplish an action smoothly. *Detection:* click-to-feedback > 100 ms; double-click required where single should suffice; drag-drop drops on the wrong target; modal where an inspector would suffice; sheet that blocks routine flow.
- **Cognitive load spike** - too much information at once. *Detection:* visible-element density spikes > 2× surrounding density; mixed type sizes within one card; > 3 simultaneously animating regions.
- **Polish drift** - looks like a prototype, not a product. *Detection:* spacing not on the 8 pt grid; mixed corner radii within one panel; opaque-vs-glass mixing in the same surface; rectangular focus-ring fallback in lists; shadow noise on `.glass` or `.glassProminent` controls.
- **Reliability smell** - even if nothing fails, something looks unsafe. *Detection:* error states appearing transiently before correct states settle; flicker between two values; controls enabling and re-disabling in rapid succession; values that briefly show `nil` or `—` before populating.
- **Iteration drag** - avoidable waiting that lengthens the recording or loop. *Detection:* dead head, dead tail, relaunch gaps, delayed assertions, slow handoffs, redundant repeated waits.

## Right vs wrong signatures

Right:

- App window appears with populated content within ≤ 2 s of process spawn.
- Every state transition is animated, transition completes ≤ 200 ms, idle UI is pixel-stable ≥ 2 s.
- Controls reflect their state via shape + color + label, not just one channel.
- Toolbar and sidebar Liquid Glass intact across navigation, inspector toggle, and modal flow.
- New toasts queue, do not overlap.
- Click-to-feedback < 100 ms, hover < 50 ms.
- Recording starts within 5 s of process spawn, ends within 5 s of process exit, no idle freezes > 2 s outside known waits.
- Final dashboard summary at end of run shows all expected acts as Done or Closed with daemon-health green.

Wrong:

- Snap (no animation) on transitions; opacity flips without crossfade.
- Spinner without follow-up state change.
- Layout reflow on every keystroke.
- Truncation that hides the primary action.
- Modal sheet blocking what an inspector should host.
- Click handlers that fire twice (badge flickering between two states briefly).
- Recording showing the app frozen ≥ 2 s without a progress signal.
- Liquid Glass disappearing after inspector toggle and never coming back.
- Sidebar opaque flash on app launch before real material settles.
- Focus-ring rectangular fallback inside a list (NSTableView leak).
- Same value rendered differently across two surfaces in one frame.

## Checklist pass

After the chronological recording review, run the proof checklist in [recording-checklist.md](recording-checklist.md) and keep the short verdict lines with the iteration notes. Do not move to secondary artifacts until the checklist pass is complete.
