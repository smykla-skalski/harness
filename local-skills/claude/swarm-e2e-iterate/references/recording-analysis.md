# Recording Analysis

Load this before inspecting `swarm-full-flow.mov`, extracting keyframes, or promoting a UI/UX/performance finding. Recording evidence is primary; every promoted row needs a timestamp range and one secondary artifact.

## Contents

- [Detection Recipes](#detection-recipes)
- [Per-Launch Checklist](#per-launch-checklist)
- [UX Heuristics](#ux-heuristics)
- [Right And Wrong Signatures](#right-and-wrong-signatures)

## Detection Recipes

- Extract per-act keyframes with `ffmpeg -ss <ts> -i swarm-full-flow.mov -frames:v 1 -y <act>.png` at act start, act end, and 250 ms before each transition. Derive timestamps from `act-driver.log` `actReady` and acknowledgement anchors. Compare frames with `ui-snapshots/<actN>.png` using histogram or perceptual hash.
- Detect frame freezes with `ffprobe -show_frames -of compact=p=0 swarm-full-flow.mov`; compute inter-frame gaps. Gap > 50 ms during expected motion is a hitch. Gap > 2 s outside known waits is a freeze. Idle gap > 5 s with no log entries is a stall.
- Detect dead head/tail by comparing first frame with daemon app-launch time and last frame with the test termination line. More than 5 s on either side is a recording-artifact finding.
- Detect animation thrash by sampling 10 fps over 2 s windows. If a region changes more than 3 times in any 500 ms window without user input, flag flicker.
- Detect layout drift by comparing accessibility element bounding boxes across consecutive keyframes from `ui-snapshots/<actN>.txt`. Same element moving more than 2 pt without user action is drift.
- Detect black/blank frames with mean luminance < 5 or unique-color count < 10. Allow only during known transitions.

Reproducible implementations live under `scripts/e2e/recording-triage/`. Swift detector logic lives in `apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/RecordingTriage.swift` and is exposed through `harness-monitor-e2e recording-triage <subcommand>`.

## Per-Launch Checklist

Process and lifecycle:
- Time-to-first-frame target <= 2 s on M-series. Anything >= 4 s is a finding.
- Time-to-populated-dashboard target <= 1 s after first frame. Anything >= 2 s is a finding.
- Daemon-manifest pickup latency > 1 s when manifest already exists on disk is a finding.
- Warm start should be measurably faster than cold start when the lane relaunches.
- Termination should be orderly `NSApplication.terminate`; hung windows, beachballs, crash dialogs, or SIGTERM-visible endings are findings.
- With `-ApplePersistenceIgnoreState YES`, prior-session state must not reappear.

First-frame state:
- Loading, empty, and populated states must be visually distinct.
- Disabled/enabled controls must match underlying capability.
- Non-nil sidebar/list selection must have visible highlight.
- Glass/material regressions are visible-design findings.

Transitions between acts:
- Every transition must animate and complete within 200 ms.
- Motion still active 500 ms after trigger is a finding.
- Visible controls must stay hit-testable or visibly disabled.
- Toasts queue; overlapping toasts for more than 1 frame are findings.
- Modal sheets center, present in < 200 ms, dismiss in < 200 ms, and do not flicker.

Idle behavior:
- Outside known live-data fields, idle frames must be pixel-stable for at least 2 s.
- Always-visible chrome must not animate.
- Pixel changes without input or expected live data are findings.
- Visible jank while logs are silent suggests a render loop.

Animation and performance:
- Inter-frame gap > 50 ms during animation is a hitch; three in one segment is a perf finding.
- Inter-frame gap > 250 ms without a clear cause is a stall.
- More than three bounding-box changes within 500 ms after navigation is first-frame layout thrash.
- Toolbar back-and-forth size changes on FocusedValue updates are findings.

Readability and accessibility:
- Truncation hiding a primary affordance is a finding.
- Text contrast below WCAG 4.5:1 for body text or 3:1 for large text is a finding.
- Primary tap targets below 24x24 pt are findings; below 32x32 pt on macOS is a smell.
- Font scaling regressions are findings.
- Visible interactive density spikes greater than 2x surrounding density indicate clutter.

Interaction fidelity:
- Click-to-feedback must be < 100 ms.
- Hover affordances must appear and disappear within 50 ms.
- Drag preview and valid drop feedback must appear within 100 ms.
- Keyboard shortcut feedback must appear within 100 ms.

Swarm-specific UI:
- Runtime/icon must be correct for every role: leader/claude, worker/codex, worker/claude, reviewer/claude, reviewer/codex, duplicate reviewer/claude rejection, observer/claude, improver/codex, and optional gemini/copilot/vibe.
- Review-state badge transitions must show `Open -> AwaitingReview -> InReview -> Done`.
- Arbitration banner appears on round-3 arbitration and dismisses on final approval.
- Heuristic issue cards must exist for each injected code: `python_traceback_output`, `unauthorized_git_commit_during_run`, `python_used_in_bash_tool_use`, `absolute_manifest_path_used`, `jq_error_in_command_output`, `unverified_recursive_remove`, `hook_denied_tool_call`, `agent_repeated_error`, `agent_stalled_progress`, `cross_agent_file_conflict`.
- `workerRefusal` toast fires at act11.
- `signalCollision` toast fires at act14.
- Auto-spawn-reviewer indicator appears after act10 reviewer removal cascade.
- Round-counter pill increments 1 -> 2 -> 3 across the three request-changes rounds in act12.
- Partial-agreement chip appears when worker disputes p2/p3.
- Daemon-health indicator remains green throughout a passing run.

Recording artifact:
- `.mov` starts within 5 s of process spawn and ends within 5 s of process exit.
- No frame freezes > 2 s except known waits.
- No black frames except known transitions.
- Typical file size is > 5 MB and < 2 GB.
- Multi-launch iterations produce multiple segments with no dead time between launches.

## UX Heuristics

- Communication failure: user cannot tell state. Detect visually identical loading/empty/error states, unchanged badges, or missing progress for operations taking > 1 s.
- Attention thrash: UI moves without input. Detect layout shifts, always-visible chrome animations, or idle pixel changes outside live-data regions.
- Trust erosion: UI shows stale, wrong, or contradictory information. Detect badge/content disagreement, green daemon health with empty roster, or count mismatch across surfaces.
- Friction: action cannot be completed smoothly. Detect click-to-feedback > 100 ms, double-click requirements, wrong drag-drop target, modal where inspector fits, or routine-blocking sheet.
- Cognitive load spike: too much information at once. Detect density > 2x surrounding area, mixed type sizes in one card, or more than three simultaneous animated regions.
- Polish drift: prototype feel. Detect spacing off the 8 pt grid, mixed radii in one panel, opaque/glass mixing, rectangular list focus-ring fallback, or noisy shadows on glass controls.
- Reliability smell: unsafe-looking transient behavior. Detect temporary error states before correct state, flicker between values, rapid enable/disable cycles, or brief `nil` placeholders.

## Right And Wrong Signatures

Right:
- App appears populated within <= 2 s of process spawn.
- Transitions animate, finish <= 200 ms, and idle UI is stable for >= 2 s.
- Controls communicate state through shape, color, and label.
- Toolbar/sidebar Liquid Glass remains intact across navigation, inspector toggle, and modal flow.
- Toasts queue without overlap.
- Click feedback < 100 ms; hover feedback < 50 ms.
- Recording starts and ends within 5 s of app lifecycle boundaries with no idle freeze > 2 s outside known waits.
- Final dashboard shows expected acts as `Done` or `Closed`, with daemon health green.

Wrong:
- Transition snaps, opacity flips, spinner without follow-up state change, layout reflow on every keystroke.
- Primary action truncation, routine modal blocking, duplicate click handlers, frozen recording, Liquid Glass disappearing, sidebar opaque flash, rectangular list focus-ring fallback, or same value rendered differently across two surfaces in one frame.
