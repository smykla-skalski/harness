---
name: swarm-e2e-iterate
description: Recording-first infinite-iteration loop for the harness-monitor swarm full-flow e2e. Runs the lane, walks the .mov, lands TDD fixes, re-runs until zero open findings.
---

# Swarm e2e iteration loop

This skill drives the harness-monitor `swarm-full-flow` e2e through a
recording-first quality-improvement loop. Every iteration runs the lane,
walks the screen recording end to end, lands recording-confirmed
findings into a persistent ledger, fixes every Open finding under TDD
with signed commits and green gates, then re-runs. The loop terminates
only when an iteration completes with zero new findings AND the ledger
holds zero Open items.

The recording walk precedes every other artefact in the loop, in the
plan, and in the skill body. No iteration completes without producing
and processing the .mov; no triage row promotes without a recording
timestamp range plus one secondary artefact reference.

Triggers: `/swarm-e2e-iterate`, "iterate the swarm e2e", "run the swarm
loop", "find every issue in the swarm e2e", "drive the swarm to zero
findings".

## Hard rules (every cycle)

1. **Recording handling is mandatory.** No iteration completes without
   producing and processing the recording.
2. **The first triage step is the recording.** Always. Before any other
   artefact.
3. **Recording-first cannot be skipped, deferred, or run in parallel**
   with xcresult/log/state triage.
4. **Only after the recording has been reviewed end to end** can other
   artefacts be triaged, and only to support or extend findings already
   framed against the recording timeline.
5. **The recording must match the app lifecycle.** A segment starts at
   app startup/launch (NSApp first frame after process spawn) and ends
   at app shutdown/termination. Multiple launches in one iteration must
   yield multiple segments. A single capture spanning multiple launches
   with idle dead time between them is itself a finding.
6. **Avoid duplicate expensive reruns.** Reuse one recording per
   iteration. Re-run the lane only when fixes have landed and a new
   capture is required.
7. **Triage records confirmed findings from the recording first**, then
   uses screenshots, hierarchy dumps, logs, xcresult exports, and
   persisted state to support and extend those findings.
8. **Real findings only.** No invention, no severity inflation, no
   closing without code/test proof. If unsure, mark
   `needs-verification` and re-watch the segment before promotion.
9. **TDD is mandatory.** Failing test first → confirm red → implement →
   confirm green → run gate → sign-and-commit → verify signature.
10. **Smallest independently committable chunk per fix.** Never bundle
    unrelated fixes.
11. **Right gate per stack.** Rust → `mise run check`. Swift →
    `mise run monitor:macos:lint` plus the relevant scoped build/test
    lane. Cross-stack → both.
12. **No version bumps inside iteration.** Bumps land on main after the
    loop terminates.
13. **No full UI suite.** All targeted XCTest runs use
    `XCODE_ONLY_TESTING=Target/Class/method`.
14. **All commands through mise + rtk.** No raw cargo, no raw
    xcodebuild, no direct script calls when a mise task exists. Never
    `rtk proxy` (bypasses output filters).
15. **Commit signing is strict.** `git commit -sS`. Sign-off must be
    exactly `Bart Smykla <bartek@smykla.com>`. If 1Password is
    unavailable, hard stop and wait.

## §4.2 detection recipes (verbatim)

- **Extract per-act keyframes.** Use
  `ffmpeg -ss <ts> -i swarm-full-flow.mov -frames:v 1 -y <act>.png` at
  each act boundary timestamp (derived from act-driver.log entries —
  every `actReady` write is a wall-clock anchor). Write a frame for the
  act start (act ready), the act end (act ack), and a frame 250 ms
  before each transition. Compare these frames against the matching
  `ui-snapshots/<actN>.png` ground-truth checkpoint exported by the
  XCUITest — both should depict the same UI state. Diff via per-pixel
  histogram or perceptual hash.
- **Detect frame freezes.**
  `ffprobe -show_frames -of compact=p=0 swarm-full-flow.mov | awk -F= '/pkt_pts_time=/ {print $NF}'`
  then compute inter-frame gaps. Any gap > 50 ms during expected motion
  is a hitch. Any gap > 2 s outside known waits is a freeze. Outside the
  act boundaries, idle gaps > 5 s with no log entries are a stall
  finding.
- **Detect dead head/tail.** Compare the .mov's first frame timestamp
  against the daemon-log's app-launch line, and the .mov's last frame
  against the test's `terminate` line. > 5 s either side is a
  recording-artefact finding.
