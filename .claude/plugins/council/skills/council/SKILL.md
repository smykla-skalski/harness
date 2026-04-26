---
name: council
description: Summon a council of engineering persona agents - antirez, tef, Casey Muratori, Fred Hebert, Donella Meadows, Cedric Chin - to collaboratively review code, debate a plan, or advise on strategy. Personas are sourced from each thinker's primary public writing. Use when reviewing a design document, architecture proposal, refactoring plan, code change, or strategic decision and you want diverse, opinionated, evidence-grounded perspectives that cut through generic AI-style hedging.
argument-hint: core|all|debate <problem-description|@file>
allowed-tools: Agent, AskUserQuestion, Read, Grep, Glob, Bash, Write, Edit
disable-model-invocation: true
user-invocable: true
---

# Council of Experts

Summon engineering persona agents to review code, debate a plan, or advise on strategy. Each persona is built from the writer's primary public corpus (essays, talks, books). Personas argue from their actual positions, with their actual phrases and evidence. They will disagree with each other.

## Why this exists

Generic AI review drifts to safe, hedged, template-shaped output. Opinionated persona agents pull responses out of that middle. Each persona is sharp in one direction and blind in others - the council's value is the *combination* of their disagreements.

## Mode dispatch

Parse `$ARGUMENTS`. First word selects the council composition:

| Mode     | Keyword  | Agents Summoned                  | Purpose |
|----------|----------|----------------------------------|---------|
| **Core** | `core`   | All 6 core personas              | Default. Best signal-to-noise for catching over-engineering, blind spots, premature abstraction, missing failure modes. |
| **All**  | `all`    | Reserved for extended roster     | Currently identical to `core`. Reserved for when extended personas (type-system, DDD, formal-spec, PBT, etc.) ship. |
| **Debate** | `debate` | 3-6 personas you select for the topic | Multi-round - personas read each other's positions and respond. Use for hard tradeoff calls where disagreement is the point. |

If the first word is none of `core`, `all`, `debate`, treat the whole `$ARGUMENTS` as a problem description and default to `core` mode.

The remainder of `$ARGUMENTS` is the problem statement. If it begins with `@`, treat as a file path - read it before dispatching to personas.

## Core roster

Located in [agents/](../../agents/). Each persona is a self-contained subagent with its own system prompt, voice, philosophy, and review questions. Read [references/personas.md](references/personas.md) for the registry summary.

| Persona | Lens |
|---------|------|
| [antirez-simplicity-reviewer](../../agents/antirez-simplicity-reviewer.md) | Code as artifact, design sacrifices, comments-pro, lazy-evaluation, hack value |
| [tef-deletability-reviewer](../../agents/tef-deletability-reviewer.md) | Easy to delete > easy to extend, anti-naive-DRY, protocol over topology |
| [muratori-perf-reviewer](../../agents/muratori-perf-reviewer.md) | Semantic compression, performance from day one, anti-Clean-Code-orthodoxy |
| [hebert-resilience-reviewer](../../agents/hebert-resilience-reviewer.md) | Operability, supervision trees, complexity has to live somewhere, sociotechnical resilience |
| [meadows-systems-advisor](../../agents/meadows-systems-advisor.md) | 12 leverage points, stocks/flows/loops, intervene at the right level |
| [chin-strategy-advisor](../../agents/chin-strategy-advisor.md) | Tacit knowledge, NDM, anti-framework-cult, close the loop |

## Workflow

### Core / All mode

1. **Read input.** If `$ARGUMENTS` second segment begins with `@`, read that file. Otherwise treat the remainder as a free-form problem statement.
2. **Brief each persona in parallel.** Spawn each persona via the Agent tool with `subagent_type` matching the persona's registered name (`antirez-simplicity-reviewer`, `tef-deletability-reviewer`, `muratori-perf-reviewer`, `hebert-resilience-reviewer`, `meadows-systems-advisor`, `chin-strategy-advisor`). Each call gets:
   - The full problem context (file contents or problem statement)
   - Instruction to review through *their specific lens only*
   - Format expectation (see "Persona output contract" below)
3. **Synthesize.** When all personas return, write a single integrated review for the user with:
   - **Convergence**: where multiple personas agreed (high-confidence signals)
   - **Disagreement**: where they pulled in opposite directions (real tradeoffs the user must decide)
   - **Per-persona top-3**: each persona's three most pointed objections or recommendations, with their voice intact
   - **What to do next**: the smallest set of concrete actions that respect the strongest critiques
4. **Do not** average the personas into bland consensus. The point is the disagreement.

### Debate mode

1. **Read input.** Same as above.
2. **Select 3-6 relevant personas.** Pick personas whose lenses most directly bear on the problem. Default selection rules:
   - Code-style / refactor: antirez + tef + muratori
   - Reliability / failure / ops: hebert + meadows + tef
   - Strategy / learning / process: chin + meadows + hebert
   - Performance / hot path: muratori + tef + antirez
   - Architecture / system design: hebert + meadows + tef + muratori
   - When in doubt, ask the user via AskUserQuestion which 3-6 to summon.
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

The persona dossiers in [references/](references/) are derived from each thinker's public writing for personal review use. They quote directly with citations to the original sources. Do not republish wholesale. The personas are best used as private review tools, not as public-facing impersonations.

## Examples

<example>
Default core review of a refactoring plan:
```
/council core @docs/plans/refactor-auth-module.md
```
Spawns all 6 personas in parallel, returns an integrated review.
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

1. Add a research dossier in [references/](references/) (markdown).
2. Add a subagent file in [agents/](../../agents/) following the existing six as a template.
3. Add a row to the table in this file and in [references/personas.md](references/personas.md).
4. Decide whether the persona belongs in `core` or only in `all` / `debate` selection.
