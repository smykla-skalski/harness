# Recording Analysis

This document describes the recording-first triage loop for `swarm-full-flow`.

## Process and lifecycle:

- Start with the `.mov` recording.
- Review the timeline in order before looking at logs or persisted state.
- One recording segment maps to one app launch.
- Cross-launch dead time is itself a signal.

## First-frame state:

- Confirm the initial render path.
- Verify the first visible state matches the expected bootstrap.
- Treat missing or delayed content as a finding.

## Transitions between acts:

- Watch for state jumps, dropped frames, or incorrect ordering.
- Record the exact timestamp range for any issue.
- Pair the timestamp with at least one secondary artifact.

## Idle behavior:

- Idle screens should settle quickly.
- Long frozen tails after exit are a failure.
- Cross-launch idle gaps need explanation.

## Animation and performance:

- Flag visible jank, redundant transitions, and thrashing.
- Compare expected and actual motion timing.
- Review repeated layout changes as a likely regression.

## Readability and accessibility:

- Check text contrast, density, and legibility.
- Prefer clear state labels over subtle visuals.
- Verify keyboard and focus behavior where relevant.

## Interaction fidelity:

- Actions should map cleanly to visible changes.
- Buttons should not require retries or hidden workarounds.
- Confirm prompts, approvals, and dismissals behave consistently.

## Swarm-specific UI:

- Look for agent status drift.
- Verify recorded findings reflect the current run, not stale state.
- Treat mismatched badges or stale session state as findings.

## Recording artifact:

- Save a frame reference for each promoted issue.
- Keep the timestamp precise enough to revisit the act.
- Do not promote from logs alone.
- Time-to-first-frame target <= 2 s on M-series.
- Toolbar back-and-forth size changes on FocusedValue updates.
- `workerRefusal` toast fires at act11.
- `signalCollision` toast fires at act14.

## Detection recipes

- `ffmpeg -ss <ts> -i swarm-full-flow.mov -frames:v 1 -y <act>.png`
- `ffprobe -show_frames -of compact=p=0 swarm-full-flow.mov`
- sampling 10 fps over 2 s windows
- Same element moving more than 2 pt without user action is drift
- mean luminance < 5 or unique-color count < 10

## Heuristics

- Communication failure:
- Attention thrash:
- Trust erosion:
- Friction:
- Cognitive load spike:
- Polish drift:
- Reliability smell:

## Right / Wrong

Right:
- Validate the timeline first.
- Keep one recording per iteration.
- Promote only confirmed findings.

Wrong:
- Start with logs.
- Batch unrelated frames.
- Close a row without timestamps.
