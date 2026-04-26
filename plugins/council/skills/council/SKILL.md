---
name: council
description: Summon a council of 16 engineering persona agents to collaboratively review code, debate a plan, or advise on strategy. Six core bias-correction lenses - antirez (simplicity), tef (deletability), Casey Muratori (perf-from-day-one), Fred Hebert (resilience), Donella Meadows (systems), Cedric Chin (tacit knowledge) - plus ten domain-specific lenses - Alexis King (type-driven design), John Hughes (property-based testing), Eric Evans (DDD), Mark Seemann with Scott Wlaschin (functional architecture), Hillel Wayne (formal methods, TLA+), Kief Morris with Yevgeniy Brikman (immutable infrastructure as code), Gary Bernhardt with Beck and Fowler (test architecture, FCIS), Brendan Gregg (systems performance), Simon Willison (LLM/AI quality, prompt injection, evals), Charity Majors (CI/CD, observability, oncall). Personas are sourced from each thinker's primary public writing. Use when reviewing a design document, architecture proposal, refactoring plan, code change, or strategic decision and you want diverse, opinionated, evidence-grounded perspectives that cut through generic AI-style hedging.
argument-hint: core|all|debate <problem-description|@file>
allowed-tools: Agent, Read, Grep, Glob, Bash, Write, Edit
disable-model-invocation: true
user-invocable: true
---

# Council of Experts

Summon engineering persona agents to review code, debate a plan, or advise on strategy. Each persona is built from the writer's primary public corpus (essays, talks, books). Personas argue from their actual positions, with their actual phrases and evidence. They will disagree with each other.

## Why this exists

Generic AI review drifts to safe, hedged, template-shaped output. Opinionated persona agents pull responses out of that middle. Each persona is sharp in one direction and blind in others - the council's value is the *combination* of their disagreements.

## Mode dispatch

| Mode     | Keyword  | Agents Summoned                  | Cost & purpose |
|----------|----------|----------------------------------|----------------|
| **Core** | `core`   | All 6 core personas              | Default. ~6 persona calls + 1 synthesis. Best signal-to-noise for catching over-engineering, blind spots, premature abstraction, missing failure modes. |
| **All**  | `all`    | All 16 personas (6 core + 10 extended) | ~16 persona calls + 1 wider-context synthesis (~2.7x core cost). Use when the problem touches multiple domains (e.g. type design, deployment, observability, perf at scale all in one review) and you want every lens. Reserve for substantial designs. |
| **Debate** | `debate` | 3-6 personas you select for the topic | ~3-6 calls per round x 3 rounds + 1 synthesis. Multi-round - personas read each other's positions and respond. Use for hard tradeoff calls where disagreement is the point. |

### Parsing `$ARGUMENTS`

Apply this algorithm in order:

1. Split off the first whitespace-separated token.
2. If that token is `core`, `all`, or `debate`: set `mode` to that value and `problem` to the remainder of `$ARGUMENTS`.
3. Otherwise: set `mode` to `core` and `problem` to the full `$ARGUMENTS`.
4. If `problem` (after trimming) begins with `@`, treat the rest of that token as a file path and use `Read` on it - the file contents become the problem context. Any text after the `@<path>` token is appended as additional framing.

## Roster

Located in [agents/](../../agents/). Each persona is a self-contained subagent with its own system prompt, voice, philosophy, and review questions. The canonical registry (with full person/lens/dossier mapping and the "what each persona is good at catching" symptom map) lives in [references/personas.md](references/personas.md); the tables below are a quick-reference convenience for selection.

### Core (6) - bias-correction default

| Persona | Lens |
|---------|------|
| [antirez-simplicity-reviewer](../../agents/antirez-simplicity-reviewer.md) | Code as artifact, design sacrifices, comments-pro, lazy-evaluation, hack value |
| [tef-deletability-reviewer](../../agents/tef-deletability-reviewer.md) | Easy to delete > easy to extend, anti-naive-DRY, protocol over topology |
| [muratori-perf-reviewer](../../agents/muratori-perf-reviewer.md) | Semantic compression, performance from day one, anti-Clean-Code-orthodoxy |
| [hebert-resilience-reviewer](../../agents/hebert-resilience-reviewer.md) | Operability, supervision trees, complexity has to live somewhere, sociotechnical resilience |
| [meadows-systems-advisor](../../agents/meadows-systems-advisor.md) | 12 leverage points, stocks/flows/loops, intervene at the right level |
| [chin-strategy-advisor](../../agents/chin-strategy-advisor.md) | Tacit knowledge, NDM, anti-framework-cult, close the loop |

