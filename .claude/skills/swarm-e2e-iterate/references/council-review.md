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

The council skill is `disable-model-invocation: true`, so the iterate skill cannot reach it through the Skill tool. Spawn an Agent that follows `.claude/plugins/council/skills/council/SKILL.md` directly.

```
Agent (general-purpose, sonnet):
  prompt: |
    Read .claude/plugins/council/skills/council/SKILL.md, then execute the
    workflow it describes for this user input:

      /council <mode> @_artifacts/active.md

    Pick the mode per the heuristic in
    agents/skills/swarm-e2e-iterate/references/council-review.md.

    Save the integrated synthesis (Convergence / Disagreement / Per-persona
    top-3 / What to do next / What we did not address) - not the per-persona
    drafts - to _artifacts/runs/<slug>/council-review.md.
```

Pick `<mode>` from the next section. The Agent may spawn nested persona subagents in parallel; that is by design.

## Mode dispatch

| `active.md` data rows | Suggested mode | Why |
|---|---|---|
| 0 | skip | nothing to review |
| 1-3 | core | 6 personas catch over-engineering, blind spots, missing failure modes; ~6 calls + 1 synthesis (~50k tokens, ~2.5 min) |
| 4+, single lens (all `perf-*`, or all `swarm-act*`) | core | extra personas would be filler; bias-correction is enough |
| 4+, mixed lenses (`perf-*` + `lifecycle.*` + `swarm-act*`, or design + AI quality + UX/a11y) | all | 27 personas (6 core + 10 extended-domain + 11 extended UX/platform) surface lens-specific bugs the core 6 cannot; ~150k tokens, ~13 min - reserve for substantial iterations whose findings span domain + UX + platform lenses |
| any count, single contested fix decision (e.g., raise the perf budget vs. hoist hot work) | debate | run debate scoped to that one finding; pick 3-6 personas from the persona table; ~70k tokens, ~6 min |

Lens spread is decided by the `Subsystem` column in `active.md`. Treat `perf-*`, `startup-*`, `swarm-act*`, `artifact-*`, `a11y-*`, `interaction-*`, `suite-*`, `lifecycle-*`, `swiftui-*`, `cocoa-*`, `motion-*` as distinct lenses.

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

Cross-cutting findings (multiple prefixes in one row's evidence) usually warrant `all` mode.

## Output handling

The council writes its synthesis to `_artifacts/runs/<slug>/council-review.md`. Treat it like the recording-triage checklist: read it before you act on the iteration's findings.

Use the synthesis sections like this:

- **Convergence** - if 3+ personas independently call out a finding's root cause or the same fix direction, that is the highest-confidence signal in the review. Tie-break the "fix smallest open row first" heuristic by convergence-strength when two rows are similarly sized.
- **Disagreement** - genuine tradeoffs the iteration owner must decide. If the council disagrees on whether `L-XXXX` is "raise the budget" or "fix the code", do not run the Fix Protocol on that row this iteration. Either resolve the tradeoff explicitly (write the rationale into `Current behavior` on the active.md row) or flip the row to `needs-verification` until the next recording proves one direction.
- **Per-persona top-3** - skim for any finding the council surfaces that the active.md set is missing. If you spot one, append a `needs-verification` row to active.md with the persona's evidence pointer.
- **What to do next** - cross-reference against active.md row order. The council's first action item should usually be the smallest-open-row this iteration.
- **What we did not address** - if the council says it cannot rule on something (e.g., recording is missing the relevant frames), do not silently move past it. Either rerun the lane with extra capture or call the gap out in the iteration summary.

## Cost vs. value

A 30-minute swarm e2e iteration absorbs the `core` cost without changing the loop shape. `all` mode is wider but pricier; reserve for iterations where the findings genuinely span 4+ lenses. `debate` is for one specific contested fix per iteration.

Skip the council on iterations where `active.md` is empty, where every Open row already has a green Fix Protocol path queued from the prior iteration, or where the recording itself is missing (no input to review).

## Anti-patterns

- Running the council on a moving target. Always wait for `active.md` to be frozen for the iteration (header refreshed + all `found` rows promoted) before invoking.
- Acting on the council review before reading `recording-triage/checklist.md`. The detectors are deterministic; the council is interpretive. Use the detectors for ground truth, the council for interpretation.
- Replacing an `active.md` row with the council's verbatim wording. The council is a review aid, not the authoritative finding record. Persist its synthesis in `council-review.md`; keep `active.md` rows in the canonical schema.
- Treating Convergence as proof. Convergence across opposed lenses is the strongest signal in the review, but it is not deterministic evidence. The detector JSON or the recording timestamp remains the source of truth for the row.
- Re-invoking the council mid-fix to rationalize a change. The council reviews a frozen iteration's findings, once. If the fix uncovers a new finding, append it to active.md and let the next iteration's council pass review it.
