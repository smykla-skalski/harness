# Recording Analysis

Recording-first doctrine for `swarm-full-flow`. Read the `.mov` first; use artifacts here to confirm findings.

## Investigation order

1. Recording first: startup, shutdown, retries, relaunches, UI state, stalls, layout, interactions.
2. Then screenshots, hierarchy dumps, logs, `xcresult`, persisted state.
3. No recording timestamp, no promotion.

## Ground truth per act

For every act marker the lane already produces three pieces of truth at a known wall clock:

- `act-driver.log` `actReady("actN", ...)` and `actAck("actN")` bracket the act window.
- `ui-snapshots/<actN>.png` shows the rendered app state.
- `ui-snapshots/<actN>.txt` shows the hierarchy and accessibility tree.

If the frame disagrees with those artifacts, file a finding. See [act-marker-matrix.md](act-marker-matrix.md) for the per-act surface.

## Detection thresholds

The wrappers under [scripts/e2e/recording-triage](../../../../scripts/e2e/recording-triage/) bake these in. Read the JSON the wrapper emitted; only fall back to ad-hoc commands when the wrapper output is missing or skipped.

### Per-act keyframes

`auto-keyframes.sh` extracts one frame per `actN.ready` mtime and `compare-keyframes.sh` runs the perceptual-hash compare against `ui-snapshots/swarm-actN.png`. Inspect the JSON pair under `recording-triage/`.

### Frame freezes and stalls

`frame-gaps.sh` writes `recording-triage/frame-gaps.json` with the same thresholds:

- Gap > 50 ms during expected motion is a hitch.
- Gap > 250 ms without a clear cause is a stall.
- Gap > 2 s mid-run outside known waits is a freeze.
- Idle gap > 5 s outside act boundaries with no `act-driver.log` activity is a stall finding.

Three or more hitches in a single segment is a perf finding even when no individual gap crosses 250 ms.

### Dead head and dead tail

`detect-dead-head-tail.sh` compares the `.mov` bounds against the daemon app-launch / terminate lines and writes `recording-triage/dead-head-tail.json`. Either side > 5 s is a recording-artifact finding.

## Suite-speed lens

Treat any wait that could have started the next safe action as a finding. Dead head, dead tail, relaunch gaps, delayed assertions, slow handoffs, and redundant waits all count.

## Checklist pass

After the chronological recording review, run [recording-checklist.md](recording-checklist.md). Do not move to secondary artifacts until that pass is complete.