- **Detect animation thrash.** Sample 10 fps across 2 s windows; in each
  window, count the number of frames whose perceptual hash differs from
  the previous by > N. If a region of the screen changes > 3 times in
  any 500 ms window without user input, flag flicker.
- **Detect layout drift.** Compare the bounding-box of every
  accessibility-identified element across consecutive keyframes from
  `ui-snapshots/<actN>.txt` hierarchy dumps. If the same element shifts
  > 2 pt between adjacent acts without a user action, flag layout
  drift.
- **Detect black/blank frames.** A frame whose mean luminance is < 5 or
  whose unique-color count is < 10 is suspect. Allow during known
  transitions only.

The reproducible implementations live under
`scripts/e2e/recording-triage/` (assert-recording, extract-keyframes,
frame-gaps, compare-keyframes, detect-dead-head-tail, detect-thrash,
detect-black-frames, run-all). The Swift detector logic lives in
`apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/RecordingTriage.swift`
and is exposed via `harness-monitor-e2e recording-triage <subcommand>`.

## §4.4 per-launch checklist (verbatim, applied per segment)

**A. Process and lifecycle**
- Time-to-first-frame from process spawn (target ≤ 2 s on M-series).
  Anything ≥ 4 s is a finding.
- Time-to-populated-dashboard from first frame (target ≤ 1 s; cached
  daemon should be sub-second). Anything ≥ 2 s is a finding.
- Daemon-manifest pickup latency: the gap between first frame and first
  daemon-confirmed UI state. Anything > 1 s when manifest already exists
  on disk is a finding.
- Cold vs warm start: compare two consecutive launches in the same
  iteration if the lane relaunches; warm start should be measurably
  faster.
- Termination cleanliness: orderly NSApplication.terminate vs SIGTERM vs
  crash dialog. Hung windows or beachballs in the last 5 s of a segment
  are findings.
- Window-restore noise: with `-ApplePersistenceIgnoreState YES` set, no
  prior-session window state should reappear. If it does, the launch
  arg is wired wrong — finding.

**B. First-frame state**
- Loading vs empty vs populated must be visually distinguishable at a
  glance — three states, three different surface treatments. Any pair
  that look alike is a communication-failure finding.
- Disabled vs enabled controls must reflect the underlying capability,
  not the sequencing. A button that should be enabled but renders
  disabled is a state-lie finding.
- Sidebar/list selection must have a visible highlight when selection
  is non-nil. A non-nil selection without highlight is a focus finding.
- Glass/material regressions: sidebar opaque flashes, toolbar Liquid
  Glass loss after inspector toggle, detail backdrop bleeding,
  glass-on-glass stacks. Any of these are visible-design findings.

**C. State transitions between acts**
- Every state transition must be animated, never a snap. Transition
  animations must complete within 200 ms.
- Transitions must terminate. A transition still in motion 500 ms after
  the trigger is a finding.
- During transitions, controls in the moving region must remain
  hit-testable or visibly disabled. Phantom controls (visible but not
  hittable) are interaction findings.
- Toast queue: new toasts must enqueue, not stack. Two toasts visually
  overlapping for > 1 frame is a finding.
- Modal sheet flow: sheet must center, present in < 200 ms, dismiss in
  < 200 ms, no flicker either way.

**D. Idle behavior between acts**
- Outside known live-data fields (timestamps, counters, progress bars),
  idle frames must be pixel-stable for ≥ 2 s.
- No animations on always-visible chrome. Repeating animations during
  idle are a perf and attention-thrash finding.
- No unexplained re-renders. If pixels change while no input was given
  and no live data was expected, it is a finding.
- CPU smell: visible jank during otherwise idle frames suggests a
  render loop. Cross-reference the `act-driver.log` for the same window
  — silence in the log plus motion on screen is a smell.

**E. Animation, performance, hitches**
- Inter-frame gap > 50 ms during animation is a hitch. Three or more in
  a single segment is a perf finding.
- Inter-frame gap > 250 ms without a clear cause is a stall.
- First-frame layout thrash: bounds-box changes > 3 within 500 ms after
  a navigation is a finding.
- Toolbar quantization stutter on FocusedValue updates: rapid
  back-and-forth size changes in the toolbar are a finding.

**F. Readability and accessibility**
- Truncation that hides the primary affordance is a finding. Truncation
  of secondary metadata is acceptable if a tooltip or detail surface is
  reachable.
