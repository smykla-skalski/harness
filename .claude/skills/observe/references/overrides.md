# Observer overrides

Configure classifier behavior through CLI flags or the persisted observer state.

Observer state is stored automatically at `~harness/projects/project-<digest>/agents/observe/<observe-id>/snapshot.json`.

Do not edit that file manually. Use `harness observe scan <session-id> --action ...` to inspect or mutate observer state.

## Mute list

Suppress specific issue codes that are known false positives for the current session.

Persisted mute:

`harness observe scan <session-id> --action mute --codes shell_alias_interference,user_frustration_detected`

Persisted unmute:

`harness observe scan <session-id> --action unmute --codes shell_alias_interference`

One-shot per-scan mute:

`harness observe scan <session-id> --mute shell_alias_interference --json --summary`

Inspect the current persisted observer state:

`harness observe scan <session-id> --action status`

## Focus presets

Focus presets map to these category groups:

- `--focus harness`: build_error, cli_error, workflow_error, data_integrity
- `--focus skills`: skill_behavior, hook_failure, naming_error, subagent_issue
- `--focus all`: no preset filter

If both `--focus` and `--category` are set, the result is the intersection.

List current presets from the CLI:

`harness observe scan <session-id> --action list-focus-presets`

## Severity filtering

`--severity medium` filters out low-severity issues. Valid values are `low`, `medium`, and `critical`.

## Format options

- `--json`: JSONL output
- `--format markdown`: markdown table
- `--format sarif`: SARIF output
- `--top-causes 5`: summarize the most frequent issue codes

## YAML overrides file

YAML overrides are supported today through `--overrides path/to/file.yaml`.

Example:

```yaml
mute:
  - shell_alias_interference
  - user_frustration_detected
severity_overrides:
  python_used_in_bash_output: low
  file_edit_churn: low
```

Use it with scan or watch:

- `harness observe scan <session-id> --overrides path/to/overrides.yaml --json --summary`
- `harness observe watch <session-id> --overrides path/to/overrides.yaml --json --summary`
