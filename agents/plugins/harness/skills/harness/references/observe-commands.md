# Observe command surface

Supported invocation shapes for `harness observe`.

## Contents

- [Doctor](#doctor)
- [Scan and watch](#scan-and-watch)
- [Dump](#dump)
- [Maintenance actions](#maintenance-actions)
- [Machine-readable output](#machine-readable-output)

## Doctor

Project health and contract drift:

```
harness observe doctor [--project-dir <path>] [--json]
harness observe --agent <runtime> doctor [--json]
```

## Scan and watch

One-shot scan:

```
harness observe scan <session-id> [--project-hint <hint>] [--json] [--summary]
```

Filtered scan:

```
harness observe scan <session-id> \
  [--project-hint <hint>] \
  [--from-line <n>] [--until-line <n>] \
  [--from <line|timestamp|prose>] \
  [--focus <harness|skills|all>] \
  [--severity <low|medium|critical>] \
  [--category <csv>] [--exclude <csv>] \
  [--fixable] \
  [--since-timestamp <iso>] [--until-timestamp <iso>] \
  [--json] [--summary]
```

Output control:

```
harness observe scan <session-id> \
  [--format <json|markdown|sarif>] \
  [--output <path>] \
  [--output-details] \
  [--top-causes <n>] \
  [--json] [--summary]
```

Watch mode:

```
harness observe watch <session-id> \
  [--project-hint <hint>] \
  [--from-line <n>] \
  [--poll-interval <seconds>] \
  [--timeout <seconds>] \
  [--json] [--summary]
```

## Dump

Raw dump:

```
harness observe dump <session-id> \
  [--project-hint <hint>] \
  [--from-line <n>] [--to-line <m>]
```

Filtered dump:

```
harness observe dump <session-id> \
  [--project-hint <hint>] \
  [--from-line <n>] [--to-line <m>] \
  [--filter <substring>] \
  [--role <assistant|user|tool>] \
  [--tool-name <name>]
```

Context dump:

```
harness observe dump <session-id> \
  [--project-hint <hint>] \
  [--context-line <line>] \
  [--context-window <n>]
```

Raw JSON dump:

```
harness observe dump <session-id> \
  [--project-hint <hint>] \
  [--from-line <n>] [--to-line <m>] \
  [--raw-json]
```

## Maintenance actions

Observer maintenance actions go through `scan --action`:

| Action | Command |
|--------|---------|
| cycle | `harness observe scan <session-id> --action cycle` |
| status | `harness observe scan <session-id> --action status` |
| resume | `harness observe scan <session-id> --action resume [--json] [--summary]` |
| verify | `harness observe scan <session-id> --action verify --issue-id <id> [--since-line <n>]` |
| resolve-from | `harness observe scan <session-id> --action resolve-from --value "<line|timestamp|prose>"` |
| compare | `harness observe scan <session-id> --action compare --range-a <from:to> --range-b <from:to>` |
| list-categories | `harness observe scan <session-id> --action list-categories` |
| list-focus-presets | `harness observe scan <session-id> --action list-focus-presets` |
| mute | `harness observe scan <session-id> --action mute --codes <csv>` |
| unmute | `harness observe scan <session-id> --action unmute --codes <csv>` |

## Machine-readable output

Issue JSON is one line per issue with nested sections:

- `id` - issue identifier
- `location` - line number, file, context
- `classification` - category, severity, confidence
- `source` - where the issue was detected
- `message` - human-readable description
- `remediation` - suggested fix

Summary JSON (final line when `--summary` set):

- `status` - scan status
- `cursor.last_line` - last processed line
- `issues.total` - total issue count
- `issues.by_severity[]` - counts per severity
- `issues.by_category[]` - counts per category

Top causes (with `--top-causes`):

- `causes[]` with `code`, `occurrences`, `summary`

SARIF output uses version `2.1.0` with harness-specific properties under `properties.harnessObserve`.