- Text contrast: foreground vs background WCAG ratio < 4.5:1 for body,
  < 3:1 for large text, is a finding. Use the ui-snapshots PNG for
  sampling.
- Tap targets < 24 × 24 pt for primary actions are a finding;
  < 32 × 32 pt for primary actions on macOS is a smell.
- Cmd+/- font scaling regressions: the `Font.scaled(by:)` system should
  propagate; views that ignore it are findings.
- Density spikes: count visible interactive elements per region per
  frame; sudden spikes that exceed surrounding density by 2× indicate
  clutter.

**G. Interaction fidelity**
- Click-to-feedback latency must be < 100 ms. Any click that produces
  no visible response within 100 ms is a finding.
- Hover gating: hover-revealed affordances must appear within 50 ms of
  pointer entry and disappear within 50 ms of exit.
- Drag-drop: every drag must show a drag-preview within 100 ms; every
  drop on a valid target must produce immediate state change, not after
  a round-trip.
- Keyboard shortcuts: every shortcut firing must produce visible
  feedback within 100 ms.

**H. Swarm-specific UI (cross-reference act markers act1..act16)**
- Agents card runtime/icon must be correct for every joined role:
  leader/claude, worker/codex, worker/claude, reviewer/claude,
  reviewer/codex, reviewer/claude duplicate (must be visibly rejected,
  not silently accepted), observer/claude, improver/codex, plus
  optional gemini/copilot/vibe.
- Review-state badge transitions must be visible and timestamped:
  `Open → AwaitingReview → InReview → Done`. Missing intermediate
  transitions are findings (badge skipping a state).
- Arbitration banner: must appear on entry into round-3 arbitration
  (act12+) and dismiss on final approve.
- Heuristic issue cards: one card per injected code
  (`python_traceback_output`, `unauthorized_git_commit_during_run`,
  `python_used_in_bash_tool_use`, `absolute_manifest_path_used`,
  `jq_error_in_command_output`, `unverified_recursive_remove`,
  `hook_denied_tool_call`, `agent_repeated_error`,
  `agent_stalled_progress`, `cross_agent_file_conflict`). Missing cards
  or wrong code labels are findings.
- workerRefusal toast must fire at act11 (the awaiting-review worker
  assignment that should be rejected).
- signalCollision toast must fire at act14 (the duplicate signal send).
- Auto-spawn-reviewer indicator must appear after act10's reviewer
  removal cascade.
- Round-counter pill must increment 1 → 2 → 3 across the three
  request_changes rounds in act12.
- Partial-agreement chip must appear when worker disputes p2/p3.
- Daemon-health indicator: must remain green throughout a passing run;
  any flap is a finding.

**I. Recording artifact verification**
- .mov starts within 5 s of process spawn and ends within 5 s of
  process exit. Flag dead head/tail.
- No frame freezes > 2 s mid-run except known waits (daemon manifest
  pickup, model selection).
- No black frames except known transitions.
- File size in expected band (> 5 MB, < 2 GB for typical run).
  Truncated captures are findings.
- One segment per launch. Multi-launch iterations yield multi-segment
  captures with no dead time across launches.

## §4.5 UX heuristic detection (verbatim)

- **Communication failure** — the user cannot tell what state the app
  is in. *Detection:* loading vs empty vs error visually identical
  (perceptual-hash distance between the three < threshold); status
  badge that does not change color/shape on transition; progress
  feedback absent during operations the log shows took > 1 s.
- **Attention thrash** — UI moves or changes when the user did nothing.
  *Detection:* layout-shift count > 0 per second of idle; animations
  on always-visible chrome; pixel changes outside live-data regions in
  idle frames.
- **Trust erosion** — UI shows stale, wrong, or contradictory info.
  *Detection:* badge says state X but the content area shows state Y at
  the same timestamp; daemon-health green but agent roster empty;
  review counts disagree across surfaces (sidebar count vs inspector
  count vs metrics card).
- **Friction** — user cannot accomplish an action smoothly. *Detection:*
  click-to-feedback > 100 ms; double-click required where single should
  suffice; drag-drop drops on wrong target; modal where inspector would
  suffice; sheet that blocks routine flow.
- **Cognitive load spike** — too much information at once. *Detection:*
  visible-element density spikes > 2× surrounding density; mixed type
  sizes within one card; > 3 simultaneously animating regions.
