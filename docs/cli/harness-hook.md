# Command-Line Help for `harness-hook`

This document contains the help content for the `harness-hook` command-line program.

**Command Overview:**

* [`harness-hook`↴](#harness-hook)
* [`harness-hook tool-guard`↴](#harness-hook-tool-guard)
* [`harness-hook tool-result`↴](#harness-hook-tool-result)
* [`harness-hook audit-turn`↴](#harness-hook-audit-turn)
* [`harness-hook session-start`↴](#harness-hook-session-start)
* [`harness-hook session-stop`↴](#harness-hook-session-stop)
* [`harness-hook prompt-submit`↴](#harness-hook-prompt-submit)
* [`harness-hook pre-compact`↴](#harness-hook-pre-compact)

## `harness-hook`

Harness lifecycle hooks

**Usage:** `harness-hook [OPTIONS] <COMMAND>`

###### **Subcommands:**

* `tool-guard` —
* `tool-result` —
* `audit-turn` —
* `session-start` —
* `session-stop` —
* `prompt-submit` —
* `pre-compact` —

###### **Options:**

* `--delay <DELAY>` — Seconds to wait before executing the command

  Default value: `0`



## `harness-hook tool-guard`

**Usage:** `harness-hook tool-guard --agent <AGENT> --skill <SKILL>`

###### **Options:**

* `--agent <AGENT>` — Hook transport/agent protocol

  Possible values: `claude`, `copilot`, `codex`, `gemini`, `vibe`, `opencode`

* `--skill <SKILL>` — Harness skill owning the hook

  Possible values: `suite:run`, `suite:create`, `observe`




## `harness-hook tool-result`

**Usage:** `harness-hook tool-result --agent <AGENT> --skill <SKILL>`

###### **Options:**

* `--agent <AGENT>` — Hook transport/agent protocol

  Possible values: `claude`, `copilot`, `codex`, `gemini`, `vibe`, `opencode`

* `--skill <SKILL>` — Harness skill owning the hook

  Possible values: `suite:run`, `suite:create`, `observe`




## `harness-hook audit-turn`

**Usage:** `harness-hook audit-turn --agent <AGENT> --skill <SKILL>`

###### **Arguments:**


###### **Options:**

* `--agent <AGENT>` — Hook transport/agent protocol

  Possible values: `claude`, `copilot`, `codex`, `gemini`, `vibe`, `opencode`

* `--skill <SKILL>` — Harness skill owning the hook

  Possible values: `suite:run`, `suite:create`, `observe`




## `harness-hook session-start`

**Usage:** `harness-hook session-start [OPTIONS] --agent <AGENT>`

###### **Options:**

* `--agent <AGENT>` — Hook transport/agent protocol

  Possible values: `claude`, `copilot`, `codex`, `gemini`, `vibe`, `opencode`

* `--project-dir <PROJECT_DIR>` — Project directory associated with the runtime session
* `--session-id <SESSION_ID>` — Native runtime session identifier



## `harness-hook session-stop`

**Usage:** `harness-hook session-stop [OPTIONS] --agent <AGENT>`

###### **Options:**

* `--agent <AGENT>` — Hook transport/agent protocol

  Possible values: `claude`, `copilot`, `codex`, `gemini`, `vibe`, `opencode`

* `--project-dir <PROJECT_DIR>` — Project directory associated with the runtime session
* `--session-id <SESSION_ID>` — Native runtime session identifier



## `harness-hook prompt-submit`

**Usage:** `harness-hook prompt-submit [OPTIONS] --agent <AGENT>`

###### **Options:**

* `--agent <AGENT>` — Hook transport/agent protocol

  Possible values: `claude`, `copilot`, `codex`, `gemini`, `vibe`, `opencode`

* `--project-dir <PROJECT_DIR>` — Project directory associated with the runtime session
* `--session-id <SESSION_ID>` — Native runtime session identifier



## `harness-hook pre-compact`

**Usage:** `harness-hook pre-compact [OPTIONS]`

###### **Options:**

* `--project-dir <PROJECT_DIR>` — Project directory to save the compact handoff for



<hr/>

<small><i>
    This document was generated automatically by
    <a href="https://crates.io/crates/clap-markdown"><code>clap-markdown</code></a>.
</i></small>
