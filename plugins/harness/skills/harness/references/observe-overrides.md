# Observer overrides

Configure classifier behavior through CLI flags or persisted observer state.

Observer state is stored at:
```
~harness/projects/project-<digest>/agents/observe/<observe-id>/snapshot.json
```

Do not edit that file manually. Use `harness observe scan <session-id> --action ...` to inspect or mutate.

## Mute list

Suppress specific issue codes that are known false positives.

**Persistent mute:**
```bash
harness observe scan <session-id> --action mute --codes shell_alias_interference,user_frustration_detected
```

**Persistent unmute:**
```bash
harness observe scan <session-id> --action unmute --codes shell_alias_interference
```

**One-shot per-scan mute:**
```bash
harness observe scan <session-id> --mute shell_alias_interference --json --summary
```

**Inspect current state:**
```bash
harness observe scan <session-id> --action status
```

## Focus presets

| Preset | Categories |
|--------|------------|
| `harness` | build_error, cli_error, workflow_error, data_integrity |
| `skills` | skill_behavior, hook_failure, naming_error, subagent_issue |
| `all` | No preset filter |

If both `--focus` and `--category` are set, the result is the intersection.

**List presets:**
```bash
harness observe scan <session-id> --action list-focus-presets
```

## Severity filtering

```bash
harness observe scan <session-id> --severity medium
```

Filters out low-severity issues. Valid values: `low`, `medium`, `critical`.

## Format options

| Flag | Output |
|------|--------|
| `--json` | JSONL output |
| `--format markdown` | Markdown table |
| `--format sarif` | SARIF output |
| `--top-causes 5` | Summarize most frequent issue codes |

## YAML overrides file

Create a YAML file for reusable overrides:

```yaml
mute:
  - shell_alias_interference
  - user_frustration_detected
severity_overrides:
  python_used_in_bash_output: low
  file_edit_churn: low
```

Use with scan or watch:

```bash
harness observe scan <session-id> --overrides path/to/overrides.yaml --json --summary
harness observe watch <session-id> --overrides path/to/overrides.yaml --json --summary
```