- **Polish drift** — looks like a prototype, not a product. *Detection:*
  spacing not on the 8 pt grid; mixed corner radii within one panel;
  opaque-vs-glass mixing in the same surface; rectangular focus-ring
  fallback in lists; shadow noise on `.glass` / `.glassProminent`
  controls.
- **Reliability smell** — even if nothing fails, something looks unsafe.
  *Detection:* error states appearing transiently before correct states
  settle; flicker between two values; controls enabling and re-disabling
  in rapid succession; values that briefly show `nil`/`—` before
  populating.

## §4.6 right vs wrong signatures (verbatim)

Right:

- App window appears with populated content within ≤ 2 s of process
  spawn.
- Every state transition is animated; transition completes ≤ 200 ms;
  idle UI is pixel-stable ≥ 2 s.
- Controls reflect their state via shape + color + label, not just one
  channel.
- Toolbar/sidebar Liquid Glass intact across navigation, inspector
  toggle, and modal flow.
- New toasts queue, do not overlap.
- Click-to-feedback < 100 ms, hover < 50 ms.
- Recording starts within 5 s of process spawn, ends within 5 s of
  process exit, no idle freezes > 2 s outside known waits.
- Final dashboard summary at end of run shows all expected acts as
  `Done`/`Closed` with daemon-health green.

Wrong:

- Snap (no animation) on transitions; opacity flips without crossfade.
- Spinner without follow-up state change.
- Layout reflow on every keystroke.
- Truncation that hides the primary action.
- Modal sheet blocking what an inspector should host.
- Click handlers that fire twice (badge flickering between two states
  briefly).
- Recording showing the app frozen ≥ 2 s without progress signal.
- Liquid Glass disappearing after inspector toggle and never coming
  back.
- Sidebar opaque flash on app launch before real material settles.
- Focus ring rectangular fallback inside a list (NSTableView leak).
- Same value rendered differently across two surfaces in one frame.

## Loop protocol (step-numbered)

1. **State read.** Read `tmp/e2e-triage/ledger.md`. If absent,
   initialise with the §6 schema. Increment iteration counter.
2. **Run the lane.** `rtk mise run e2e:swarm:full`. Capture exit status
   and the run slug. If the lane crashes before producing the recording,
   file a high-severity ledger row, fix the bootstrap break, and restart
   the iteration.
3. **Recording-first triage.** Walk the .mov chronologically:
   - `rtk mise run e2e:swarm:triage:recording -- tmp/e2e-triage/runs/<slug>`
   - Walk the §4.4 per-launch checklist against extracted keyframes +
     emitted JSON.
   - Promote each candidate finding to the ledger only when supported by
     a recording timestamp range AND at least one secondary artefact
     reference (UI snapshot, hierarchy dump, log line).
   - Mark unsure entries `needs-verification` and re-watch the segment
     before promotion.
4. **Test failure triage.** Use the xcresult exports already produced by
   the existing triage script. Tie each failure to a recording timestamp
   segment.
5. **Logs and persisted-state triage.** Walk daemon, act-driver,
   xcodebuild, and screen-recording logs; walk
   `context/state-root` and `context/sync-root`. Promote anomalies that
   don't already match a ledger row.
6. **Ledger update.** Persist all confirmed findings under §6's schema.
   Never delete past rows.
7. **Fix every Open item** in dependency order, smallest first:
   - Reproduce against the artifacts; cite recording timestamp range.
   - Write a failing test (Rust unit, Swift XCTest, or e2e contract).
     Confirm red.
   - Implement the smallest correct fix. No hacks, no warning
     suppressions, no TODO debt.
   - Re-run the targeted test. Confirm green.
   - Run the right gate per stack: Rust → `rtk mise run check`; Swift →
     `rtk mise run monitor:macos:lint` then
     `XCODE_ONLY_TESTING=… rtk mise run monitor:macos:test`; cross-stack
     → both.
   - `rtk git commit -sS` with a Conventional Commits message; verify
     signature with `rtk git log --show-signature -1`; verify the
     `Signed-off-by: Bart Smykla <bartek@smykla.com>` trailer.
   - Update the ledger row → Closed with iteration closed and commit
     hash.
8. **Loop or terminate.** If any fixes landed or any Open ledger items
   remain, re-run the lane (step 2) and iterate. Terminate only when an
   iteration produces zero new findings AND the ledger has zero Open
   items AND all gates are green on the terminating run. On termination,
   print a summary table grouped by subsystem with iteration counts and
   commit hashes.

