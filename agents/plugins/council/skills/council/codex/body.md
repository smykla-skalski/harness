# Council of Experts

Run an engineering council review from Codex. Use generic Codex subagents, not Claude named subagents. Each persona is loaded from a Markdown file under `agents/`, reviews through one sourced lens, and returns material for one integrated synthesis.

## Path Sanity

If you need to inspect or debug this skill from repo files, keep the skill-name segment in the path:

- Canonical Codex variant: `agents/plugins/council/skills/council/codex/body.md`
- Canonical base skill: `agents/plugins/council/skills/council/body.md`
- Rendered Codex skill: `plugins/council/skills/council/SKILL.md`
- Canonical persona source: `agents/plugins/council/agents/<persona>.md`
- Rendered persona mirror: `plugins/council/agents/<persona>.md`

Do not guess `skills/codex/body.md`. That path is wrong for this repo and for the rendered plugin mirrors; the variant always lives under `skills/council/codex/`.
Do not read `.agents/skills/council/agents/<persona>.md` for persona content. That mirror does not hold the canonical persona Markdown roster for Codex council reviews.

## Mode Dispatch

| Mode | Agents | Cost & purpose |
|------|--------|----------------|
| **core** | 6 personas, profile auto-picked from problem text | Default. Profile resolves to `core-eng`, `core-ux`, or `core-mix` via the auto-detect rules below. Tell the user which profile you picked and why before spawning. |
| **core-eng** (alias `eng`) | 6 engineering bias-correction personas | Pin for code, architecture, refactor, perf, protocol, infra, ops problems. |
| **core-ux** (alias `ux`) | 6 UI/UX bias-correction personas | Pin for interaction design, layout, dashboard, accessibility, usability, visual density. |
| **core-mix** (alias `mix`, `random`) | 3 engineering + 3 UX personas | Pin for features that ship code and UI together. Forces both lenses without paying for `all`. |
| **all** | 27 personas (engineering core + UX core + 10 extended domain + 11 extended UX/platform, deduped) | Use for substantial designs touching multiple domains such as types, deployment, observability, AI quality, performance, UI craft, accessibility, motion, macOS-platform conventions, and dashboard density. Roughly 4.5x core cost. |
| **debate** | 3-6 selected personas | Use for hard tradeoff calls where disagreement is the point. Run opening positions, responses, then final positions. |

If the user does not name a mode, use `core` and resolve the profile via auto-detect. If the request starts with `@<path>`, read that file first and treat its contents as the problem context.

## Auto-detect rules for plain `core`

Score the problem text (file contents + framing) against two cue sets:

- **UX cues:** `ui`, `ux`, `view`, `screen`, `sidebar`, `toolbar`, `button`, `menu`, `window`, `sheet`, `tab`, `dashboard`, `chart`, `layout`, `typography`, `color`, `contrast`, `animation`, `motion`, `transition`, `easing`, `swiftui`, `appkit`, `cocoa`, `accessibility`, `a11y`, `voiceover`, `screen reader`, `wcag`, `aria`, `focus`, `keyboard navigation`, `affordance`, `usability`, `recording`, `figma`, `mockup`, `interaction`, `tooltip`, `hover`, `drag`, `gesture`.
- **Engineering cues:** `refactor`, `architecture`, `module`, `crate`, `package`, `function`, `class`, `struct`, `actor`, `protocol` (in code-design sense), `api`, `endpoint`, `schema`, `migration`, `database`, `sql`, `query`, `cache`, `lock`, `thread`, `concurrency`, `async`, `await`, `goroutine`, `tokio`, `performance` (in CPU/memory/throughput sense), `latency` (system), `throughput`, `pipeline`, `ci`, `cd`, `deploy`, `kubernetes`, `terraform`, `helm`, `oncall`, `incident`, `dependency`, `lint`, `test` (unit/integration), `mock`, `fuzz`, `tla+`.

