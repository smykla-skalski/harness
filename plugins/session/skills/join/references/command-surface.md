# Session command surface

## Lifecycle

```
harness session start --context "<goal>"
harness session join <session-id> --role <role> --runtime <runtime> [--capabilities "x,y"]
harness session end <session-id> --actor <agent-id>
harness session status <session-id> [--json]
harness session list [--json]
```

## Roles

```
harness session assign <session-id> <agent-id> --role <role> --actor <agent-id>
harness session remove <session-id> <agent-id> --actor <agent-id>
harness session transfer-leader <session-id> <new-leader-id> [--reason "..."] --actor <agent-id>
```

Roles: `leader`, `observer`, `worker`, `reviewer`, `improver`.

## Tasks

```
harness session task create <session-id> --title "..." --context "..." --severity <low|medium|high|critical> --actor <agent-id>
harness session task assign <session-id> <task-id> <agent-id> --actor <agent-id>
harness session task list <session-id> [--status <status>] [--json]
harness session task update <session-id> <task-id> --status <status> [--note "..."] --actor <agent-id>
harness session task checkpoint <session-id> --summary "..." --progress <0-100> --actor <agent-id>
```

Task statuses: `open`, `in-progress`, `in-review`, `blocked`, `done`.
Task severities: `low`, `medium`, `high`, `critical`.

## Signals

```
harness session signal send <agent-id> --command <cmd> --message "..." --session-id <id> --actor <agent-id>
harness session signal list [--agent <id>] --session-id <id> [--json]
```

Signal commands: `inject_context`, `request_action`, `transfer_leadership`, `pause`, `resume`, `abort`.

## Observation

```
harness session observe <session-id> [--poll-interval <seconds>] --actor <agent-id> [--json]
```

Runs the observe classifier pipeline across all registered agents in the session. Combines with `--poll-interval` for continuous monitoring.

## Runtimes

Supported: `claude`, `codex`, `gemini`, `copilot`, `opencode`.

Bootstrap all runtimes with `harness setup bootstrap`. Narrow to a subset with `harness setup bootstrap --agents <runtime[,runtime...]>`.
