# Council of Experts

Run an engineering council review from Codex. Use generic Codex subagents, not Claude named subagents. Each persona is loaded from a Markdown file under `agents/`, reviews through one sourced lens, and returns material for one integrated synthesis.

## Mode Dispatch

| Mode | Agents | Cost & purpose |
|------|--------|----------------|
| **core** | 6 core personas | Default. Best signal-to-noise for over-engineering, blind spots, premature abstraction, missing failure modes. |
| **all** | 16 personas | Use for substantial designs touching multiple domains such as types, deployment, observability, AI quality, and performance. |
| **debate** | 3-6 selected personas | Use for hard tradeoff calls where disagreement is the point. Run opening positions, responses, then final positions. |

If the user does not name a mode, use `core`. If the request starts with `@<path>`, read that file first and treat its contents as the problem context.

## Roster

Persona files live in [agents/](../../agents/). The canonical registry and symptom map live in [references/personas.md](references/personas.md).

Core:

- `antirez-simplicity-reviewer`
- `tef-deletability-reviewer`
- `muratori-perf-reviewer`
- `hebert-resilience-reviewer`
- `meadows-systems-advisor`
- `chin-strategy-advisor`

Extended:

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

## Codex Workflow

1. Resolve `mode` and problem context. For file-backed requests, read the file before spawning reviewers.
2. Select personas. Use core for default reviews, all for broad designs, and 3-6 focused personas for debate.
3. For each selected persona, call `spawn_agent` with `agent_type: default` and a unique task name. The message must tell the subagent to read `agents/<persona>.md`, read any referenced dossier only if needed, review the supplied context through that persona's lens only, and return the Persona Output Contract below.
4. Use `wait_agent` until every reviewer has returned. If one reviewer fails, continue with the successful reviewers and call out the missing lens in the synthesis.
5. Synthesize the returned reviews. Do not average the personas into bland consensus. The value is convergence across opposed lenses and named disagreement where constraints decide the tradeoff.

For debate mode, run three rounds:

1. Opening positions from each selected persona.
2. Responses where each persona receives the other opening positions and names agreement, disagreement, and evidence that would change the answer.
3. Final positions, then one integrated decision summary.

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
