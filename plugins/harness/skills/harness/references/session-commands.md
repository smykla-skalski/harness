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

```
harness task-board create --title "..." [--body "..."] [--priority <priority>] [--agent-mode <mode>] [--project-id <id>] [--tag <tag>] [--id <id>]
harness task-board list [--status <status>] [--json]
harness task-board get <task-id> [--json]
harness task-board update <task-id> [--title "..."] [--body "..."] [--status <status>] [--priority <priority>] [--agent-mode <mode>] [--project-id <id>] [--clear-project] [--tag <tag>] [--planning-summary "..."] [--approved-by <id>]
harness task-board delete <task-id>
harness task-board sync [--json]
harness task-board dispatch [--json]
harness task-board audit [--json]
harness task-board project [--json]
harness task-board machine [--json]
```

Task statuses: `new`, `planning`, `plan_review`, `todo`, `in_progress`, `in_review`, `done`, `blocked`.
Task priorities: `low`, `medium`, `high`, `critical`.
Agent modes: `headless`, `interactive`, `planning`, `evaluate`.

Read [task-board-workflow.md](task-board-workflow.md) for planning gates, review gates, dispatch readiness, and overview commands.

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
harness session agents start terminal <session-id> --runtime <runtime> [--agent-id <id>]
harness session agents start codex <session-id> --mode <mode> --prompt "..."
harness session agents attach <session-id> <agent-id>
harness session agents list <session-id>
harness session agents show <session-id> <agent-id>
harness session agents input <session-id> <agent-id> --text "..."
harness session agents resize <session-id> <agent-id> --cols <n> --rows <n>
harness session agents stop <session-id> <agent-id>
harness session agents steer <session-id> <agent-id> --prompt "..."
harness session agents interrupt <session-id> <agent-id>
harness session agents approve <session-id> <agent-id> <approval-id> --decision <accept|reject>
```

## Runtimes

Supported: `claude`, `codex`, `gemini`, `copilot`, `opencode`, `vibe`.

Bootstrap all runtimes: `harness setup bootstrap`
Narrow to subset: `harness setup bootstrap --agents <runtime[,runtime...]>`
