# CLI references

The `*.md` reference files in this directory are the generated command-line reference for every binary in the workspace that defines its interface with clap. They are **generated** — do not edit them by hand. This README is the only hand-written file here.

- Regenerate: `mise run cli-docs:generate`
- Drift gate (runs inside `mise run test`): `mise run cli-docs:check`

Each reference renders from the owning binary's top-level clap parser (`tools/cli-docs-codegen` compiles the same types the binaries parse), so the document and the runtime `--help` output share one source of truth. A doc comment, subcommand, or flag change ships with its reference by running the regenerate task.

`harness-openrouter-agent` is not covered: it lives in a nested standalone workspace that the root workspace cannot compile, so its `--help` output stays its reference.
