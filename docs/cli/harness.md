# Command-Line Help for `harness`

This document contains the help content for the `harness` command-line program.

**Command Overview:**

* [`harness`↴](#harness)
* [`harness setup`↴](#harness-setup)
* [`harness setup bootstrap`↴](#harness-setup-bootstrap)
* [`harness setup capabilities`↴](#harness-setup-capabilities)
* [`harness setup secrets`↴](#harness-setup-secrets)
* [`harness setup secrets list`↴](#harness-setup-secrets-list)
* [`harness setup secrets set`↴](#harness-setup-secrets-set)
* [`harness setup secrets clear`↴](#harness-setup-secrets-clear)
* [`harness setup secrets test`↴](#harness-setup-secrets-test)
* [`harness observe`↴](#harness-observe)
* [`harness observe scan`↴](#harness-observe-scan)
* [`harness observe watch`↴](#harness-observe-watch)
* [`harness observe dump`↴](#harness-observe-dump)
* [`harness observe doctor`↴](#harness-observe-doctor)
* [`harness session`↴](#harness-session)
* [`harness session adopt`↴](#harness-session-adopt)
* [`harness session start`↴](#harness-session-start)
* [`harness session join`↴](#harness-session-join)
* [`harness session end`↴](#harness-session-end)
* [`harness session assign`↴](#harness-session-assign)
* [`harness session remove`↴](#harness-session-remove)
* [`harness session transfer-leader`↴](#harness-session-transfer-leader)
* [`harness session recover-leader`↴](#harness-session-recover-leader)
* [`harness session task`↴](#harness-session-task)
* [`harness session task create`↴](#harness-session-task-create)
* [`harness session task assign`↴](#harness-session-task-assign)
* [`harness session task list`↴](#harness-session-task-list)
* [`harness session task update`↴](#harness-session-task-update)
* [`harness session task checkpoint`↴](#harness-session-task-checkpoint)
* [`harness session task submit-for-review`↴](#harness-session-task-submit-for-review)
* [`harness session task claim-review`↴](#harness-session-task-claim-review)
* [`harness session task submit-review`↴](#harness-session-task-submit-review)
* [`harness session task respond-review`↴](#harness-session-task-respond-review)
* [`harness session task arbitrate`↴](#harness-session-task-arbitrate)
* [`harness session improver`↴](#harness-session-improver)
* [`harness session improver apply`↴](#harness-session-improver-apply)
* [`harness session signal`↴](#harness-session-signal)
* [`harness session signal send`↴](#harness-session-signal-send)
* [`harness session signal list`↴](#harness-session-signal-list)
* [`harness session agents`↴](#harness-session-agents)
* [`harness session agents readiness`↴](#harness-session-agents-readiness)
* [`harness session agents start`↴](#harness-session-agents-start)
* [`harness session agents start terminal`↴](#harness-session-agents-start-terminal)
* [`harness session agents start codex`↴](#harness-session-agents-start-codex)
* [`harness session agents start acp`↴](#harness-session-agents-start-acp)
* [`harness session agents attach`↴](#harness-session-agents-attach)
* [`harness session agents list`↴](#harness-session-agents-list)
* [`harness session agents show`↴](#harness-session-agents-show)
* [`harness session agents input`↴](#harness-session-agents-input)
* [`harness session agents resize`↴](#harness-session-agents-resize)
* [`harness session agents stop`↴](#harness-session-agents-stop)
* [`harness session agents steer`↴](#harness-session-agents-steer)
* [`harness session agents interrupt`↴](#harness-session-agents-interrupt)
* [`harness session agents approve`↴](#harness-session-agents-approve)
* [`harness session agents acp`↴](#harness-session-agents-acp)
* [`harness session agents acp inspect`↴](#harness-session-agents-acp-inspect)
* [`harness session agents acp logout`↴](#harness-session-agents-acp-logout)
* [`harness session agents acp sessions`↴](#harness-session-agents-acp-sessions)
* [`harness session agents acp close-session`↴](#harness-session-agents-acp-close-session)
* [`harness session agents acp delete-session`↴](#harness-session-agents-acp-delete-session)
* [`harness session observe`↴](#harness-session-observe)
* [`harness session sync`↴](#harness-session-sync)
* [`harness session leave`↴](#harness-session-leave)
* [`harness session title`↴](#harness-session-title)
* [`harness session status`↴](#harness-session-status)
* [`harness session list`↴](#harness-session-list)
* [`harness task-board`↴](#harness-task-board)
* [`harness task-board create`↴](#harness-task-board-create)
* [`harness task-board list`↴](#harness-task-board-list)
* [`harness task-board get`↴](#harness-task-board-get)
* [`harness task-board update`↴](#harness-task-board-update)
* [`harness task-board delete`↴](#harness-task-board-delete)
* [`harness task-board begin`↴](#harness-task-board-begin)
* [`harness task-board submit`↴](#harness-task-board-submit)
* [`harness task-board approve`↴](#harness-task-board-approve)
* [`harness task-board plan-revoke`↴](#harness-task-board-plan-revoke)
* [`harness task-board sync`↴](#harness-task-board-sync)
* [`harness task-board dispatch`↴](#harness-task-board-dispatch)
* [`harness task-board dispatch-pick`↴](#harness-task-board-dispatch-pick)
* [`harness task-board dispatch-deliver`↴](#harness-task-board-dispatch-deliver)
* [`harness task-board evaluate`↴](#harness-task-board-evaluate)
* [`harness task-board progress`↴](#harness-task-board-progress)
* [`harness task-board progress checkpoint`↴](#harness-task-board-progress-checkpoint)
* [`harness task-board progress submit-for-review`↴](#harness-task-board-progress-submit-for-review)
* [`harness task-board progress complete`↴](#harness-task-board-progress-complete)
* [`harness task-board progress block`↴](#harness-task-board-progress-block)
* [`harness task-board progress show`↴](#harness-task-board-progress-show)
* [`harness task-board audit`↴](#harness-task-board-audit)
* [`harness task-board project`↴](#harness-task-board-project)
* [`harness task-board machine`↴](#harness-task-board-machine)
* [`harness task-board host`↴](#harness-task-board-host)
* [`harness task-board host list`↴](#harness-task-board-host-list)
* [`harness task-board host local`↴](#harness-task-board-host-local)
* [`harness task-board host set-project-types`↴](#harness-task-board-host-set-project-types)
* [`harness task-board host clear-project-types`↴](#harness-task-board-host-clear-project-types)
* [`harness task-board orchestrator`↴](#harness-task-board-orchestrator)
* [`harness task-board orchestrator status`↴](#harness-task-board-orchestrator-status)
* [`harness task-board orchestrator start`↴](#harness-task-board-orchestrator-start)
* [`harness task-board orchestrator stop`↴](#harness-task-board-orchestrator-stop)
* [`harness task-board orchestrator run-once`↴](#harness-task-board-orchestrator-run-once)
* [`harness task-board orchestrator settings`↴](#harness-task-board-orchestrator-settings)
* [`harness task-board orchestrator runtime-config`↴](#harness-task-board-orchestrator-runtime-config)
* [`harness task-board orchestrator github-tokens`↴](#harness-task-board-orchestrator-github-tokens)
* [`harness task-board policy`↴](#harness-task-board-policy)
* [`harness task-board policy dump`↴](#harness-task-board-policy-dump)
* [`harness task-board policy import`↴](#harness-task-board-policy-import)
* [`harness task-board policy grants`↴](#harness-task-board-policy-grants)
* [`harness task-board policy grant-resolve`↴](#harness-task-board-policy-grant-resolve)
* [`harness task-board policy grant-revoke`↴](#harness-task-board-policy-grant-revoke)
* [`harness task-board policy spawn-requires-live-policy`↴](#harness-task-board-policy-spawn-requires-live-policy)
* [`harness task-board policy spawn-kill-switch`↴](#harness-task-board-policy-spawn-kill-switch)
* [`harness task-board triage-escalation`↴](#harness-task-board-triage-escalation)
* [`harness task-board triage-escalation report`↴](#harness-task-board-triage-escalation-report)
* [`harness daemon`↴](#harness-daemon)
* [`harness daemon status`↴](#harness-daemon-status)
* [`harness daemon identity`↴](#harness-daemon-identity)
* [`harness daemon stop`↴](#harness-daemon-stop)
* [`harness daemon restart`↴](#harness-daemon-restart)
* [`harness daemon install-launch-agent`↴](#harness-daemon-install-launch-agent)
* [`harness daemon remove-launch-agent`↴](#harness-daemon-remove-launch-agent)
* [`harness daemon doctor`↴](#harness-daemon-doctor)
* [`harness daemon snapshot`↴](#harness-daemon-snapshot)
* [`harness bridge`↴](#harness-bridge)
* [`harness bridge stop`↴](#harness-bridge-stop)
* [`harness bridge status`↴](#harness-bridge-status)
* [`harness bridge reconfigure`↴](#harness-bridge-reconfigure)
* [`harness bridge install-launch-agent`↴](#harness-bridge-install-launch-agent)
* [`harness bridge remove-launch-agent`↴](#harness-bridge-remove-launch-agent)

## `harness`

Harness CLI

**Usage:** `harness [OPTIONS] <COMMAND>`

###### **Subcommands:**

* `setup` — Setup environment and cluster commands
* `observe` — Observe and classify harness-managed agent session logs
* `session` — Multi-agent session orchestration
* `task-board` — Cross-project task board
* `daemon` — Local daemon for the Harness app
* `bridge` — Supervise host capabilities for sandboxed Codex and terminal agent flows

###### **Options:**

* `--delay <DELAY>` — Seconds to wait before executing the command. Accepts fractional values (e.g. 0.5). Use instead of `sleep N && harness ...`

  Default value: `0`



## `harness setup`

Setup environment and cluster commands

**Usage:** `harness setup <COMMAND>`

###### **Subcommands:**

* `bootstrap` — Arguments for `harness bootstrap`
* `capabilities` — Arguments for `harness setup capabilities`
* `secrets` — Inspect task-board secret state in your macOS Keychain



## `harness setup bootstrap`

Arguments for `harness bootstrap`

**Usage:** `harness setup bootstrap [OPTIONS]`

###### **Options:**

* `--project-dir <PROJECT_DIR>` — Project directory to bootstrap the wrapper for
* `--agents <AGENTS>` — Agents to bootstrap. Defaults to every supported agent

  Possible values: `claude`, `copilot`, `codex`, `gemini`, `vibe`, `opencode`

* `--skip-runtime-hooks <SKIP_RUNTIME_HOOKS>` — Skip runtime hook config files for the listed agents while bootstrapping

  Possible values: `claude`, `copilot`, `codex`, `gemini`, `vibe`, `opencode`




## `harness setup capabilities`

Arguments for `harness setup capabilities`

**Usage:** `harness setup capabilities [OPTIONS]`

###### **Options:**

* `--project-dir <PROJECT_DIR>` — Project directory to evaluate for wrapper and plugin readiness



## `harness setup secrets`

Inspect task-board secret state in your macOS Keychain

**Usage:** `harness setup secrets <COMMAND>`

###### **Subcommands:**

* `list` — Report which task-board credentials are configured in your Keychain
* `set` — Store a task-board secret in your Keychain. Reads the secret from stdin (default), a file with `--file`, or an env var with `--env-var`
* `clear` — Remove a task-board secret from your Keychain
* `test` — Verify a task-board secret without revealing it. Provider credentials are authenticated against their upstream API



## `harness setup secrets list`

Report which task-board credentials are configured in your Keychain

**Usage:** `harness setup secrets list`



## `harness setup secrets set`

Store a task-board secret in your Keychain. Reads the secret from stdin (default), a file with `--file`, or an env var with `--env-var`

**Usage:** `harness setup secrets set [OPTIONS] --kind <KIND>`

###### **Options:**

* `--kind <KIND>` — Which secret to act on

  Possible values:
  - `github`:
    GitHub personal access token
  - `ssh`:
    SSH private key used for git transport authentication
  - `signing-ssh`:
    SSH private key used for commit/tag signing
  - `gpg`:
    GPG private key used for commit/tag signing
  - `open-router`:
    `OpenRouter` API key for the in-daemon `OpenRouter` agent backend

* `--repository <REPOSITORY>` — Repository slug `owner/repo` for a per-repo override. Omit for the global scope
* `--file <FILE>` — Read the secret value from this file path (mutually exclusive with `--env-var`)
* `--env-var <ENV_VAR>` — Read the secret value from this environment variable (mutually exclusive with `--file`)



## `harness setup secrets clear`

Remove a task-board secret from your Keychain

**Usage:** `harness setup secrets clear [OPTIONS] --kind <KIND>`

###### **Options:**

* `--kind <KIND>` — Which secret to act on

  Possible values:
  - `github`:
    GitHub personal access token
  - `ssh`:
    SSH private key used for git transport authentication
  - `signing-ssh`:
    SSH private key used for commit/tag signing
  - `gpg`:
    GPG private key used for commit/tag signing
  - `open-router`:
    `OpenRouter` API key for the in-daemon `OpenRouter` agent backend

* `--repository <REPOSITORY>` — Repository slug `owner/repo` for a per-repo override. Omit for the global scope



## `harness setup secrets test`

Verify a task-board secret without revealing it. Provider credentials are authenticated against their upstream API

**Usage:** `harness setup secrets test [OPTIONS] --kind <KIND>`

###### **Options:**

* `--kind <KIND>` — Which secret to act on

  Possible values:
  - `github`:
    GitHub personal access token
  - `ssh`:
    SSH private key used for git transport authentication
  - `signing-ssh`:
    SSH private key used for commit/tag signing
  - `gpg`:
    GPG private key used for commit/tag signing
  - `open-router`:
    `OpenRouter` API key for the in-daemon `OpenRouter` agent backend

* `--repository <REPOSITORY>` — Repository slug `owner/repo` for a per-repo override. Omit for the global scope



## `harness observe`

Observe and classify harness-managed agent session logs

**Usage:** `harness observe [OPTIONS] <COMMAND>`

###### **Subcommands:**

* `scan` — One-shot scan of a session log, plus observer maintenance actions
* `watch` — Continuously poll for new events
* `dump` — Raw event dump without classification
* `doctor` — Validate observe wiring, session pointers, and compact handoff state

###### **Options:**

* `--agent <AGENT>` — Narrow canonical session resolution to a specific agent runtime

  Possible values: `claude`, `copilot`, `codex`, `gemini`, `vibe`, `opencode`

* `--observe-id <OBSERVE_ID>` — Shared observer state ID under the harness project ledger

  Default value: `project-default`



## `harness observe scan`

One-shot scan of a session log, plus observer maintenance actions

**Usage:** `harness observe scan [OPTIONS] [SESSION_ID]`

###### **Arguments:**

* `<SESSION_ID>` — Session ID to observe

###### **Options:**

* `--action <ACTION>` — Optional maintenance action to run instead of a normal scan

  Possible values: `cycle`, `status`, `resume`, `verify`, `resolve-from`, `compare`, `list-categories`, `list-focus-presets`, `mute`, `unmute`

* `--issue-id <ISSUE_ID>` — Issue ID used by `--action verify`
* `--since-line <SINCE_LINE>` — Start verification from this line instead of the issue's first-seen line
* `--value <VALUE>` — Value used by `--action resolve-from`
* `--range-a <FROM:TO>` — First comparison range for `--action compare`, using `FROM:TO` syntax
* `--range-b <FROM:TO>` — Second comparison range for `--action compare`, using `FROM:TO` syntax
* `--codes <CODES>` — Issue codes used by `--action mute` or `--action unmute`
* `--from-line <FROM_LINE>` — Start scanning from this line number

  Default value: `0`
* `--from <FROM>` — Resolve start position: line number, ISO timestamp, or prose substring
* `--focus <FOCUS>` — Focus preset: harness, skills, or all
* `--project-hint <PROJECT_HINT>` — Narrow session search to this project directory name
* `--json` — Output as JSON lines
* `--summary` — Print summary at end
* `--severity <SEVERITY>` — Filter by minimum severity: low, medium, critical
* `--category <CATEGORY>` — Filter by category (comma-separated)
* `--exclude <EXCLUDE>` — Exclude categories (comma-separated)
* `--fixable` — Only show fixable issues
* `--mute <MUTE>` — Mute specific issue codes (comma-separated)
* `--until-line <UNTIL_LINE>` — Stop scanning at this line number
* `--since-timestamp <SINCE_TIMESTAMP>` — Only include events at or after this ISO timestamp
* `--until-timestamp <UNTIL_TIMESTAMP>` — Only include events at or before this ISO timestamp
* `--format <FORMAT>` — Output format: json (default), markdown, sarif
* `--overrides <OVERRIDES>` — Path to YAML overrides config file
* `--top-causes <TOP_CAUSES>` — Show top N root causes grouped by issue code
* `--output <OUTPUT>` — Write truncated issues to this file instead of stdout (watch mode)
* `--output-details <OUTPUT_DETAILS>` — Write full untruncated issues to this file



## `harness observe watch`

Continuously poll for new events

**Usage:** `harness observe watch [OPTIONS] <SESSION_ID>`

###### **Arguments:**

* `<SESSION_ID>` — Session ID to observe

###### **Options:**

* `--poll-interval <POLL_INTERVAL>` — Seconds between polls

  Default value: `3`
* `--timeout <TIMEOUT>` — Exit after this many seconds of no new events

  Default value: `90`
* `--from-line <FROM_LINE>` — Start scanning from this line number

  Default value: `0`
* `--from <FROM>` — Resolve start position: line number, ISO timestamp, or prose substring
* `--focus <FOCUS>` — Focus preset: harness, skills, or all
* `--project-hint <PROJECT_HINT>` — Narrow session search to this project directory name
* `--json` — Output as JSON lines
* `--summary` — Print summary at end
* `--severity <SEVERITY>` — Filter by minimum severity: low, medium, critical
* `--category <CATEGORY>` — Filter by category (comma-separated)
* `--exclude <EXCLUDE>` — Exclude categories (comma-separated)
* `--fixable` — Only show fixable issues
* `--mute <MUTE>` — Mute specific issue codes (comma-separated)
* `--until-line <UNTIL_LINE>` — Stop scanning at this line number
* `--since-timestamp <SINCE_TIMESTAMP>` — Only include events at or after this ISO timestamp
* `--until-timestamp <UNTIL_TIMESTAMP>` — Only include events at or before this ISO timestamp
* `--format <FORMAT>` — Output format: json (default), markdown, sarif
* `--overrides <OVERRIDES>` — Path to YAML overrides config file
* `--top-causes <TOP_CAUSES>` — Show top N root causes grouped by issue code
* `--output <OUTPUT>` — Write truncated issues to this file instead of stdout (watch mode)
* `--output-details <OUTPUT_DETAILS>` — Write full untruncated issues to this file



## `harness observe dump`

Raw event dump without classification

**Usage:** `harness observe dump [OPTIONS] <SESSION_ID>`

###### **Arguments:**

* `<SESSION_ID>` — Session ID to observe

###### **Options:**

* `--context-line <CONTEXT_LINE>` — Show context around a specific line instead of a generic dump
* `--context-window <CONTEXT_WINDOW>` — Number of lines before and after `--context-line`

  Default value: `10`
* `--from-line <FROM_LINE>` — Start from this line number
* `--to-line <TO_LINE>` — Stop at this line number
* `--filter <FILTER>` — Text filter (case-insensitive substring match)
* `--role <ROLE>` — Role filter (comma-separated: user,assistant)
* `--tool-name <TOOL_NAME>` — Filter by tool name (e.g. Bash, Read, Write)
* `--raw-json` — Output raw JSON instead of formatted text
* `--project-hint <PROJECT_HINT>` — Narrow session search to this project directory name



## `harness observe doctor`

Validate observe wiring, session pointers, and compact handoff state

**Usage:** `harness observe doctor [OPTIONS]`

###### **Options:**

* `--json` — Output machine-readable JSON
* `--project-dir <PROJECT_DIR>` — Project directory to inspect instead of the active environment project



## `harness session`

Multi-agent session orchestration

**Usage:** `harness session <COMMAND>`

###### **Subcommands:**

* `adopt` — Adopt an existing on-disk session directory into this daemon
* `start` — Create a new multi-agent orchestration session
* `join` — Register an agent into an existing session
* `end` — End an active session
* `assign` — Assign or change the role of an agent
* `remove` — Remove an agent from a session
* `transfer-leader` — Transfer leader role to another agent
* `recover-leader` — Recover a leaderless degraded session with a managed leader TUI
* `task` — Task management
* `improver` — Improver actions (apply observer-flagged patches to canonical sources)
* `signal` — Signal management
* `agents` — Unified managed terminal and Codex thread operations
* `observe` — Observe all agents in a session
* `sync` — Run a one-shot agent liveness reconciliation
* `leave` — Voluntarily leave a session
* `title` — Set or update a session title
* `status` — Show current session status
* `list` — List sessions



## `harness session adopt`

Adopt an existing on-disk session directory into this daemon

**Usage:** `harness session adopt [OPTIONS] <PATH>`

###### **Arguments:**

* `<PATH>` — Filesystem path to the on-disk session directory to adopt

###### **Options:**

* `--bookmark-id <BOOKMARK_ID>` — Optional security-scoped bookmark id (used when the daemon runs sandboxed)



## `harness session start`

Create a new multi-agent orchestration session

**Usage:** `harness session start [OPTIONS] --context <CONTEXT>`

###### **Options:**

* `--context <CONTEXT>` — Human-readable context or goal for this session
* `--title <TITLE>` — Short human-readable session name

  Default value: ``
* `--project-dir <PROJECT_DIR>` — Project directory (defaults to cwd)
* `--session-id <SESSION_ID>` — Explicit session ID (auto-generated if omitted)
* `--policy-preset <POLICY_PRESET>` — Session policy preset



## `harness session join`

Register an agent into an existing session

**Usage:** `harness session join [OPTIONS] --role <ROLE> --runtime <RUNTIME> <SESSION_ID>`

###### **Arguments:**

* `<SESSION_ID>` — Session ID to join

###### **Options:**

* `--role <ROLE>` — Role to join as

  Possible values: `leader`, `observer`, `worker`, `reviewer`, `improver`

* `--runtime <RUNTIME>` — Agent runtime

  Possible values: `claude`, `copilot`, `codex`, `gemini`, `vibe`, `opencode`

* `--fallback-role <FALLBACK_ROLE>` — Fallback role to use when joining as leader and a leader already exists

  Possible values: `leader`, `observer`, `worker`, `reviewer`, `improver`

* `--capabilities <CAPABILITIES>` — Comma-separated capability tags
* `--name <NAME>` — Human-readable agent display name
* `--project-dir <PROJECT_DIR>` — Project directory
* `--persona <PERSONA>` — Persona identifier to attach to the agent registration



## `harness session end`

End an active session

**Usage:** `harness session end [OPTIONS] --actor <ACTOR> <SESSION_ID>`

###### **Arguments:**

* `<SESSION_ID>` — Session ID

###### **Options:**

* `--actor <ACTOR>` — Agent ID of the caller
* `--project-dir <PROJECT_DIR>` — Project directory



## `harness session assign`

Assign or change the role of an agent

**Usage:** `harness session assign [OPTIONS] --role <ROLE> --actor <ACTOR> <SESSION_ID> <AGENT_ID>`

###### **Arguments:**

* `<SESSION_ID>` — Session ID
* `<AGENT_ID>` — Agent ID to assign

###### **Options:**

* `--role <ROLE>` — New role

  Possible values: `leader`, `observer`, `worker`, `reviewer`, `improver`

* `--reason <REASON>` — Reason for the role change
* `--actor <ACTOR>` — Agent ID of the caller
* `--project-dir <PROJECT_DIR>` — Project directory



## `harness session remove`

Remove an agent from a session

**Usage:** `harness session remove [OPTIONS] --actor <ACTOR> <SESSION_ID> <AGENT_ID>`

###### **Arguments:**

* `<SESSION_ID>` — Session ID
* `<AGENT_ID>` — Agent ID to remove

###### **Options:**

* `--actor <ACTOR>` — Agent ID of the caller
* `--project-dir <PROJECT_DIR>` — Project directory



## `harness session transfer-leader`

Transfer leader role to another agent

**Usage:** `harness session transfer-leader [OPTIONS] --actor <ACTOR> <SESSION_ID> <NEW_LEADER_ID>`

###### **Arguments:**

* `<SESSION_ID>` — Session ID
* `<NEW_LEADER_ID>` — Agent ID of the new leader

###### **Options:**

* `--reason <REASON>` — Reason for transfer
* `--actor <ACTOR>` — Agent ID of the caller
* `--project-dir <PROJECT_DIR>` — Project directory



## `harness session recover-leader`

Recover a leaderless degraded session with a managed leader TUI

**Usage:** `harness session recover-leader [OPTIONS] --preset <PRESET> --runtime <RUNTIME> <SESSION_ID>`

###### **Arguments:**

* `<SESSION_ID>` — Session ID

###### **Options:**

* `--preset <PRESET>` — Session policy preset used for managed leader recovery
* `--runtime <RUNTIME>` — Agent runtime to launch

  Possible values: `claude`, `copilot`, `codex`, `gemini`, `vibe`, `opencode`

* `--project-dir <PROJECT_DIR>` — Project directory



## `harness session task`

Task management

**Usage:** `harness session task <COMMAND>`

###### **Subcommands:**

* `create` — Create a new work item
* `assign` — Assign a work item to an agent
* `list` — List work items in a session
* `update` — Update a work item's status
* `checkpoint` — Record an append-only task checkpoint
* `submit-for-review` — Return a task to the reviewer queue
* `claim-review` — Claim an awaiting-review task for review
* `submit-review` — Submit a review verdict
* `respond-review` — Respond to review feedback as the worker
* `arbitrate` — Leader arbitration on an exhausted review cycle



## `harness session task create`

Create a new work item

**Usage:** `harness session task create [OPTIONS] --title <TITLE> --actor <ACTOR> <SESSION_ID>`

###### **Arguments:**

* `<SESSION_ID>` — Session ID

###### **Options:**

* `--title <TITLE>` — Task title
* `--context <CONTEXT>` — Task context
* `--severity <SEVERITY>` — Severity level

  Default value: `medium`

  Possible values: `low`, `medium`, `high`, `critical`

* `--suggested-fix <SUGGESTED_FIX>` — Suggested fix, if already known
* `--actor <ACTOR>` — Agent ID of the caller
* `--project-dir <PROJECT_DIR>` — Project directory



## `harness session task assign`

Assign a work item to an agent

**Usage:** `harness session task assign [OPTIONS] --actor <ACTOR> <SESSION_ID> <TASK_ID> <AGENT_ID>`

###### **Arguments:**

* `<SESSION_ID>` — Session ID
* `<TASK_ID>` — Task ID to assign
* `<AGENT_ID>` — Agent ID to assign to

###### **Options:**

* `--actor <ACTOR>` — Agent ID of the caller
* `--project-dir <PROJECT_DIR>` — Project directory



## `harness session task list`

List work items in a session

**Usage:** `harness session task list [OPTIONS] <SESSION_ID>`

###### **Arguments:**

* `<SESSION_ID>` — Session ID

###### **Options:**

* `--status <STATUS>` — Filter by status

  Possible values: `open`, `in_progress`, `awaiting_review`, `in_review`, `done`, `blocked`

* `--json` — Output as JSON
* `--project-dir <PROJECT_DIR>` — Project directory



## `harness session task update`

Update a work item's status

**Usage:** `harness session task update [OPTIONS] --status <STATUS> --actor <ACTOR> <SESSION_ID> <TASK_ID>`

###### **Arguments:**

* `<SESSION_ID>` — Session ID
* `<TASK_ID>` — Task ID to update

###### **Options:**

* `--status <STATUS>` — New status

  Possible values: `open`, `in_progress`, `awaiting_review`, `in_review`, `done`, `blocked`

* `--note <NOTE>` — Optional note
* `--actor <ACTOR>` — Agent ID of the caller
* `--project-dir <PROJECT_DIR>` — Project directory



## `harness session task checkpoint`

Record an append-only task checkpoint

**Usage:** `harness session task checkpoint [OPTIONS] --actor <ACTOR> --summary <SUMMARY> --progress <PROGRESS> <SESSION_ID> <TASK_ID>`

###### **Arguments:**

* `<SESSION_ID>` — Session ID
* `<TASK_ID>` — Task ID

###### **Options:**

* `--actor <ACTOR>` — Agent ID of the caller
* `--summary <SUMMARY>` — Human-readable checkpoint summary
* `--progress <PROGRESS>` — Progress percentage
* `--project-dir <PROJECT_DIR>` — Project directory



## `harness session task submit-for-review`

Return a task to the reviewer queue

**Usage:** `harness session task submit-for-review [OPTIONS] --actor <ACTOR> <SESSION_ID> <TASK_ID>`

###### **Arguments:**

* `<SESSION_ID>` — Session ID
* `<TASK_ID>` — Task ID to return for review

###### **Options:**

* `--actor <ACTOR>` — Agent ID of the caller
* `--summary <SUMMARY>` — Optional short summary of the worker's hand-off
* `--suggested-persona <SUGGESTED_PERSONA>` — Optional persona hint for the reviewer queue
* `--project-dir <PROJECT_DIR>` — Project directory



## `harness session task claim-review`

Claim an awaiting-review task for review

**Usage:** `harness session task claim-review [OPTIONS] --actor <ACTOR> <SESSION_ID> <TASK_ID>`

###### **Arguments:**

* `<SESSION_ID>` — Session ID
* `<TASK_ID>` — Task ID to claim for review

###### **Options:**

* `--actor <ACTOR>` — Agent ID of the reviewer claiming the task
* `--project-dir <PROJECT_DIR>` — Project directory



## `harness session task submit-review`

Submit a review verdict

**Usage:** `harness session task submit-review [OPTIONS] --actor <ACTOR> --verdict <VERDICT> --summary <SUMMARY> <SESSION_ID> <TASK_ID>`

###### **Arguments:**

* `<SESSION_ID>` — Session ID
* `<TASK_ID>` — Task ID under review

###### **Options:**

* `--actor <ACTOR>` — Agent ID of the reviewer
* `--verdict <VERDICT>` — Overall verdict

  Possible values: `approve`, `request_changes`, `reject`

* `--summary <SUMMARY>` — Human-readable summary of the review
* `--points <POINTS>` — JSON array of review points (`ReviewPoint`). Defaults to empty
* `--project-dir <PROJECT_DIR>` — Project directory



## `harness session task respond-review`

Respond to review feedback as the worker

**Usage:** `harness session task respond-review [OPTIONS] --actor <ACTOR> <SESSION_ID> <TASK_ID>`

###### **Arguments:**

* `<SESSION_ID>` — Session ID
* `<TASK_ID>` — Task ID the worker is responding on

###### **Options:**

* `--actor <ACTOR>` — Agent ID of the worker
* `--agreed <AGREED>` — Comma-separated point ids the worker agrees with
* `--disputed <DISPUTED>` — Comma-separated point ids the worker disputes
* `--note <NOTE>` — Optional worker note
* `--project-dir <PROJECT_DIR>` — Project directory



## `harness session task arbitrate`

Leader arbitration on an exhausted review cycle

**Usage:** `harness session task arbitrate [OPTIONS] --actor <ACTOR> --verdict <VERDICT> --summary <SUMMARY> <SESSION_ID> <TASK_ID>`

###### **Arguments:**

* `<SESSION_ID>` — Session ID
* `<TASK_ID>` — Task ID awaiting arbitration

###### **Options:**

* `--actor <ACTOR>` — Agent ID of the leader arbitrating
* `--verdict <VERDICT>` — Final arbitration verdict

  Possible values: `approve`, `request_changes`, `reject`

* `--summary <SUMMARY>` — Human-readable arbitration summary
* `--project-dir <PROJECT_DIR>` — Project directory



## `harness session improver`

Improver actions (apply observer-flagged patches to canonical sources)

**Usage:** `harness session improver <COMMAND>`

###### **Subcommands:**

* `apply` — Apply a patch to a canonical skill/plugin source



## `harness session improver apply`

Apply a patch to a canonical skill/plugin source

**Usage:** `harness session improver apply [OPTIONS] --actor <ACTOR> --issue-id <ISSUE_ID> --target <TARGET> --rel-path <REL_PATH> --new-contents-file <NEW_CONTENTS_FILE> <SESSION_ID>`

###### **Arguments:**

* `<SESSION_ID>` — Session ID

###### **Options:**

* `--actor <ACTOR>` — Agent ID of the improver
* `--issue-id <ISSUE_ID>` — Observer-issue ID the improver is addressing
* `--target <TARGET>` — Target root (`skill`, `plugin`, `local_skill_claude`)

  Possible values: `skill`, `plugin`, `local_skill_claude`

* `--rel-path <REL_PATH>` — Repo-relative path under the target root
* `--new-contents-file <NEW_CONTENTS_FILE>` — Path to a local file whose contents will replace the target file
* `--dry-run` — Compute the diff without writing
* `--project-dir <PROJECT_DIR>` — Project directory hint used only to help locate the session on disk when the daemon is not running. The actual write always targets the session's own project directory, so a bogus `--project-dir` cannot escape the session's repo root



## `harness session signal`

Signal management

**Usage:** `harness session signal <COMMAND>`

###### **Subcommands:**

* `send` — Send a file-backed signal to an agent runtime
* `list` — List known signals for a session



## `harness session signal send`

Send a file-backed signal to an agent runtime

**Usage:** `harness session signal send [OPTIONS] --command <COMMAND> --message <MESSAGE> --actor <ACTOR> <SESSION_ID> <AGENT_ID>`

###### **Arguments:**

* `<SESSION_ID>` — Session ID
* `<AGENT_ID>` — Agent ID receiving the signal

###### **Options:**

* `--command <COMMAND>` — Runtime command name for the signal
* `--message <MESSAGE>` — Human-readable message payload
* `--action-hint <ACTION_HINT>` — Optional action hint for the target agent
* `--actor <ACTOR>` — Agent ID of the caller
* `--project-dir <PROJECT_DIR>` — Project directory



## `harness session signal list`

List known signals for a session

**Usage:** `harness session signal list [OPTIONS] <SESSION_ID>`

###### **Arguments:**

* `<SESSION_ID>` — Session ID

###### **Options:**

* `--agent <AGENT>` — Filter to a single agent
* `--json` — Output as JSON
* `--project-dir <PROJECT_DIR>` — Project directory



## `harness session agents`

Unified managed terminal and Codex thread operations

**Usage:** `harness session agents <COMMAND>`

###### **Subcommands:**

* `readiness` — Check every prerequisite for a headless agent run
* `start` — Start a managed terminal session or Codex thread
* `attach` — Attach to a live managed terminal agent
* `list` — List managed agents for a session
* `show` — Show one managed agent snapshot
* `input` — Send keyboard-like input to a managed terminal agent
* `resize` — Resize a managed terminal agent viewport
* `stop` — Stop a managed terminal agent session
* `steer` — Send additional context to a managed Codex thread
* `interrupt` — Interrupt a managed Codex thread
* `approve` — Resolve a managed Codex approval request
* `acp` — ACP agent lifecycle and observability commands



## `harness session agents readiness`

Check every prerequisite for a headless agent run

**Usage:** `harness session agents readiness [OPTIONS] --runtime <RUNTIME> --model <MODEL>`

###### **Options:**

* `--runtime <RUNTIME>` — Runtime to execute
* `--model <MODEL>` — Model to request from the runtime
* `--lane <LANE>` — Execution lane. Defaults to codex for Codex and acp otherwise

  Possible values: `codex`, `acp`, `agent-tui`




## `harness session agents start`

Start a managed terminal session or Codex thread

**Usage:** `harness session agents start <COMMAND>`

###### **Subcommands:**

* `terminal` — Start an interactive terminal-backed agent session
* `codex` — Start a structured Codex thread
* `acp` — Start an ACP-backed agent session



## `harness session agents start terminal`

Start an interactive terminal-backed agent session

**Usage:** `harness session agents start terminal [OPTIONS] --runtime <RUNTIME> <SESSION_ID>`

###### **Arguments:**

* `<SESSION_ID>` — Session ID

###### **Options:**

* `--runtime <RUNTIME>` — Agent runtime to launch

  Possible values: `claude`, `copilot`, `codex`, `gemini`, `vibe`, `opencode`

* `--role <ROLE>` — Role to register the managed terminal agent as

  Default value: `worker`

  Possible values: `leader`, `observer`, `worker`, `reviewer`, `improver`

* `--fallback-role <FALLBACK_ROLE>` — Fallback role to use when joining as leader and a leader already exists

  Possible values: `leader`, `observer`, `worker`, `reviewer`, `improver`

* `--capability <CAPABILITIES>` — Capability tag. May be repeated or comma-separated
* `--name <NAME>` — Human-readable agent display name
* `--prompt <PROMPT>` — Optional first prompt to submit after launch
* `--project-dir <PROJECT_DIR>` — Project directory. Defaults to the daemon's session project
* `--arg <ARGV>` — Override argv, one argument per --arg
* `--rows <ROWS>` — Initial PTY rows

  Default value: `30`
* `--cols <COLS>` — Initial PTY columns

  Default value: `120`
* `--persona <PERSONA>` — Persona identifier to attach to the agent registration
* `--model <MODEL>` — Model identifier validated against the runtime's catalog. Defaults to the runtime default when omitted
* `--effort <EFFORT>` — Reasoning/thinking effort level. Must be a level supported by the selected model; runtimes whose CLI does not accept the flag ignore it with a warning
* `--allow-custom-model` — Accept `--model` as-is without validating against the runtime's model catalog. Used for provider previews or self-hosted identifiers that Harness does not pre-register



## `harness session agents start codex`

Start a structured Codex thread

**Usage:** `harness session agents start codex [OPTIONS] --prompt <PROMPT> <SESSION_ID>`

###### **Arguments:**

* `<SESSION_ID>` — Session ID

###### **Options:**

* `--prompt <PROMPT>` — Initial prompt to send to Codex
* `--mode <MODE>` — Codex execution mode

  Default value: `report`

  Possible values: `report`, `workspace-write`, `approval`

* `--role <ROLE>` — Role to register the Codex app-server agent as

  Default value: `worker`

  Possible values: `leader`, `observer`, `worker`, `reviewer`, `improver`

* `--fallback-role <FALLBACK_ROLE>` — Fallback role to use when joining as leader and a leader already exists

  Possible values: `leader`, `observer`, `worker`, `reviewer`, `improver`

* `--capability <CAPABILITIES>` — Capability tag. May be repeated or comma-separated
* `--name <NAME>` — Human-readable agent display name
* `--persona <PERSONA>` — Persona identifier to attach to the agent registration
* `--resume-thread-id <RESUME_THREAD_ID>` — Resume an existing Codex thread instead of starting a new one
* `--model <MODEL>` — Model identifier validated against the codex catalog. Defaults to the codex runtime default when omitted
* `--effort <EFFORT>` — Reasoning effort level forwarded to the codex app-server. Must match a value supported by the selected model; ignored when the model does not support reasoning
* `--allow-custom-model` — Accept `--model` as-is without validating against the codex catalog



## `harness session agents start acp`

Start an ACP-backed agent session

**Usage:** `harness session agents start acp [OPTIONS] --session-id <SESSION_ID> --agent <AGENT>`

###### **Options:**

* `--session-id <SESSION_ID>` — Session ID
* `--agent <AGENT>` — ACP descriptor ID to launch
* `--role <ROLE>` — Role to register the ACP agent as

  Default value: `worker`

  Possible values: `leader`, `observer`, `worker`, `reviewer`, `improver`

* `--fallback-role <FALLBACK_ROLE>` — Fallback role to use when joining as leader and a leader already exists

  Possible values: `leader`, `observer`, `worker`, `reviewer`, `improver`

* `--capability <CAPABILITIES>` — Capability tag. May be repeated or comma-separated
* `--name <NAME>` — Human-readable agent display name
* `--prompt <PROMPT>` — Optional first prompt to submit after launch
* `--project-dir <PROJECT_DIR>` — Project directory. Defaults to the daemon's session project
* `--persona <PERSONA>` — Persona identifier to attach to the agent registration
* `--model <MODEL>` — Model identifier to launch when the ACP runtime supports overrides
* `--effort <EFFORT>` — Reasoning effort level when the ACP runtime supports overrides
* `--allow-custom-model` — Allow model identifiers outside the advertised catalog
* `--record-permissions` — Record ACP permission decisions without granting permission requests
* `--additional-directory <ADDITIONAL_DIRECTORIES>` — Extra root the agent may work in, beyond the project directory. May be repeated. Ignored by agents that do not advertise `additionalDirectories`
* `--resume-session <RESUME_SESSION_ID>` — Pick up this agent session instead of opening a new one, by resume or load depending on what the agent supports. Overrides the session the daemon would have picked up on its own
* `--no-resume` — Always open a new session, even when a previous one could be resumed or loaded
* `--endpoint <ENDPOINT>` — Connect to a remote ACP endpoint instead of spawning the descriptor's command. `ws`/`wss` uses WebSocket, `http`/`https` uses SSE with POST. The descriptor still names the agent; its launch command is not run
* `--header-env <HEADER_ENV>` — Header for the remote connection as `Name=ENV_VAR`. The daemon reads the value from that environment variable at connect time, so the secret never rides the request. Only http/https endpoints accept headers; ws/wss cannot carry them. Repeatable; requires `--endpoint`



## `harness session agents attach`

Attach to a live managed terminal agent

**Usage:** `harness session agents attach <AGENT_ID>`

###### **Arguments:**

* `<AGENT_ID>` — Managed terminal agent ID



## `harness session agents list`

List managed agents for a session

**Usage:** `harness session agents list <SESSION_ID>`

###### **Arguments:**

* `<SESSION_ID>` — Session ID



## `harness session agents show`

Show one managed agent snapshot

**Usage:** `harness session agents show <AGENT_ID>`

###### **Arguments:**

* `<AGENT_ID>` — Managed agent ID



## `harness session agents input`

Send keyboard-like input to a managed terminal agent

**Usage:** `harness session agents input [OPTIONS] <AGENT_ID>`

###### **Arguments:**

* `<AGENT_ID>` — Managed terminal agent ID

###### **Options:**

* `--text <TEXT>` — Send plain text bytes
* `--paste <PASTE>` — Send bracketed paste text
* `--key <KEY>` — Send a named key

  Possible values: `enter`, `escape`, `tab`, `backspace`, `arrow-up`, `arrow-down`, `arrow-right`, `arrow-left`

* `--control <CONTROL>` — Send a Ctrl+key combination
* `--raw-base64 <RAW_BASE64>` — Send raw bytes encoded as base64



## `harness session agents resize`

Resize a managed terminal agent viewport

**Usage:** `harness session agents resize --rows <ROWS> --cols <COLS> <AGENT_ID>`

###### **Arguments:**

* `<AGENT_ID>` — Managed terminal agent ID

###### **Options:**

* `--rows <ROWS>` — New PTY rows
* `--cols <COLS>` — New PTY columns



## `harness session agents stop`

Stop a managed terminal agent session

**Usage:** `harness session agents stop <AGENT_ID>`

###### **Arguments:**

* `<AGENT_ID>` — Managed terminal agent ID



## `harness session agents steer`

Send additional context to a managed Codex thread

**Usage:** `harness session agents steer --prompt <PROMPT> <AGENT_ID>`

###### **Arguments:**

* `<AGENT_ID>` — Managed Codex agent ID

###### **Options:**

* `--prompt <PROMPT>` — Additional prompt or context to send to Codex



## `harness session agents interrupt`

Interrupt a managed Codex thread

**Usage:** `harness session agents interrupt <AGENT_ID>`

###### **Arguments:**

* `<AGENT_ID>` — Managed Codex agent ID



## `harness session agents approve`

Resolve a managed Codex approval request

**Usage:** `harness session agents approve --decision <DECISION> <AGENT_ID> <APPROVAL_ID>`

###### **Arguments:**

* `<AGENT_ID>` — Managed Codex agent ID
* `<APPROVAL_ID>` — Approval request ID

###### **Options:**

* `--decision <DECISION>` — Resolution to apply

  Possible values: `accept`, `accept-for-session`, `decline`, `cancel`




## `harness session agents acp`

ACP agent lifecycle and observability commands

**Usage:** `harness session agents acp <COMMAND>`

###### **Subcommands:**

* `inspect` — Inspect live ACP sessions
* `logout` — Ask an ACP agent to log out (requires the auth.logout capability)
* `sessions` — List the sessions an ACP agent itself knows about
* `close-session` — Ask an ACP agent to close one of its sessions
* `delete-session` — Ask an ACP agent to delete one of its sessions



## `harness session agents acp inspect`

Inspect live ACP sessions

**Usage:** `harness session agents acp inspect [OPTIONS]`

###### **Options:**

* `--session-id <SESSION_ID>` — Optional session ID filter. Omit to inspect every live ACP session
* `--json` — Emit the raw daemon snapshot as JSON instead of the doctor view



## `harness session agents acp logout`

Ask an ACP agent to log out (requires the auth.logout capability)

**Usage:** `harness session agents acp logout <ACP_ID>`

###### **Arguments:**

* `<ACP_ID>` — Managed ACP agent ID



## `harness session agents acp sessions`

List the sessions an ACP agent itself knows about

**Usage:** `harness session agents acp sessions [OPTIONS] <ACP_ID>`

###### **Arguments:**

* `<ACP_ID>` — Managed ACP agent ID

###### **Options:**

* `--cwd <CWD>` — Only list sessions the agent associates with this working directory
* `--cursor <CURSOR>` — Opaque pagination cursor from a previous listing



## `harness session agents acp close-session`

Ask an ACP agent to close one of its sessions

**Usage:** `harness session agents acp close-session <ACP_ID> <AGENT_SESSION_ID>`

###### **Arguments:**

* `<ACP_ID>` — Managed ACP agent ID
* `<AGENT_SESSION_ID>` — Agent-owned session ID, as reported by `sessions`



## `harness session agents acp delete-session`

Ask an ACP agent to delete one of its sessions

**Usage:** `harness session agents acp delete-session <ACP_ID> <AGENT_SESSION_ID>`

###### **Arguments:**

* `<ACP_ID>` — Managed ACP agent ID
* `<AGENT_SESSION_ID>` — Agent-owned session ID, as reported by `sessions`



## `harness session observe`

Observe all agents in a session

**Usage:** `harness session observe [OPTIONS] <SESSION_ID>`

###### **Arguments:**

* `<SESSION_ID>` — Session ID

###### **Options:**

* `--poll-interval <POLL_INTERVAL>` — Poll interval in seconds for watch mode (0 = one-shot scan)

  Default value: `0`
* `--json` — Output as JSON
* `--actor <ACTOR>` — Actor ID used for task creation; omit to keep observe read-only
* `--project-dir <PROJECT_DIR>` — Project directory



## `harness session sync`

Run a one-shot agent liveness reconciliation

**Usage:** `harness session sync [OPTIONS] <SESSION_ID>`

###### **Arguments:**

* `<SESSION_ID>` — Session ID

###### **Options:**

* `--json` — Output as JSON
* `--project-dir <PROJECT_DIR>` — Project directory



## `harness session leave`

Voluntarily leave a session

**Usage:** `harness session leave [OPTIONS] <SESSION_ID> <AGENT_ID>`

###### **Arguments:**

* `<SESSION_ID>` — Session ID
* `<AGENT_ID>` — Agent ID of the agent leaving

###### **Options:**

* `--project-dir <PROJECT_DIR>` — Project directory



## `harness session title`

Set or update a session title

**Usage:** `harness session title [OPTIONS] --title <TITLE> <SESSION_ID>`

###### **Arguments:**

* `<SESSION_ID>` — Session ID

###### **Options:**

* `--title <TITLE>` — New session title
* `--project-dir <PROJECT_DIR>` — Project directory



## `harness session status`

Show current session status

**Usage:** `harness session status [OPTIONS] <SESSION_ID>`

###### **Arguments:**

* `<SESSION_ID>` — Session ID

###### **Options:**

* `--json` — Output as JSON
* `--project-dir <PROJECT_DIR>` — Project directory



## `harness session list`

List sessions

**Usage:** `harness session list [OPTIONS]`

###### **Options:**

* `--all` — Include archived sessions
* `--json` — Output as JSON
* `--project-dir <PROJECT_DIR>` — Project directory



## `harness task-board`

Cross-project task board

**Usage:** `harness task-board <COMMAND>`

###### **Subcommands:**

* `create` — Create a board task
* `list` — List board tasks
* `get` — Show one board task
* `update` — Update one board task
* `delete` — Tombstone one board task
* `begin` — Move an item into planning and clear any approval
* `submit` — Submit a plan summary for review
* `approve` — Approve a submitted plan and move it to ready work
* `plan-revoke` — Revoke a previously granted approval; the plan summary stays intact
* `sync` — Run external synchronization
* `dispatch` — Dispatch ready work into sessions
* `dispatch-pick` — Preview the highest-priority ready task-board dispatch
* `dispatch-deliver` — Deliver one held task-board dispatch
* `evaluate` — Evaluate linked session work and update board workflow state
* `progress` — Report and read worker progress on a dispatched item
* `audit` — Print task-board audit data
* `project` — Manage known projects
* `machine` — Manage known worker machines
* `host` — Manage the local host record and its declared project types
* `orchestrator` — Manage autonomous task-board orchestration
* `policy` — Manage task-board spawn policy and approval grants
* `triage-escalation` — Triage escalation commands. The daemon's own spawned escalation worker is the only real caller



## `harness task-board create`

Create a board task

**Usage:** `harness task-board create [OPTIONS] --title <TITLE>`

###### **Options:**

* `--title <TITLE>`
* `--body <BODY>`

  Default value: ``
* `--status <STATUS>`

  Possible values: `inbox`, `todo`, `planning`, `in_progress`, `agentic_review`, `testing`, `in_review`, `to_review`, `human_required`, `failed`, `done`, `new`, `plan_review`, `needs_you`, `blocked`

* `--priority <PRIORITY>`

  Default value: `medium`

  Possible values: `low`, `medium`, `high`, `critical`

* `--agent-mode <AGENT_MODE>`

  Default value: `headless`

  Possible values: `headless`, `interactive`, `planning`, `evaluate`

* `--kind <KIND>`

  Default value: `task`

  Possible values: `task`, `umbrella`

* `--tag <TAG>`
* `--project-id <PROJECT_ID>`
* `--target-project-type <TARGET_PROJECT_TYPE>`
* `--external-ref <EXTERNAL_REF>`
* `--planning-summary <PLANNING_SUMMARY>`
* `--approved-by <APPROVED_BY>`
* `--approved-at <APPROVED_AT>`
* `--workflow-execution-id <WORKFLOW_EXECUTION_ID>`
* `--workflow-status <WORKFLOW_STATUS>`

  Possible values:
  - `idle`
  - `admitting`:
    A dispatch has been reserved for this ticket and one execution now owns it, but the worker has not started yet. The ticket stays in Todo through this window; the state records which execution admitted it so a repeated admission is visibly a no-op rather than a second competing run
  - `running`
  - `paused`
  - `completed`
  - `failed`
  - `cancelled`

* `--workflow-current-step-id <WORKFLOW_CURRENT_STEP_ID>`
* `--workflow-attempts <WORKFLOW_ATTEMPTS>`
* `--workflow-branch <WORKFLOW_BRANCH>`
* `--workflow-worktree <WORKFLOW_WORKTREE>`
* `--workflow-pr-number <WORKFLOW_PR_NUMBER>`
* `--workflow-pr-url <WORKFLOW_PR_URL>`
* `--workflow-last-error <WORKFLOW_LAST_ERROR>`
* `--workflow-policy-trace-id <WORKFLOW_POLICY_TRACE_ID>`
* `--session-id <SESSION_ID>`
* `--work-item-id <WORK_ITEM_ID>`
* `--estimated-tokens <ESTIMATED_TOKENS>`
* `--estimated-cost-microusd <ESTIMATED_COST_MICROUSD>`
* `--id <ID>`



## `harness task-board list`

List board tasks

**Usage:** `harness task-board list [OPTIONS]`

###### **Options:**

* `--status <STATUS>`

  Possible values: `inbox`, `todo`, `planning`, `in_progress`, `agentic_review`, `testing`, `in_review`, `to_review`, `human_required`, `failed`, `done`, `new`, `plan_review`, `needs_you`, `blocked`

* `--priority <PRIORITY>`

  Possible values: `low`, `medium`, `high`, `critical`

* `--agent-mode <AGENT_MODE>`

  Possible values: `headless`, `interactive`, `planning`, `evaluate`

* `--project-id <PROJECT_ID>`
* `--tag <TAG>` — Repeatable; an item must carry every requested tag
* `--query <QUERY>` — Case-insensitive substring over title, body, and tags
* `--limit <LIMIT>` — Read one page of at most this many items instead of every page
* `--cursor <CURSOR>` — Read the page following a previous page's `next_cursor`
* `--json`



## `harness task-board get`

Show one board task

**Usage:** `harness task-board get [OPTIONS] <ID>`

###### **Arguments:**

* `<ID>`

###### **Options:**

* `--json`



## `harness task-board update`

Update one board task

**Usage:** `harness task-board update [OPTIONS] <ID>`

###### **Arguments:**

* `<ID>`

###### **Options:**

* `--title <TITLE>`
* `--body <BODY>`
* `--status <STATUS>`

  Possible values: `inbox`, `todo`, `planning`, `in_progress`, `agentic_review`, `testing`, `in_review`, `to_review`, `human_required`, `failed`, `done`, `new`, `plan_review`, `needs_you`, `blocked`

* `--priority <PRIORITY>`

  Possible values: `low`, `medium`, `high`, `critical`

* `--agent-mode <AGENT_MODE>`

  Possible values: `headless`, `interactive`, `planning`, `evaluate`

* `--kind <KIND>`

  Possible values: `task`, `umbrella`

* `--tag <TAG>`
* `--project-id <PROJECT_ID>`
* `--target-project-type <TARGET_PROJECT_TYPE>`
* `--parent-id <PARENT_ID>`
* `--external-ref <EXTERNAL_REF>`
* `--planning-summary <PLANNING_SUMMARY>`
* `--approved-by <APPROVED_BY>`
* `--approved-at <APPROVED_AT>`
* `--workflow-execution-id <WORKFLOW_EXECUTION_ID>`
* `--workflow-status <WORKFLOW_STATUS>`

  Possible values:
  - `idle`
  - `admitting`:
    A dispatch has been reserved for this ticket and one execution now owns it, but the worker has not started yet. The ticket stays in Todo through this window; the state records which execution admitted it so a repeated admission is visibly a no-op rather than a second competing run
  - `running`
  - `paused`
  - `completed`
  - `failed`
  - `cancelled`

* `--workflow-current-step-id <WORKFLOW_CURRENT_STEP_ID>`
* `--workflow-attempts <WORKFLOW_ATTEMPTS>`
* `--workflow-branch <WORKFLOW_BRANCH>`
* `--workflow-worktree <WORKFLOW_WORKTREE>`
* `--workflow-pr-number <WORKFLOW_PR_NUMBER>`
* `--workflow-pr-url <WORKFLOW_PR_URL>`
* `--workflow-last-error <WORKFLOW_LAST_ERROR>`
* `--workflow-policy-trace-id <WORKFLOW_POLICY_TRACE_ID>`
* `--session-id <SESSION_ID>`
* `--work-item-id <WORK_ITEM_ID>`
* `--estimated-tokens <ESTIMATED_TOKENS>`
* `--estimated-cost-microusd <ESTIMATED_COST_MICROUSD>`
* `--clear-project`
* `--clear-session`
* `--clear-work-item`
* `--clear-parent`
* `--clear-estimated-tokens`
* `--clear-estimated-cost-microusd`
* `--clear-external-refs`
* `--clear-planning`
* `--clear-workflow`



## `harness task-board delete`

Tombstone one board task

**Usage:** `harness task-board delete <ID>`

###### **Arguments:**

* `<ID>`



## `harness task-board begin`

Move an item into planning and clear any approval

**Usage:** `harness task-board begin <ID>`

###### **Arguments:**

* `<ID>`



## `harness task-board submit`

Submit a plan summary for review

**Usage:** `harness task-board submit --summary <SUMMARY> <ID>`

###### **Arguments:**

* `<ID>`

###### **Options:**

* `--summary <SUMMARY>`



## `harness task-board approve`

Approve a submitted plan and move it to ready work

**Usage:** `harness task-board approve [OPTIONS] --approved-by <APPROVED_BY> <ID>`

###### **Arguments:**

* `<ID>`

###### **Options:**

* `--approved-by <APPROVED_BY>`
* `--approved-at <APPROVED_AT>`



## `harness task-board plan-revoke`

Revoke a previously granted approval; the plan summary stays intact

**Usage:** `harness task-board plan-revoke [OPTIONS] <ID>`

###### **Arguments:**

* `<ID>`

###### **Options:**

* `--actor <ACTOR>`



## `harness task-board sync`

Run external synchronization

**Usage:** `harness task-board sync [OPTIONS]`

###### **Options:**

* `--json`
* `--provider <PROVIDER>`

  Possible values: `github`

* `--direction <DIRECTION>`

  Default value: `both`

  Possible values: `pull`, `push`, `both`

* `--conflict-policy <CONFLICT_POLICY>`

  Default value: `report`

  Possible values: `report`, `prefer_local`, `prefer_remote`

* `--apply`



## `harness task-board dispatch`

Dispatch ready work into sessions

**Usage:** `harness task-board dispatch [OPTIONS]`

###### **Options:**

* `--json`
* `--dry-run`
* `--item-id <ITEM_ID>` [alias: `id`]
* `--status <STATUS>`

  Possible values: `inbox`, `todo`, `planning`, `in_progress`, `agentic_review`, `testing`, `in_review`, `to_review`, `human_required`, `failed`, `done`, `new`, `plan_review`, `needs_you`, `blocked`

* `--project-dir <PROJECT_DIR>`
* `--actor <ACTOR>`



## `harness task-board dispatch-pick`

Preview the highest-priority ready task-board dispatch

**Usage:** `harness task-board dispatch-pick [OPTIONS]`

**Command Alias:** `pick`

###### **Options:**

* `--json`



## `harness task-board dispatch-deliver`

Deliver one held task-board dispatch

**Usage:** `harness task-board dispatch-deliver [OPTIONS] --item-id <ITEM_ID>`

**Command Alias:** `deliver`

###### **Options:**

* `--item-id <ITEM_ID>` [alias: `id`]
* `--dry-run`
* `--json`



## `harness task-board evaluate`

Evaluate linked session work and update board workflow state

**Usage:** `harness task-board evaluate [OPTIONS]`

###### **Options:**

* `--json`
* `--dry-run`
* `--item-id <ITEM_ID>` [alias: `id`]
* `--status <STATUS>`

  Possible values: `inbox`, `todo`, `planning`, `in_progress`, `agentic_review`, `testing`, `in_review`, `to_review`, `human_required`, `failed`, `done`, `new`, `plan_review`, `needs_you`, `blocked`

* `--project-dir <PROJECT_DIR>`



## `harness task-board progress`

Report and read worker progress on a dispatched item

**Usage:** `harness task-board progress <COMMAND>`

###### **Subcommands:**

* `checkpoint` — Record a checkpoint against the dispatched work item
* `submit-for-review` — Hand the work item to review, keeping the attempt that produced it
* `complete` — Report the work item as finished
* `block` — Report the work item as stalled and needing a human
* `show` — Show the current progress and checkpoint log



## `harness task-board progress checkpoint`

Record a checkpoint against the dispatched work item

**Usage:** `harness task-board progress checkpoint [OPTIONS] --item-id <ITEM_ID> --summary <SUMMARY>`

###### **Options:**

* `--item-id <ITEM_ID>` [alias: `id`] — Task-board item identifier
* `--actor <ACTOR>` — The agent reporting. Defaults to the calling principal
* `--sequence <SEQUENCE>` — Ordering fence; must be greater than the last accepted report
* `--json`
* `--summary <SUMMARY>` — What the worker has done since the last checkpoint
* `--progress <PROGRESS>`
* `--running` — Report the worker as running rather than leaving the state alone



## `harness task-board progress submit-for-review`

Hand the work item to review, keeping the attempt that produced it

**Usage:** `harness task-board progress submit-for-review [OPTIONS] --item-id <ITEM_ID>`

###### **Options:**

* `--item-id <ITEM_ID>` [alias: `id`] — Task-board item identifier
* `--actor <ACTOR>` — The agent reporting. Defaults to the calling principal
* `--sequence <SEQUENCE>` — Ordering fence; must be greater than the last accepted report
* `--json`
* `--summary <SUMMARY>` — What the reviewer should look at



## `harness task-board progress complete`

Report the work item as finished

**Usage:** `harness task-board progress complete [OPTIONS] --item-id <ITEM_ID>`

###### **Options:**

* `--item-id <ITEM_ID>` [alias: `id`] — Task-board item identifier
* `--actor <ACTOR>` — The agent reporting. Defaults to the calling principal
* `--sequence <SEQUENCE>` — Ordering fence; must be greater than the last accepted report
* `--json`
* `--summary <SUMMARY>`



## `harness task-board progress block`

Report the work item as stalled and needing a human

**Usage:** `harness task-board progress block [OPTIONS] --item-id <ITEM_ID> --reason <REASON>`

###### **Options:**

* `--item-id <ITEM_ID>` [alias: `id`] — Task-board item identifier
* `--actor <ACTOR>` — The agent reporting. Defaults to the calling principal
* `--sequence <SEQUENCE>` — Ordering fence; must be greater than the last accepted report
* `--json`
* `--reason <REASON>` — Why the work cannot continue



## `harness task-board progress show`

Show the current progress and checkpoint log

**Usage:** `harness task-board progress show [OPTIONS] --item-id <ITEM_ID>`

###### **Options:**

* `--item-id <ITEM_ID>` [alias: `id`]
* `--json`



## `harness task-board audit`

Print task-board audit data

**Usage:** `harness task-board audit [OPTIONS]`

###### **Options:**

* `--json`



## `harness task-board project`

Manage known projects

**Usage:** `harness task-board project [OPTIONS]`

###### **Options:**

* `--json`
* `--status <STATUS>`

  Possible values: `inbox`, `todo`, `planning`, `in_progress`, `agentic_review`, `testing`, `in_review`, `to_review`, `human_required`, `failed`, `done`, `new`, `plan_review`, `needs_you`, `blocked`




## `harness task-board machine`

Manage known worker machines

**Usage:** `harness task-board machine [OPTIONS]`

###### **Options:**

* `--json`
* `--status <STATUS>`

  Possible values: `inbox`, `todo`, `planning`, `in_progress`, `agentic_review`, `testing`, `in_review`, `to_review`, `human_required`, `failed`, `done`, `new`, `plan_review`, `needs_you`, `blocked`




## `harness task-board host`

Manage the local host record and its declared project types

**Usage:** `harness task-board host <COMMAND>`

###### **Subcommands:**

* `list` — List every registered host
* `local` — Show the local host record, creating one on first call
* `set-project-types` — Replace the local host's declared project types
* `clear-project-types` — Drop every `project_type` from the local host record



## `harness task-board host list`

List every registered host

**Usage:** `harness task-board host list [OPTIONS]`

###### **Options:**

* `--json`



## `harness task-board host local`

Show the local host record, creating one on first call

**Usage:** `harness task-board host local [OPTIONS]`

###### **Options:**

* `--json`



## `harness task-board host set-project-types`

Replace the local host's declared project types

**Usage:** `harness task-board host set-project-types [OPTIONS]`

###### **Options:**

* `--type <PROJECT_TYPES>` — Project types this host accepts. Repeat the flag for multiple types
* `--json`



## `harness task-board host clear-project-types`

Drop every `project_type` from the local host record

**Usage:** `harness task-board host clear-project-types [OPTIONS]`

###### **Options:**

* `--json`



## `harness task-board orchestrator`

Manage autonomous task-board orchestration

**Usage:** `harness task-board orchestrator <COMMAND>`

###### **Subcommands:**

* `status` — Print durable orchestrator status
* `start` — Enable autonomous orchestration intent
* `stop` — Disable autonomous orchestration intent
* `run-once` — Run one orchestrator tick
* `settings` — Read or update durable orchestrator settings
* `runtime-config` — Read or update git runtime config
* `github-tokens` — Sync process-local GitHub tokens from environment variables



## `harness task-board orchestrator status`

Print durable orchestrator status

**Usage:** `harness task-board orchestrator status [OPTIONS]`

###### **Options:**

* `--json`



## `harness task-board orchestrator start`

Enable autonomous orchestration intent

**Usage:** `harness task-board orchestrator start [OPTIONS]`

###### **Options:**

* `--json`



## `harness task-board orchestrator stop`

Disable autonomous orchestration intent

**Usage:** `harness task-board orchestrator stop [OPTIONS]`

###### **Options:**

* `--json`



## `harness task-board orchestrator run-once`

Run one orchestrator tick

**Usage:** `harness task-board orchestrator run-once [OPTIONS]`

###### **Options:**

* `--json`
* `--dry-run`
* `--apply`
* `--item-id <ITEM_ID>` [alias: `id`]
* `--status <STATUS>`

  Possible values: `inbox`, `todo`, `planning`, `in_progress`, `agentic_review`, `testing`, `in_review`, `to_review`, `human_required`, `failed`, `done`, `new`, `plan_review`, `needs_you`, `blocked`

* `--project-dir <PROJECT_DIR>`
* `--actor <ACTOR>`



## `harness task-board orchestrator settings`

Read or update durable orchestrator settings

**Usage:** `harness task-board orchestrator settings [OPTIONS]`

###### **Options:**

* `--json`
* `--step-mode <STEP_MODE>`

  Possible values: `true`, `false`

* `--dry-run-default <DRY_RUN_DEFAULT>`

  Possible values: `true`, `false`

* `--dispatch-status-filter <DISPATCH_STATUS_FILTER>`

  Possible values: `inbox`, `todo`, `planning`, `in_progress`, `agentic_review`, `testing`, `in_review`, `to_review`, `human_required`, `failed`, `done`, `new`, `plan_review`, `needs_you`, `blocked`

* `--clear-dispatch-status-filter`
* `--project-dir <PROJECT_DIR>`
* `--clear-project-dir`
* `--admission-policy <JSON>` — Complete admission policy as a JSON object



## `harness task-board orchestrator runtime-config`

Read or update git runtime config

**Usage:** `harness task-board orchestrator runtime-config [OPTIONS]`

###### **Options:**

* `--json`
* `--repository <REPOSITORY>`
* `--author-name <AUTHOR_NAME>`
* `--clear-author-name`
* `--author-email <AUTHOR_EMAIL>`
* `--clear-author-email`
* `--ssh-key-path <SSH_KEY_PATH>`
* `--clear-ssh-key-path`
* `--ssh-private-key-env <SSH_PRIVATE_KEY_ENV>`
* `--ssh-private-key-passphrase-env <SSH_PRIVATE_KEY_PASSPHRASE_ENV>`
* `--signing-mode <SIGNING_MODE>`

  Possible values: `none`, `ssh`, `gpg`

* `--signing-ssh-key-path <SIGNING_SSH_KEY_PATH>`
* `--signing-ssh-private-key-env <SIGNING_SSH_PRIVATE_KEY_ENV>`
* `--signing-ssh-private-key-passphrase-env <SIGNING_SSH_PRIVATE_KEY_PASSPHRASE_ENV>`
* `--gpg-key-id <GPG_KEY_ID>`
* `--gpg-private-key-path <GPG_PRIVATE_KEY_PATH>`
* `--gpg-private-key-env <GPG_PRIVATE_KEY_ENV>`
* `--gpg-private-key-passphrase-env <GPG_PRIVATE_KEY_PASSPHRASE_ENV>`
* `--clear-signing`



## `harness task-board orchestrator github-tokens`

Sync process-local GitHub tokens from environment variables

**Usage:** `harness task-board orchestrator github-tokens [OPTIONS]`

###### **Options:**

* `--json`
* `--clear`
* `--global-token-env <GLOBAL_TOKEN_ENV>`
* `--repository-token-env <REPOSITORY_TOKEN_ENV>`



## `harness task-board policy`

Manage task-board spawn policy and approval grants

**Usage:** `harness task-board policy <COMMAND>`

###### **Subcommands:**

* `dump` — Dump policy canvases as a portable JSON bundle
* `import` — Import policy canvases from JSON files or standard input
* `grants` — List pending approval grants
* `grant-resolve` — Approve or deny one pending approval grant
* `grant-revoke` — Revoke one approval grant
* `spawn-requires-live-policy` — Toggle the fail-closed live-policy requirement for worker spawning
* `spawn-kill-switch` — Toggle the emergency app-wide automation kill switch



## `harness task-board policy dump`

Dump policy canvases as a portable JSON bundle

**Usage:** `harness task-board policy dump [OPTIONS]`

**Command Alias:** `export`

###### **Options:**

* `--canvas-id <CANVAS_IDS>` — Limit the dump to one or more policy canvases



## `harness task-board policy import`

Import policy canvases from JSON files or standard input

**Usage:** `harness task-board policy import [OPTIONS] [INPUT]...`

###### **Arguments:**

* `<INPUT>` — JSON file to import; use `-` for standard input

  Default value: `-`

###### **Options:**

* `--replace-all` — Replace the whole policy workspace using bundle metadata
* `--json` — Print the daemon response as JSON



## `harness task-board policy grants`

List pending approval grants

**Usage:** `harness task-board policy grants [OPTIONS]`

**Command Alias:** `approval-grants-list`

###### **Options:**

* `--json`



## `harness task-board policy grant-resolve`

Approve or deny one pending approval grant

**Usage:** `harness task-board policy grant-resolve [OPTIONS] <GRANT_ID>`

**Command Alias:** `approval-grant-resolve`

###### **Arguments:**

* `<GRANT_ID>`

###### **Options:**

* `--approve`
* `--deny`
* `--actor <ACTOR>`
* `--json`



## `harness task-board policy grant-revoke`

Revoke one approval grant

**Usage:** `harness task-board policy grant-revoke [OPTIONS] <GRANT_ID>`

**Command Alias:** `approval-grant-revoke`

###### **Arguments:**

* `<GRANT_ID>`

###### **Options:**

* `--actor <ACTOR>`
* `--json`



## `harness task-board policy spawn-requires-live-policy`

Toggle the fail-closed live-policy requirement for worker spawning

**Usage:** `harness task-board policy spawn-requires-live-policy [OPTIONS] --enabled <ENABLED>`

**Command Alias:** `set-spawn-requires-live-policy`

###### **Options:**

* `--enabled <ENABLED>`

  Possible values: `true`, `false`

* `--json`



## `harness task-board policy spawn-kill-switch`

Toggle the emergency app-wide automation kill switch

**Usage:** `harness task-board policy spawn-kill-switch [OPTIONS] --enabled <ENABLED>`

**Command Alias:** `set-spawn-kill-switch`

###### **Options:**

* `--enabled <ENABLED>`

  Possible values: `true`, `false`

* `--json`



## `harness task-board triage-escalation`

Triage escalation commands. The daemon's own spawned escalation worker is the only real caller

**Usage:** `harness task-board triage-escalation <COMMAND>`

###### **Subcommands:**

* `report` — Report a triage escalation verdict back to the daemon



## `harness task-board triage-escalation report`

Report a triage escalation verdict back to the daemon

**Usage:** `harness task-board triage-escalation report [OPTIONS] --token <TOKEN> --fingerprint <FINGERPRINT> --verdict <VERDICT> --rationale <RATIONALE> <ESCALATION_ID>`

###### **Arguments:**

* `<ESCALATION_ID>` — The escalation id from the prompt

###### **Options:**

* `--token <TOKEN>` — The single-use token from the prompt -- the entire credential for this report, not the daemon's control-plane session token
* `--fingerprint <FINGERPRINT>` — The item's evidence fingerprint from the prompt
* `--verdict <VERDICT>` — `todo` or `undecided`
* `--rationale <RATIONALE>` — At most 256 bytes, no control characters, and -- because the rendered prompt wraps this argument in single quotes -- no quote characters. Validated here so a non-conforming agent gets an immediate, actionable CLI error and can re-run with the same still-running token, instead of a confusing shell error or the daemon silently dropping an out-of-bounds rationale
* `--json`



## `harness daemon`

Local daemon for the Harness app

**Usage:** `harness daemon <COMMAND>`

###### **Subcommands:**

* `status` — Arguments validated by the selected worker after process delegation
* `identity` — Arguments validated by the selected worker after process delegation
* `stop` — Arguments validated by the selected worker after process delegation
* `restart` — Arguments validated by the selected worker after process delegation
* `install-launch-agent` — Arguments validated by the selected worker after process delegation
* `remove-launch-agent` — Arguments validated by the selected worker after process delegation
* `doctor` — Arguments validated by the selected worker after process delegation
* `snapshot` — Arguments validated by the selected worker after process delegation



## `harness daemon status`

Arguments validated by the selected worker after process delegation

**Usage:** `harness daemon status [ARGS]...`

###### **Arguments:**

* `<ARGS>`



## `harness daemon identity`

Arguments validated by the selected worker after process delegation

**Usage:** `harness daemon identity [ARGS]...`

###### **Arguments:**

* `<ARGS>`



## `harness daemon stop`

Arguments validated by the selected worker after process delegation

**Usage:** `harness daemon stop [ARGS]...`

###### **Arguments:**

* `<ARGS>`



## `harness daemon restart`

Arguments validated by the selected worker after process delegation

**Usage:** `harness daemon restart [ARGS]...`

###### **Arguments:**

* `<ARGS>`



## `harness daemon install-launch-agent`

Arguments validated by the selected worker after process delegation

**Usage:** `harness daemon install-launch-agent [ARGS]...`

###### **Arguments:**

* `<ARGS>`



## `harness daemon remove-launch-agent`

Arguments validated by the selected worker after process delegation

**Usage:** `harness daemon remove-launch-agent [ARGS]...`

###### **Arguments:**

* `<ARGS>`



## `harness daemon doctor`

Arguments validated by the selected worker after process delegation

**Usage:** `harness daemon doctor [ARGS]...`

###### **Arguments:**

* `<ARGS>`



## `harness daemon snapshot`

Arguments validated by the selected worker after process delegation

**Usage:** `harness daemon snapshot [ARGS]...`

###### **Arguments:**

* `<ARGS>`



## `harness bridge`

Supervise host capabilities for sandboxed Codex and terminal agent flows

**Usage:** `harness bridge <COMMAND>`

###### **Subcommands:**

* `stop` — Arguments validated by the selected worker after process delegation
* `status` — Arguments validated by the selected worker after process delegation
* `reconfigure` — Arguments validated by the selected worker after process delegation
* `install-launch-agent` — Arguments validated by the selected worker after process delegation
* `remove-launch-agent` — Arguments validated by the selected worker after process delegation



## `harness bridge stop`

Arguments validated by the selected worker after process delegation

**Usage:** `harness bridge stop [ARGS]...`

###### **Arguments:**

* `<ARGS>`



## `harness bridge status`

Arguments validated by the selected worker after process delegation

**Usage:** `harness bridge status [ARGS]...`

###### **Arguments:**

* `<ARGS>`



## `harness bridge reconfigure`

Arguments validated by the selected worker after process delegation

**Usage:** `harness bridge reconfigure [ARGS]...`

###### **Arguments:**

* `<ARGS>`



## `harness bridge install-launch-agent`

Arguments validated by the selected worker after process delegation

**Usage:** `harness bridge install-launch-agent [ARGS]...`

###### **Arguments:**

* `<ARGS>`



## `harness bridge remove-launch-agent`

Arguments validated by the selected worker after process delegation

**Usage:** `harness bridge remove-launch-agent [ARGS]...`

###### **Arguments:**

* `<ARGS>`



<hr/>

<small><i>
    This document was generated automatically by
    <a href="https://crates.io/crates/clap-markdown"><code>clap-markdown</code></a>.
</i></small>