Apply file path hints first - they are the strongest signal. `*.swift`, `*.css`, `*.html`, `apps/harness-monitor-macos/Sources/...` bias UX; `*.rs`, `*.go`, `Cargo.toml`, `Dockerfile`, `*.tf` bias engineering. Treat each path hint as adding 2 to the matching side's score.

Then resolve in this order - first matching rule wins:

1. Two-surface framing wins. If the problem text names two halves (`both halves`, `backend + UI`, `code and UI`, `crate and SwiftUI`, `API and view`, `frontend and backend`, `server and client`), pick `core-mix`.
2. Both halves have real signal. If UX score >= 2 AND engineering score >= 2 (after path hints), pick `core-mix`.
3. Single side dominates. UX > engineering picks `core-ux`; engineering > UX picks `core-eng`.
4. No signal at all. Both scores 0 picks `core-mix` and the announcement says so explicitly.

Never silently fall back to `core-eng`; that hides the choice from the user.

## Roster

Persona files live in [agents/](../../agents/). The canonical registry and symptom map live in [references/personas.md](references/personas.md).

Core (engineering) (6) - bias-correction default for code/architecture:

- `antirez-simplicity-reviewer`
- `tef-deletability-reviewer`
- `muratori-perf-reviewer`
- `hebert-resilience-reviewer`
- `meadows-systems-advisor`
- `chin-strategy-advisor`

Core (UI/UX) (6) - bias-correction default for interaction/layout/a11y:

- `norman-affordance-reviewer`
- `nielsen-heuristics-reviewer`
- `krug-usability-reviewer`
- `watson-a11y-reviewer`
- `tognazzini-fpid-reviewer`
- `tufte-density-reviewer`

Core (mixed) (6) - 3 engineering + 3 UX, default when the assignment touches both:

- `antirez-simplicity-reviewer`
- `tef-deletability-reviewer`
- `hebert-resilience-reviewer`
- `norman-affordance-reviewer`
- `nielsen-heuristics-reviewer`
- `watson-a11y-reviewer`

Extended Domain (10) - domain-specific lenses:

- `king-type-reviewer`
- `hughes-pbt-advisor`
- `evans-ddd-reviewer`
- `fp-structure-reviewer`
- `wayne-spec-advisor`
- `iac-craft-reviewer`
- `test-architect`
- `gregg-perf-reviewer`
- `ai-quality-advisor`
- `cicd-build-advisor`

Extended UX/Platform (11) - UI craft, accessibility, motion, macOS conventions, dashboard density:

- `eidhof-swiftui-reviewer`
- `ash-cocoa-runtime-reviewer`
- `simmons-mac-craft-reviewer`
- `norman-affordance-reviewer`
- `tognazzini-fpid-reviewer`
- `krug-usability-reviewer`
- `nielsen-heuristics-reviewer`
- `watson-a11y-reviewer`
- `head-motion-reviewer`
- `siracusa-mac-critic`
- `tufte-density-reviewer`

## Codex Workflow

1. Resolve `mode` and problem context. For file-backed requests, read the file before spawning reviewers. If `mode` is bare `core`, run auto-detect and announce the chosen profile (`core-eng`, `core-ux`, or `core-mix`) in one sentence so the user can override on the next call.
2. Select personas from the matching roster: `core-eng` for the engineering 6, `core-ux` for the UX 6, `core-mix` for the 3+3 split, `all` for every persona deduped, and 3-6 focused personas for debate.
3. For each selected persona, call `spawn_agent` with `agent_type: default` and a unique task name. Put the full assignment in the initial `spawn_agent` message; do not send a setup-only spawn and rely on `followup_task` for the real work. The message must be self-contained and tell the subagent to:
   - read `plugins/council/agents/<persona>.md`, or `agents/plugins/council/agents/<persona>.md` if working from canonical sources
   - read any referenced dossier only if needed
   - perform the review immediately
   - not answer with `ready`
   - not wait for more input
   - not modify files
   - not spawn agents
   - review the supplied context through that persona's lens only
   - return only the Persona Output Contract below