## §6 ledger schema

`tmp/e2e-triage/ledger.md` (markdown, append-only):

```markdown
# Swarm e2e iteration ledger

- Iteration: <N>
- Last run slug: <slug>
- Last status: <passed|failed>
- Last terminated at: <UTC timestamp>

| ID | Status | Severity | Subsystem | Iteration found | Iteration closed | Recording timestamps | Current behavior | Desired behavior | Evidence | Fix commit |
|----|--------|----------|-----------|-----------------|------------------|----------------------|------------------|------------------|----------|------------|
| L-0001 | Open | high | review-state | 1 | – | mm:ss-mm:ss (launch 2) | <observed> | <expected> | <paths> | – |
```

Severities: `critical` (blocks the loop or breaks supervisor trust),
`high` (visible UX failure or correctness lie), `medium` (polish/perf
regression noticeable to a careful user), `low` (cosmetic, accessibility
tightening, density nudge).

## Escape hatches

- Lane build fails before producing artifacts → file high-severity row,
  fix bootstrap, restart iteration.
- 1Password unavailable for commit signing → hard stop, ask the user,
  wait. Never substitute another key, never strip `-S`.
- Required runtime missing per `e2e:swarm:probe-runtimes` → hard stop,
  surface to user.
- Manual recording playback required for a finding the agent cannot
  mechanically detect → pause, ask user.
- Conflicting parallel agent owns a touched file → switch scope; if
  blocked > 5 minutes, ask user.
- Loop count exceeds an explicit safety budget the user sets at
  invocation (default: no cap).

## Tooling cheat sheet

| Need | Command |
|------|---------|
| Run the lane | `rtk mise run e2e:swarm:full` |
| Recording triage | `rtk mise run e2e:swarm:triage:recording -- <run-dir>` |
| Recording triage tests | `rtk mise run e2e:swarm:triage:recording:test` |
| Scoped XCTest | `XCODE_ONLY_TESTING=Target/Class/method rtk mise run monitor:macos:test` |
| Swift gate | `rtk mise run monitor:macos:lint` |
| Rust gate | `rtk mise run check` |
| Rust integration suite | `rtk mise run test:integration` |
| Recording playback | `rtk qlmanage -p tmp/e2e-triage/runs/<slug>/swarm-full-flow.mov` |
| ffprobe duration | `rtk ffprobe -v error -show_entries format=duration -of csv=p=0 <recording>` |
| xcresult tests | `rtk xcrun xcresulttool get test-results summary --path <bundle> --compact` |
| Env override | `rtk env VAR=val rtk mise run <task>` |

`rtk proxy` is forbidden inside the loop; redirect to a file when full
output is needed (`> /tmp/foo.log 2>&1`). Lint output never goes through
`grep`/`head`/`tail`.

## Anti-patterns

- Skipping recording triage when tests pass.
- Closing rows from logs alone.
- Batching unrelated fixes into one commit.
- Suppressing lints to land faster.
- Running the full UI suite.
- Bumping version inside iteration.
- Re-running the lane without a fix landed first.
- Using `rtk proxy` to read raw command output.
- Adding a python pipeline where the Swift CLI fits.
- Using `exec` in new shell wrappers.
- Sharing a worktree across parallel implementer subagents.

## Version policy

Version bumps land on `main` only after the loop terminates. Inside the
loop the subagent rejects any diff touching `Cargo.toml`,
`testkit/Cargo.toml`, `Cargo.lock` package entries for `harness` /
`harness-testkit`,
`apps/harness-monitor-macos/Tuist/ProjectDescriptionHelpers/BuildSettings.swift`
(`VERSION_MARKER_*` lines), or
`apps/harness-monitor-macos/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist`.
After termination the subagent reports a recommended semver level
(`patch`, `minor`, `major`); the user runs `rtk mise run version:set --
<ver>` themselves.

## Done bar

A one-iteration dry run on a clean baseline must terminate with **zero
new findings**, the ledger holding **zero Open rows**, and every gate
green. Verification:

```bash
rtk mise run e2e:swarm:triage:recording:test
rtk mise run monitor:macos:tools:test:e2e
rtk mise run test:integration
rtk mise run check
rtk mise run monitor:macos:lint
```

All five must pass before the loop is considered shippable.
