---
name: harness-cli
description: Use when an agent needs accurate harness CLI command, subcommand, flag, or recovery-flow guidance, especially for setup, create, run, observe, session, daemon, bridge, or hidden lifecycle commands.
argument-hint: '[command family or task]'
allowed-tools: Agent, Bash, Glob, Grep, Read
user-invocable: true
---

# Harness CLI reference

## What this skill is for

Use this skill to answer `harness` CLI questions from checked-in references backed by live command help and Clap source.

## How to answer

1. Read the relevant file in `references/` first.
2. If the reference is missing detail or may be stale, run `harness ... --help` for the exact command path.
3. Cite the exact reference file, help command, and source file you used.
4. Do not invent commands, flags, defaults, or hidden behavior.

## Reference map

- `references/top-level-and-hidden.md` — visible top-level commands, hidden top-level commands, global `--delay`
- `references/setup-create.md` — `setup` and `create` command surfaces, key flags, bootstrap/generate shortcuts
- `references/run.md` — `run`, especially resume / status / doctor / repair recovery work.
- `references/observe-session.md` — `observe`, `session`, and `session start` runtime/flag surfaces.
- `references/agents-daemon-bridge.md` — `agents`, `daemon`, `bridge`, and wrapper lifecycle command shapes.