4. Use `wait_agent` until every reviewer has returned. If one reviewer fails, continue with the successful reviewers and call out the missing lens in the synthesis.
5. Synthesize the returned reviews. Do not average the personas into bland consensus. The value is convergence across opposed lenses and named disagreement where constraints decide the tradeoff.

For debate mode, run three rounds:

1. Opening positions from each selected persona.
2. Responses where each persona receives the other opening positions and names agreement, disagreement, and evidence that would change the answer.
3. Final positions, then one integrated decision summary.

### Debate selection heuristics

Pick 3-6 personas whose lenses bear on the topic. Defaults:

- Code-style / refactor: antirez + tef + muratori
- Reliability / failure / ops: hebert + meadows + tef
- Strategy / learning / process: chin + meadows + hebert
- Performance / hot path (single-process): muratori + tef + antirez
- Architecture / system design: hebert + meadows + tef + muratori
- Type system / data validation / parsing: king + tef + antirez
- Test design / coverage strategy: test-architect + hughes + chin
- Property-based / generative testing: hughes + king + test-architect
- Domain modeling / bounded contexts: evans + fp-structure + meadows
- Functional architecture / pure-impure boundary: fp-structure + king + test-architect
- Formal spec / concurrency / state machines: wayne + hebert + meadows
- Infrastructure / deployment / IaC: iac-craft + hebert + cicd-build
- Systems performance at scale (fleet / Linux / JVM): gregg + muratori + hebert
- AI / LLM features / prompt design / evals: ai-quality + chin + hebert
- CI/CD / deploy frequency / oncall: cicd-build + hebert + tef
- SwiftUI / view identity / state placement: eidhof + ash + king
- Cocoa runtime / ARC / GCD / NSRunLoop: ash + muratori + gregg
- macOS app craft / lifecycle / "feels like a Mac app": simmons + siracusa + tognazzini
- Interaction design / affordances / discoverability: norman + tognazzini + krug
- Heuristic evaluation / severity scoring: nielsen + krug + norman
- Accessibility / screen-reader / WCAG: watson + norman + nielsen
- Motion / animation / vestibular safety: head + muratori + simmons
- Dashboard density / chartjunk / data-ink: tufte + antirez + tef
- macOS platform conventions / HIG: siracusa + tognazzini + simmons
- Recording-first triage / muddle-through: krug + chin + watson

## Persona Output Contract

Ask each reviewer to return:

```markdown
## <Persona name> review

### What I see
<2-4 sentences naming what the proposal/code is, in their voice>

### What concerns me
<3-6 bullets grounded in that persona's philosophy and the concrete context>

### What I'd ask before approving
<3-5 questions from their canonical question list>

### Concrete next move
<1 sentence: the single change they would push for>

### Where I'd be wrong
<1-2 sentences: their honest blind spot>
```

The "Where I'd be wrong" section is required. Without it the personas drift toward dogma.

## Synthesis Shape

Return one integrated review:

```markdown
# Council review: <topic>

## Convergence (high-confidence signals)

<2-5 bullets. Format: `- [finding] - [persona1, persona2, persona3]`.>

## Disagreement (real tradeoffs the user must decide)

<2-4 bullets. Format: `- [axis] - [persona A] argues X / [persona B] argues Y. Decision is yours because <constraint>.`>

## Per-persona top-3

<For each persona that returned, three concrete bullets in that persona's voice.>

## What to do next

<3-7 numbered concrete actions, smallest first, tied back to personas.>

## What we did not address

<1-3 bullets naming gaps the council does not cover for this problem.>
```

## Privacy / Scope

Persona dossiers in [references/](references/) are private review aids derived from public writing. Do not republish dossiers wholesale. If a council review leaves the team, strip persona framing and restate the arguments in your own voice.
