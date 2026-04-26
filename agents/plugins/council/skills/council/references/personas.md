# Council Persona Registry

Sixteen personas. Six core (bias-correction default) plus ten extended (domain-specific lenses). Each built from primary public sources of the named thinker. Full deep dossiers (with sourced quotes and URLs) sit alongside this file.

## Core (6) - bias correction lens

| Subagent | Person | Lens | Deep dossier |
|----------|--------|------|--------------|
| `antirez-simplicity-reviewer` | Salvatore Sanfilippo (antirez) - Redis creator | Design sacrifices, code as artifact, comments-pro, fitness-for-purpose, anti-bloat, hack value | [antirez-deep.md](antirez-deep.md) |
| `tef-deletability-reviewer` | Thomas Edward Figg (tef) - programmingisterrible.com | Easy to delete > easy to extend, anti-naive-DRY, protocol over topology, Devil's Dictionary | [tef-deep.md](tef-deep.md) |
| `muratori-perf-reviewer` | Casey Muratori - Handmade Hero, Computer Enhance | Semantic compression, performance from day one, operation-primal, anti-Clean-Code-orthodoxy | [muratori-deep.md](muratori-deep.md) |
| `hebert-resilience-reviewer` | Fred Hebert (ferd) - ferd.ca, Honeycomb SRE | Operability, supervision trees, controlled-burn, complexity-has-to-live-somewhere, sociotechnical resilience | [hebert-deep.md](hebert-deep.md) |
| `meadows-systems-advisor` | Donella Meadows - *Thinking in Systems* | 12 leverage points, stocks/flows/loops, paradigm transcendence, dancing with systems | [meadows-deep.md](meadows-deep.md) |
| `chin-strategy-advisor` | Cedric Chin - commoncog.com | Tacit knowledge, NDM (Klein), close-the-loop, anti-framework-cult, calibration cases | [chin-deep.md](chin-deep.md) |

## Extended (10) - domain-specific lenses

| Subagent | Person | Lens | Deep dossier |
|----------|--------|------|--------------|
| `king-type-reviewer` | Alexis King (lexi-lambda) - Haskell, Hackett | Parse-don't-validate, totality, make illegal states unrepresentable, types as axioms, names are not type safety | [king-deep.md](king-deep.md) |
| `hughes-pbt-advisor` | John Hughes - Chalmers, QuickCheck co-creator, QuviQ | Property-based testing, generators not examples, shrinking is the value, stateful PBT, find the bugs your tests can't reach | [hughes-deep.md](hughes-deep.md) |
| `evans-ddd-reviewer` | Eric Evans - Domain Language Inc, DDD blue book | Ubiquitous language, bounded contexts, strategic before tactical, distill the core domain, context maps before microservices | [evans-deep.md](evans-deep.md) |
| `fp-structure-reviewer` | Mark Seemann (blog.ploeh.dk) with Scott Wlaschin (fsharpforfunandprofit.com) | Impureim sandwich, dependency rejection, railway-oriented programming, code that fits in your head, functional architecture for boring people | [fp-structure-deep.md](fp-structure-deep.md) |
| `wayne-spec-advisor` | Hillel Wayne - hillelwayne.com, *Practical TLA+* | Formal methods, TLA+, model-check the protocol, the spec is the design, safety vs liveness, are we really engineers | [wayne-deep.md](wayne-deep.md) |
| `iac-craft-reviewer` | Kief Morris (*Infrastructure as Code* O'Reilly, ThoughtWorks) with Yevgeniy Brikman (*Terraform Up & Running*) | Immutable infrastructure, drift detection, pipeline IS the change-management process, phoenix not snowflake, infrastructure as software | [iac-craft-deep.md](iac-craft-deep.md) |
| `test-architect` | Gary Bernhardt (Destroy All Software) with Kent Beck and Martin Fowler | Functional core/imperative shell, values not objects, boundaries, tests as design pressure, test pyramid, mocks aren't stubs | [test-architect-deep.md](test-architect-deep.md) |
| `gregg-perf-reviewer` | Brendan Gregg - ex-Netflix/Intel, *Systems Performance*, *BPF Performance Tools* | USE method, methodology over tools, profile in production, off-CPU analysis, BPF observability, workload characterization | [gregg-deep.md](gregg-deep.md) |
| `ai-quality-advisor` | Simon Willison - simonwillison.net, Datasette, llm CLI, Django co-creator | Prompt injection, eval-driven LLM development, lethal trifecta, dual LLM pattern, sandboxed tool use, open weights for resilience | [ai-quality-deep.md](ai-quality-deep.md) |
| `cicd-build-advisor` | Charity Majors - charity.wtf, Honeycomb co-founder | Test in production, observability over monitoring, deploy small deploy often, CI as feedback loop, oncall as cultural force, sociotechnical fixes | [cicd-build-deep.md](cicd-build-deep.md) |

## What each persona is good at catching

| Symptom | Personas to summon |
|---------|--------------------|
| Over-engineering / premature abstraction | antirez, tef, muratori |
| Wrong abstraction, hard-to-delete code | tef, antirez |
| Performance built into architecture too late (single-process hot path) | muratori |
| Performance unmeasured at fleet scale (Linux / JVM / production) | gregg, muratori |
| Failure modes ignored, blast radius unclear | hebert |
| Concurrency invariant unspecified / model-check gap | wayne, hebert |
| Wrong leverage point intervention | meadows |
| Plan that codifies frameworks instead of building skill | chin |
| Operational blindness | hebert, meadows, cicd-build |
| Sociotechnical mismatch (org/system disconnect) | meadows, hebert, chin, cicd-build |
| Lacks evidence / measurement | muratori, chin, gregg |
| Solves the symptom not the structure | meadows, hebert |
| Type lies about its preconditions / shotgun parsing | king, antirez |
| No properties, only example tests / generative coverage gap | hughes, test-architect |
| Domain language slipping / bounded context confusion | evans, meadows |
| Functional core polluted with effects / DI container ceremony | fp-structure, test-architect |
| Snowflake infra / drift unmeasured / IaC missing | iac-craft, hebert |
| Test pyramid inverted / mocks where values should be | test-architect, hughes |
| LLM output trusted without evals / prompt injection / lethal trifecta | ai-quality, hebert |
| CI is gate not feedback / deploy frequency low / oncall punishing | cicd-build, hebert, tef |

## What no persona in this council is good at catching

Sixteen personas leave residual gaps. Out of scope today: relational-database internals (query planning, index design, lock escalation), ML model training and data engineering, frontend UX and accessibility, security threat modeling and red-team work, hardware / electrical-engineering / firmware constraints, embedded real-time scheduling. If your problem lives squarely in one of those, route to direct review rather than `/council`.