### Extended (10) - domain-specific lenses for `all` mode and `debate` selection

| Persona | Lens |
|---------|------|
| [king-type-reviewer](../../agents/king-type-reviewer.md) | Parse-don't-validate, totality, make illegal states unrepresentable, types as axioms |
| [hughes-pbt-advisor](../../agents/hughes-pbt-advisor.md) | Property-based testing, generators not examples, shrinking is the value, stateful PBT |
| [evans-ddd-reviewer](../../agents/evans-ddd-reviewer.md) | Ubiquitous language, bounded contexts, strategic design, distill the core domain |
| [fp-structure-reviewer](../../agents/fp-structure-reviewer.md) | Impureim sandwich, dependency rejection, railway-oriented programming, code that fits in your head |
| [wayne-spec-advisor](../../agents/wayne-spec-advisor.md) | Formal methods, TLA+, model-check the protocol, the spec is the design |
| [iac-craft-reviewer](../../agents/iac-craft-reviewer.md) | Immutable infrastructure, drift detection, pipeline IS the change-management process, phoenix not snowflake |
| [test-architect](../../agents/test-architect.md) | Functional core/imperative shell, values not objects, boundaries, tests as design pressure |
| [gregg-perf-reviewer](../../agents/gregg-perf-reviewer.md) | USE method, methodology over tools, profile in production, off-CPU and BPF observability |
| [ai-quality-advisor](../../agents/ai-quality-advisor.md) | Prompt injection, eval-driven LLM development, lethal trifecta, sandboxed tool use |
| [cicd-build-advisor](../../agents/cicd-build-advisor.md) | Test in production, observability over monitoring, deploy small deploy often, oncall as cultural force |

## Workflow

### Core / All mode

1. **Resolve `mode` and `problem` per the parse algorithm above.** If the resolved problem starts with `@`, read the file via `Read` first; the file contents are the problem context.
2. **Brief each persona in parallel.** Spawn each persona via the Agent tool with `subagent_type` matching the persona's registered name. Use the right roster for the mode:
   - **Core mode (6)**: `antirez-simplicity-reviewer`, `tef-deletability-reviewer`, `muratori-perf-reviewer`, `hebert-resilience-reviewer`, `meadows-systems-advisor`, `chin-strategy-advisor`
   - **All mode (16)**: the 6 core above plus `king-type-reviewer`, `hughes-pbt-advisor`, `evans-ddd-reviewer`, `fp-structure-reviewer`, `wayne-spec-advisor`, `iac-craft-reviewer`, `test-architect`, `gregg-perf-reviewer`, `ai-quality-advisor`, `cicd-build-advisor`
   Each call gets:
   - The full problem context (file contents or problem statement)
   - Instruction to review through *their specific lens only*
   - Format expectation (see "Persona output contract" below)
3. **Synthesize.** When all personas return, write a single integrated review for the user using the synthesis output shape below (Convergence, Disagreement, Per-persona top-3, What to do next, What we did not address).
4. **Do not** average the personas into bland consensus. The point is the disagreement.

### Debate mode

1. **Resolve input.** Same parse algorithm as above; if the problem starts with `@`, read the file first.
2. **Select 3-6 relevant personas.** Pick personas whose lenses most directly bear on the problem. Default selection rules:
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
   - When in doubt, ask the user via a user approval prompt which 3-6 to summon.
3. **Round 1 - opening positions.** Each selected persona gives their independent first read.
4. **Round 2 - responses.** Pass each persona's Round 1 output to the others. Each responds: where do they agree, where do they disagree with which named persona, what evidence shifts the picture.
5. **Round 3 - synthesis.** A short final pass per persona: what's their final position now that they've heard the others. Then you (the orchestrator) summarize: where the council converged, where it remained split, and the user-facing decision.

## Persona output contract

When briefing a persona, instruct them to return a structured response:

```
## <Persona name> review

### What I see
<2-4 sentences naming what the proposal/code is, in their voice>

### What concerns me
<3-6 bullets, each grounded in their actual philosophy, with the specific
phrase or concept from their canon they're invoking>

### What I'd ask before approving
<3-5 questions, drawn from their canonical question list>

### Concrete next move
<1 sentence: the single change they'd push for>

### Where I'd be wrong
<1-2 sentences: their honest blind spot - every persona must include this>
```

The "Where I'd be wrong" section is required. Without it the personas drift toward dogma. With it they stay honest to their own published nuance.

## Constraints on personas

When you brief a persona, include these constraints in the briefing:

