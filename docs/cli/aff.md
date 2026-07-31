# Command-Line Help for `aff`

This document contains the help content for the `aff` command-line program.

**Command Overview:**

* [`aff`↴](#aff)
* [`aff setup`↴](#aff-setup)
* [`aff setup bootstrap`↴](#aff-setup-bootstrap)
* [`aff setup agents`↴](#aff-setup-agents)
* [`aff setup agents generate`↴](#aff-setup-agents-generate)

## `aff`

**Usage:** `aff <COMMAND>`

###### **Subcommands:**

* `setup` —



## `aff setup`

**Usage:** `aff setup <COMMAND>`

###### **Subcommands:**

* `bootstrap` —
* `agents` —



## `aff setup bootstrap`

**Usage:** `aff setup bootstrap [OPTIONS]`

###### **Options:**

* `--project-dir <PROJECT_DIR>` — Project directory whose runtime configs should be patched
* `--agents <AGENTS>` — Agents to patch. Defaults to every supported runtime

  Possible values: `claude`, `copilot`, `codex`, `gemini`, `vibe`, `opencode`

* `--skip-runtime-hooks <SKIP_RUNTIME_HOOKS>` — Skip runtime hook configs for the listed agents

  Possible values: `claude`, `copilot`, `codex`, `gemini`, `vibe`, `opencode`

* `--install-pretool-hooks` — Install aff pre-tool hooks (opt-in)
* `--include-gemini-commands` — Accepted for task-surface parity with harness; aff does not emit Gemini commands
* `--enable-suite-hooks` — Accepted for task-surface parity with harness; aff does not gate on suite hooks



## `aff setup agents`

**Usage:** `aff setup agents <COMMAND>`

###### **Subcommands:**

* `generate` —



## `aff setup agents generate`

**Usage:** `aff setup agents generate [OPTIONS]`

###### **Options:**

* `--check` — Fail if aff-owned runtime hook entries differ from the on-disk files
* `--project-dir <PROJECT_DIR>` — Project directory whose runtime configs should be patched
* `--target <TARGET>` — Limit aff runtime patching to a single target

  Default value: `all`

  Possible values: `all`, `claude`, `copilot`, `codex`, `gemini`, `vibe`, `open-code`

* `--skip-runtime-hooks <SKIP_RUNTIME_HOOKS>` — Skip runtime hook configs for the listed agents

  Possible values: `claude`, `copilot`, `codex`, `gemini`, `vibe`, `opencode`

* `--install-pretool-hooks` — Install aff pre-tool hooks (opt-in)
* `--include-gemini-commands` — Accepted for task-surface parity with harness; aff does not emit Gemini commands
* `--enable-suite-hooks` — Accepted for task-surface parity with harness; aff does not gate on suite hooks



<hr/>

<small><i>
    This document was generated automatically by
    <a href="https://crates.io/crates/clap-markdown"><code>clap-markdown</code></a>.
</i></small>
