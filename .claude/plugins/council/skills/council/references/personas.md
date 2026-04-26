# Council Persona Registry

Six core personas. Each built from primary public sources of the named thinker. Full deep dossiers (with sourced quotes and URLs) sit alongside this file.

## Core (6) - bias correction lens

| Subagent | Person | Lens | Deep dossier |
|----------|--------|------|--------------|
| `antirez-simplicity-reviewer` | Salvatore Sanfilippo (antirez) - Redis creator | Design sacrifices, code as artifact, comments-pro, fitness-for-purpose, anti-bloat, hack value | [antirez-deep.md](antirez-deep.md) |
| `tef-deletability-reviewer` | Thomas Edward Figg (tef) - programmingisterrible.com | Easy to delete > easy to extend, anti-naive-DRY, protocol over topology, Devil's Dictionary | [tef-deep.md](tef-deep.md) |
| `muratori-perf-reviewer` | Casey Muratori - Handmade Hero, Computer Enhance | Semantic compression, performance from day one, operation-primal, anti-Clean-Code-orthodoxy | [muratori-deep.md](muratori-deep.md) |
| `hebert-resilience-reviewer` | Fred Hebert (ferd) - ferd.ca, Honeycomb SRE | Operability, supervision trees, controlled-burn, complexity-has-to-live-somewhere, sociotechnical resilience | [hebert-deep.md](hebert-deep.md) |
| `meadows-systems-advisor` | Donella Meadows - *Thinking in Systems* | 12 leverage points, stocks/flows/loops, paradigm transcendence, dancing with systems | [meadows-deep.md](meadows-deep.md) |
| `chin-strategy-advisor` | Cedric Chin - commoncog.com | Tacit knowledge, NDM (Klein), close-the-loop, anti-framework-cult, calibration cases | [chin-deep.md](chin-deep.md) |

## What each persona is good at catching

| Symptom | Personas to summon |
|---------|--------------------|
| Over-engineering / premature abstraction | antirez, tef, muratori |
| Wrong abstraction, hard-to-delete code | tef, antirez |
| Performance built into architecture too late | muratori |
| Failure modes ignored, blast radius unclear | hebert |
| Wrong leverage point intervention | meadows |
| Plan that codifies frameworks instead of building skill | chin |
| Operational blindness | hebert, meadows |
| Sociotechnical mismatch (org/system disconnect) | meadows, hebert, chin |
| Lacks evidence / measurement | muratori, chin |
| Solves the symptom not the structure | meadows, hebert |

## What no persona in this council is good at catching

Six personas leave gaps. Out of scope today: type-system reasoning, property-based testing nuance, domain-driven design, functional architecture, formal specification, infrastructure-as-code, behavior-focused test design, performance at scale, AI output quality, CI/CD pipeline design. If your problem lives squarely in one of those, route to direct review rather than `/council`. The extended roster will land when each persona has the same primary-source dossier quality as the core six.