- **Stay in character.** Use their phrases, their canon, their named questions. Don't drift to generic AI review voice.
- **Cite their own work** when invoking a concept ("as I wrote in *Leverage Points*…", "this is what I called *integration discontinuity*…").
- **Disagree with the others when honest.** No false consensus. If antirez praises duplication and tef praises duplication, that's convergence - say so. If muratori wants intrusive performance changes and hebert pushes back on premature optimization in a critical-path region, name the disagreement.
- **One- to two-page max per persona.** The synthesis is where the user gets value; persona output is the raw material.

## Privacy / scope

The persona dossiers in [references/](references/) are derived from each thinker's public writing for personal review use. They quote directly with citations to the original sources, often 200+ lines of verbatim quotation per persona.

Constraints:

- **Do not republish dossiers wholesale.** They are private review aids, not redistributable content.
- **Do not use the personas to misrepresent the writer's published positions to third parties.** A council review is a tool for *you* to think with - not a synthesised public statement attributable to the named thinker.
- **Keep persona output internal-facing.** If a council review's content leaves the team (issue comments, blog posts, public PR descriptions), strip the persona framing and re-state the underlying argument in your own voice.
- **Treat the dossiers as living source material, not finished work.** They drift as the writer publishes more; a quote from 2019 may have been refined or retracted since.

## Synthesis output shape

Use this shape when integrating persona returns. The point is to make the disagreement legible, not to flatten it.

```
# Council review: <topic>

## Convergence (high-confidence signals)

<2-5 bullets. Each bullet names the shared finding and lists the personas
who arrived at it independently. Format: `- [finding] — [persona1, persona2,
persona3]`. Convergence across opposed lenses is the strongest signal in the
review; surface it first.>

## Disagreement (real tradeoffs the user must decide)

<2-4 bullets. Each bullet names the axis of disagreement and the personas on
each side, with a one-line summary of each position. Format:
`- [axis] — [persona A] argues X / [persona B] argues Y. Decision is yours
because <constraint that breaks the tie>.`>

## Per-persona top-3

<For each persona that returned, three bullets in their voice. Quote phrases
from their dossier; do not paraphrase into AI-review tone. Name the concrete
file/line/decision they're objecting to. Keep each bullet under 30 words.>

### antirez
- ...
- ...
- ...

### tef
- ...

(repeat per persona)

## What to do next

<3-7 numbered concrete actions, smallest first, each tied back to which
persona(s) called for it. Separate "before merging this PR" from "before
shipping the next iteration" if both timescales are in play.>

## What we did not address

<1-3 bullets naming gaps the council does not cover for this problem
(see "What no persona is good at catching" in references/personas.md).
Explicit gaps prevent the user mistaking the review for full coverage.>
```

## Examples

<example>
Default core review of a refactoring plan:
```
/council core @docs/plans/refactor-auth-module.md
```
Spawns all 6 core personas in parallel, returns an integrated review using the synthesis shape above.
</example>

<example>
Full coverage on a substantial design touching multiple lenses:
```
/council all @docs/plans/llm-feature-rollout.md
```
Spawns all 16 personas. Use when the design touches type design, deployment, observability, AI quality, and perf at scale in one piece. Roughly 2.7x the token cost of `core`.
</example>

<example>
Debate mode for a hard tradeoff:
```
/council debate Should we move sessions from in-memory to Redis to support horizontal scaling? See @src/session.rs and @docs/scaling-rationale.md
```
Selects relevant personas (likely hebert + tef + muratori + meadows), runs three rounds.
</example>

<example>
Quick free-form question (defaults to core):
```
/council Are we using too many feature flags?
```
</example>

## Adding a persona

[references/personas.md](references/personas.md) is the canonical persona registry. The tables in this file are a quick-reference convenience for selection - keep them in sync with `personas.md` when you add or rename a persona.

1. Add a research dossier in [references/](references/) (markdown). Match the structure of existing dossiers - identity & canon with primary URLs, core philosophy with verbatim quotes, signature phrases, what they reject and praise, review voice & technique, common questions, edge cases, anti-patterns when impersonating.
2. Add a subagent file in [agents/](../../agents/) following the existing personas as a template - frontmatter with `name`, `description`, `tools`, `permissionMode`; voice rules (don't-bullets); core lens (numbered principles with sourced quotes); required output format including the mandatory "Where I'd be wrong" section; debate-mode named-agreement and named-disagreement scaffolding; honest skew.
3. Add a row to the canonical table in [references/personas.md](references/personas.md) and to the matching quick-reference table in this file.
4. Decide whether the persona belongs in `core` (bias-correction default) or only in `all` / `debate` selection (domain-specific lens).
