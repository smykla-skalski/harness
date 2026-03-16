# Observer overrides

Configure classifier behavior per-session via CLI flags or the observer state file.

## Mute list

Suppress specific issue codes that are known false positives for your environment.

CLI: `harness observe mute <session-id> shell_alias_interference,user_frustration_detected`

Or pass per-scan: `harness observe scan <session-id> --mute shell_alias_interference`

To unmute: `harness observe unmute <session-id> shell_alias_interference`

## Focus presets

Filter by category group instead of listing individual categories.

- `--focus harness`: build_error, cli_error, workflow_error, data_integrity
- `--focus skills`: skill_behavior, hook_failure, naming_error, subagent_issue
- `--focus all`: no filter (default)

When both `--focus` and `--category` are set, the result is the intersection.

## Severity filtering

`--severity medium` filters out low-severity issues. Valid values: low, medium, critical.

## Format options

- `--json`: JSONL output (one issue per line)
- `--format markdown`: tabled markdown report
- `--top-causes 5`: show top 5 root causes grouped by issue code

## Future: YAML override file

Planned support for a YAML override config file:

```yaml
mute:
  - shell_alias_interference
  - user_frustration_detected
severity_overrides:
  python_used_in_bash_output: low
  file_edit_churn: low
```

Pass via `--overrides path/to/overrides.yaml` to apply on top of CLI flags.
