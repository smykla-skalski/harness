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

## Detection recipes

Bake these into [recording-triage scripts](../../../../scripts/e2e/recording-triage/) when they are run more than once. Run them ad-hoc when triaging a specific window.

### Per-act keyframes

```
ffmpeg -ss <ts> -i swarm-full-flow.mov -frames:v 1 -y <act>.png
```

Extract frames at `actReady`, `actAck`, and 250 ms before each transition. Compare each frame against `ui-snapshots/<actN>.png`; large visual distance is a render-mismatch finding.

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

Compare the `.mov` first frame against the daemon app-launch line and the last frame against the test `terminate` line. Either side > 5 s is a recording-artifact finding.

## Suite-speed lens

Treat any wait that could have started the next safe action as a finding. Dead head, dead tail, relaunch gaps, delayed assertions, slow handoffs, and redundant waits all count.

## Checklist pass

After the chronological recording review, run [recording-checklist.md](recording-checklist.md). Do not move to secondary artifacts until that pass is complete.
