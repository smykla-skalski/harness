# Council Review

After every iteration where `_artifacts/active.md` carries at least one data row, invoke the council to deepen the triage before any fix lands. The council catches what the deterministic detectors miss and argues priority across competing findings.

## Why this is in the loop

The recording-triage detectors emit symptom rows: frame gap > 50 ms, layout drift > 3 changes/500 ms, freeze > 2 s, dead head > 5 s. They cannot tell you:

- whether the right fix is to hoist hot work off main or to raise the budget (calibration)
- which of four perf rows deserves this iteration's fix slot (ranking)
- whether the symptom you measured is the cause or downstream of a different finding (root cause)
- what's missing from the active.md set that a different lens would have caught (coverage)

A persona council pushes against each of those gaps. The synthesis is the value; the per-persona drafts are raw material.

## When to invoke

After step 6 of the Loop (active.md header refreshed for this iteration) and before step 8 (start fixing). At that point the findings list is stable and complete - the council reviews a frozen surface, not a moving one.

Skip if `_artifacts/active.md` carries zero data rows. Nothing to review; the iteration's triage already came up clean.

## How to invoke

The council skill is model-invocable. Call it via the Skill tool directly:

```
Skill: council
Arguments: <mode> @_artifacts/active.md
```

`<mode>` is one of `core-eng`, `core-ux`, `core-mix`, or `debate`. Pin the profile rather than passing bare `core`: the iteration owner already knows the Subsystem mix from `active.md`, so the auto-detect inside the council skill is redundant and occasionally misclassifies (e.g. it scores `swarm-act*` rows as UX because of the word "interaction" in the row's evidence). The bare `core` token still works as a fallback when the mix is genuinely unclear; if you use it, the council will announce the profile it picked in its synthesis - cross-check that against the dispatch rules below before acting on the review.

**Do not invoke `all` mode from this loop.** 27 personas + synthesis runs ~150k tokens and ~13 minutes per iteration; that cost compounds across the loop and is not justified at the current iteration cadence. If a finding genuinely spans 4+ lenses across both classes, escalate by either splitting the iteration so each `core-*` profile reviews its own slice, or by running `debate` on the single contested decision the cross-cutting finding hinges on. Reserve `all` for one-off design reviews outside the iteration loop.

The council skill spawns its persona subagents in parallel and returns the integrated synthesis. Save the synthesis (Convergence / Disagreement / Per-persona top-3 / What to do next / What we did not address) - not the per-persona drafts - to `_artifacts/runs/<slug>/council-review.md`.

## Mode dispatch

Resolve mode in two passes: classify `active.md` rows by Subsystem prefix, then pick the profile that matches.

### Subsystem-prefix classes

| Class | Prefixes |
|---|---|
| **Engineering** | `perf-*`, `startup-*`, `lifecycle-*`, `swarm-act*`, `artifact-*`, `suite-*`, `swiftui-*`, `cocoa-*` |
| **UX/platform** | `a11y-*`, `interaction-*`, `motion-*` |

`swiftui-*` and `cocoa-*` ride with engineering because their strongest reviewers (eidhof, ash, king) work the runtime/identity/state-placement axis, not the interaction-design axis. If the row's evidence is genuinely about interaction (e.g. a SwiftUI view whose drag affordance fails), promote it to UX/platform manually.

### Profile selection

| `active.md` data rows | Subsystem mix | Mode | Why |
|---|---|---|---|
| 0 | n/a | skip | nothing to review |
| any | every row in the Engineering class | `core-eng` | 6 engineering bias-correction personas (antirez, tef, muratori, hebert, meadows, chin); ~6 calls + 1 synthesis (~50k tokens, ~2.5 min) |
| any | every row in the UX/platform class | `core-ux` | 6 UX bias-correction personas (norman, nielsen, krug, watson, tognazzini, tufte); same cost as `core-eng` |
| any | rows in both classes, no class is dominant | `core-mix` | 3 engineering + 3 UX (antirez, tef, hebert, norman, nielsen, watson); same cost; forces both lenses in one pass |
| 4+ | rows span 4+ distinct lenses across **both** classes | split into two passes: `core-eng` over the engineering rows, then `core-ux` over the UX rows | two `core` runs cost ~100k tokens and ~5 min combined - still cheaper and more legible than `all` (~150k, ~13 min), and each pass keeps the persona set on-lens |
| any | one contested fix decision (e.g. raise the perf budget vs. hoist hot work) | `debate` | run debate scoped to that one finding; pick 3-6 personas from the persona table below; ~70k tokens, ~6 min |

Distinct lenses are counted by Subsystem prefix. Two `perf-*` rows count as one lens; one `perf-*` row plus one `swarm-act*` row count as two.

Quick examples:

- 3 rows, all `perf-*` -> `core-eng`
- 1 row `a11y-truncation`, 1 row `interaction-hover` -> `core-ux`
- 2 rows `perf-stall`, 1 row `a11y-contrast` -> `core-mix`
- 5 rows spanning `lifecycle-dashboard`, `swarm-actState`, `artifact-tail`, `interaction-drag`, `motion-easing` -> two passes: `core-eng @<engineering subset>` then `core-ux @<UX subset>` (write the subset paths in the council's `Arguments` line, or feed each subset as a temporary file). Do not call `all`.
- single contested row "raise the 50ms perf budget vs. hoist work off main" -> `debate` with muratori + gregg + hebert + meadows

## Persona selection by finding subsystem

For `debate` mode (or to verify `core` mode covers your finding shape):

| Finding subsystem prefix | Strongest personas | What they catch |
|---|---|---|
| `perf-*` (hitch, stall, layoutThrash, toolbar) | muratori, gregg, hebert, ash | semantic compression, USE method profiling, operability cost of fixes, Cocoa-runtime hot paths |
| `startup-*` / `lifecycle.*` (ttff, freeze, dashboard, manifest, persistence) | muratori, gregg, hebert, meadows, simmons, siracusa | cold-start budget, off-CPU profiling, leverage-point framing, Mac-app lifecycle finesse, platform-convention violations |
| `swarm-act*` (state, badge, transition, roster) | king, wayne, evans | type/invariant guarantees, model-checkable protocol, bounded contexts |
| `artifact-*` (head, tail, freezes, blanks, segments, size) | test-architect, iac-craft, antirez, tufte | functional core / boundaries, pipeline-as-process, simplicity reviewer, data-ink and chartjunk on rendered artifacts |
| `a11y-*` (truncation, contrast, tapTarget, fontScaling, density) | watson, nielsen, norman, krug | lived screen-reader experience, severity-rated heuristic violations, affordance/signifier mismatches, muddle-through gaps |
| `interaction-*` (click, hover, drag, shortcut) | tognazzini, norman, krug, head | First Principles of Interaction Design + Fitts's law, mental models, three laws / mindless clicks, motion choreography on transitions |
| `suite-*` (deadHead, deadTail, handoff, repeatedWait, delayedAssert) | muratori, tef, hebert | semantic compression, anti-naive-DRY, suite-as-feedback-system |
| `swiftui-*` (identity, state placement, render thrash, modifier branches) | eidhof, ash, king | SwiftUI declarative discipline, Cocoa runtime cost of bridging, type-driven illegal-state-unrepresentable |
| `cocoa-*` (ARC, GCD, NSRunLoop, blocks, locks/dispatch) | ash, muratori, gregg | runtime mechanics, single-process hot-path cost, off-CPU and lock contention |
| `motion-*` (animation duration, easing, vestibular, prefers-reduced-motion) | head, muratori, simmons | motion has purpose, frame budget, "feels like a real Mac app" timing |

Cross-cutting findings (multiple prefixes in one row's evidence) usually warrant a `debate` scoped to the contested decision, not `all`. Pick 3-6 personas spanning the involved prefixes from this table and run debate; the disagreement is what makes those rows worth the spend.

## Output handling

The council writes its synthesis to `_artifacts/runs/<slug>/council-review.md`. Treat it like the recording-triage checklist: read it before you act on the iteration's findings.

Use the synthesis sections like this:

- **Convergence** - if 3+ personas independently call out a finding's root cause or the same fix direction, that is the highest-confidence signal in the review. Tie-break the "fix smallest open row first" heuristic by convergence-strength when two rows are similarly sized.
- **Disagreement** - genuine tradeoffs the iteration owner must decide. If the council disagrees on whether `L-XXXX` is "raise the budget" or "fix the code", do not run the Fix Protocol on that row this iteration. Either resolve the tradeoff explicitly (write the rationale into `Current behavior` on the active.md row) or flip the row to `needs-verification` until the next recording proves one direction.
- **Per-persona top-3** - skim for any finding the council surfaces that the active.md set is missing. If you spot one, append a `needs-verification` row to active.md with the persona's evidence pointer.
- **What to do next** - cross-reference against active.md row order. The council's first action item should usually be the smallest-open-row this iteration.
- **What we did not address** - if the council says it cannot rule on something (e.g., recording is missing the relevant frames), do not silently move past it. Either rerun the lane with extra capture or call the gap out in the iteration summary.

## Cost vs. value

A 30-minute swarm e2e iteration absorbs one `core-*` profile (~50k tokens, ~2.5 min) without changing the loop shape. `debate` is for one specific contested fix per iteration (~70k tokens, ~6 min). Two-profile splits (`core-eng` + `core-ux` over disjoint subsets) cap at ~100k tokens and ~5 min combined - acceptable but the exception, not the default.

`all` mode is intentionally off the table for this loop right now (~150k tokens, ~13 min, runs the cost up across iterations without proportional signal). If you find yourself wanting `all`, the right move is to either narrow the iteration's scope or run `debate` on the one decision driving the urge.

Skip the council on iterations where `active.md` is empty, where every Open row already has a green Fix Protocol path queued from the prior iteration, or where the recording itself is missing (no input to review).

## Anti-patterns

- Running the council on a moving target. Always wait for `active.md` to be frozen for the iteration (header refreshed + all `found` rows promoted) before invoking.
- Acting on the council review before reading `recording-triage/checklist.md`. The detectors are deterministic; the council is interpretive. Use the detectors for ground truth, the council for interpretation.
- Replacing an `active.md` row with the council's verbatim wording. The council is a review aid, not the authoritative finding record. Persist its synthesis in `council-review.md`; keep `active.md` rows in the canonical schema.
- Treating Convergence as proof. Convergence across opposed lenses is the strongest signal in the review, but it is not deterministic evidence. The detector JSON or the recording timestamp remains the source of truth for the row.
- Re-invoking the council mid-fix to rationalize a change. The council reviews a frozen iteration's findings, once. If the fix uncovers a new finding, append it to active.md and let the next iteration's council pass review it.
