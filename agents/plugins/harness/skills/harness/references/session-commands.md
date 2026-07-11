# Session command surface

## Contents

- [Lifecycle](#lifecycle)
- [Roles](#roles)
- [Task board](#task-board)
- [Signals](#signals)
- [Observation](#observation)
- [TUI](#tui)
- [Runtimes](#runtimes)

## Lifecycle

```
harness session start --context "<goal>" [--title "<title>"] [--session-id <id>] [--project-dir <path>] [--policy-preset <name>]
harness session join <session-id> --role <role> --runtime <runtime> [--capabilities "x,y"] [--name "<name>"]
harness session end <session-id> --actor <agent-id>
harness session status <session-id> [--json]
harness session list [--all] [--json]
harness session leave <session-id> <agent-id>
harness session title <session-id> --title "<title>"
harness session sync <session-id> [--json]
```

## Roles

```
harness session assign <session-id> <agent-id> --role <role> [--reason "..."] --actor <agent-id>
harness session remove <session-id> <agent-id> --actor <agent-id>
harness session transfer-leader <session-id> <new-leader-id> [--reason "..."] --actor <agent-id>
harness session recover-leader <session-id>
```

Roles: `leader`, `observer`, `worker`, `reviewer`, `improver`.

## Task board

Task-board commands require a running daemon with database-backed task-board
storage. Start Harness Monitor or run `harness daemon dev` first.

```
harness task-board create --title "..." [--body "..."] [--priority <priority>] [--agent-mode <mode>] [--project-id <id>] [--tag <tag>] [--id <id>]
harness task-board list [--status <status>] [--json]
harness task-board get <task-id> [--json]
harness task-board update <task-id> [--title "..."] [--body "..."] [--status <status>] [--priority <priority>] [--agent-mode <mode>] [--project-id <id>] [--clear-project] [--tag <tag>] [--planning-summary "..."] [--approved-by <id>]
harness task-board delete <task-id>
harness task-board sync [--json] [--provider <provider>] [--direction <pull|push|both>] [--apply]
harness task-board dispatch [--json] [--dry-run] [--item-id <id>] [--status <status>] [--project-dir <path>] [--actor <agent-id>]
harness task-board evaluate [--json] [--dry-run] [--item-id <id>] [--status <status>] [--project-dir <path>]
harness task-board audit [--json]
harness task-board project [--json] [--status <status>]
harness task-board machine [--json] [--status <status>]
harness task-board orchestrator status [--json]
harness task-board orchestrator start [--json]
harness task-board orchestrator stop [--json]
harness task-board orchestrator run-once [--json] [--dry-run|--apply] [--item-id <id>] [--status <status>] [--project-dir <path>] [--actor <agent-id>]
harness task-board orchestrator settings [--json] [--dry-run-default <bool>] [--dispatch-status-filter <status>] [--clear-dispatch-status-filter] [--project-dir <path>] [--clear-project-dir]
```

Task statuses: `new`, `planning`, `plan_review`, `todo`, `in_progress`, `in_review`, `done`, `blocked`.
Task priorities: `low`, `medium`, `high`, `critical`.
Agent modes: `headless`, `interactive`, `planning`, `evaluate`.

Read [task-board-workflow.md](task-board-workflow.md) for planning gates,
dispatch/evaluate behavior, orchestrator routes, policy pipeline routes, and
overview commands.

## Signals

```
harness session signal send <session-id> <agent-id> --command <cmd> --message "..." [--action-hint "..."] --actor <agent-id>
harness session signal list <session-id> [--agent <id>] [--json]
```

Signal commands: `inject_context`, `request_action`, `transfer_leadership`, `pause`, `resume`, `abort`.

## Observation

```
harness session observe <session-id> [--poll-interval <seconds>] --actor <agent-id> [--json]
```

Cross-agent observation within session. Combines with `--poll-interval` for continuous monitoring.

## Agents

Unified managed terminal and Codex thread operations.

```
harness session agents start terminal <session-id> --runtime <runtime> [--role <role>] [--capability <tag>] [--name "..."] [--prompt "..."] [--persona <id>] [--model <model>] [--effort <level>]
harness session agents start codex <session-id> --mode <mode> --prompt "..." [--role <role>] [--capability <tag>] [--name "..."] [--persona <id>] [--resume-thread-id <id>] [--model <model>] [--effort <level>]
harness session agents start acp --session-id <session-id> --agent <descriptor> [--role <role>] [--capability <tag>] [--name "..."] [--prompt "..."] [--persona <id>] [--model <model>] [--effort <level>]
harness session agents attach <agent-id>
harness session agents list <session-id>
harness session agents show <agent-id>
harness session agents input <agent-id> (--text "..."|--paste "..."|--key <key>|--control <char>|--raw-base64 <data>)
harness session agents resize <agent-id> --cols <n> --rows <n>
harness session agents stop <agent-id>
harness session agents steer <agent-id> --prompt "..."
harness session agents interrupt <agent-id>
harness session agents approve <agent-id> <approval-id> --decision <accept|reject>
harness session agents acp inspect [--session-id <session-id>]
```

Task-board dispatch creates session tasks and records worker/reviewer/evaluator
intent, but managed agent capacity is launched through these `session agents`
commands. Terminal, Codex, and ACP starts can carry role, fallback role,
capabilities, display name, persona, model, effort, and project-directory
context when supported by that runtime.

## Runtimes

Supported: `claude`, `codex`, `gemini`, `copilot`, `opencode`, `vibe`.

Bootstrap all runtimes: `harness setup bootstrap`
Narrow to subset: `harness setup bootstrap --agents <runtime[,runtime...]>`
