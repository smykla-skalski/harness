# Session command surface

## Contents

- [Lifecycle](#lifecycle)
- [Roles](#roles)
- [Tasks](#tasks)
- [Signals](#signals)
- [Observation](#observation)
- [TUI](#tui)
- [Runtimes](#runtimes)

## Lifecycle

```
harness session start --context "<goal>" [--title "<title>"] [--session-id <id>] [--runtime <runtime>]
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

## Tasks

```
harness session task create <session-id> --title "..." --context "..." --severity <level> --actor <agent-id> [--suggested-fix "..."]
harness session task assign <session-id> <task-id> <agent-id> --actor <agent-id>
harness session task list <session-id> [--status <status>] [--json]
harness session task update <session-id> <task-id> --status <status> [--note "..."] --actor <agent-id>
harness session task checkpoint <session-id> <task-id> --summary "..." --progress <0-100> --actor <agent-id>
```

Task statuses: `open`, `in-progress`, `in-review`, `blocked`, `done`.
Task severities: `low`, `medium`, `high`, `critical`.

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

## TUI

Managed interactive agent TUI processes.

```
harness session tui start <session-id> --runtime <runtime> [--agent-id <id>]
harness session tui attach <session-id> <tui-id>
harness session tui list <session-id>
harness session tui show <session-id> <tui-id>
harness session tui input <session-id> <tui-id> --text "..."
harness session tui resize <session-id> <tui-id> --cols <n> --rows <n>
harness session tui stop <session-id> <tui-id>
```

## Runtimes

Supported: `claude`, `codex`, `gemini`, `copilot`, `opencode`, `vibe`.

Bootstrap all runtimes: `harness setup bootstrap`
Narrow to subset: `harness setup bootstrap --agents <runtime[,runtime...]>`
