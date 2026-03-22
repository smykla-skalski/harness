# Command surface

Supported invocation shapes for `harness observe`.

## Doctor

- project health and contract drift:
  `harness observe doctor --project-dir <path> --json`
- default current project resolution:
  `harness observe doctor`

## Scan and watch

- one-shot scan:
  `harness observe scan <session-id> --project-hint <hint> --json --summary`
- filtered scan:
  `harness observe scan <session-id> --project-hint <hint> --from-line <n> --until-line <n> --from <line|timestamp|prose> --focus <preset> --severity <level> --category <csv> --exclude <csv> --fixable --since-timestamp <iso> --until-timestamp <iso> --json --summary`
- output control:
  `harness observe scan <session-id> --format <json|markdown|sarif> --output <path> --output-details --top-causes <n> --json --summary`
- watch mode:
  `harness observe watch <session-id> --project-hint <hint> --from-line <n> --poll-interval 3 --timeout 90 --json --summary`
- raw dump:
  `harness observe dump <session-id> --project-hint <hint> --from-line <n> --to-line <m>`
- filtered dump:
  `harness observe dump <session-id> --project-hint <hint> --from-line <n> --to-line <m> --filter <substring> --role <assistant|user|tool> --tool-name <name>`
- context dump:
  `harness observe dump <session-id> --project-hint <hint> --context-line <line> --context-window 20`
- raw JSON dump:
  `harness observe dump <session-id> --project-hint <hint> --from-line <n> --to-line <m> --raw-json`

## Maintenance actions

Observer maintenance actions go through `scan --action`:

- canonical cycle form:
  `harness observe scan <session-id> --action cycle`
- canonical status form:
  `harness observe scan <session-id> --action status`
- cycle:
  `harness observe scan <session-id> --project-hint <hint> --action cycle`
- status:
  `harness observe scan <session-id> --project-hint <hint> --action status`
- resume:
  `harness observe scan <session-id> --project-hint <hint> --action resume --json --summary`
- verify:
  `harness observe scan <session-id> --project-hint <hint> --action verify --issue-id <issue-id> [--since-line <line>]`
- resolve-from:
  `harness observe scan <session-id> --project-hint <hint> --action resolve-from --value "<line|timestamp|prose>"`
- compare:
  `harness observe scan <session-id> --project-hint <hint> --action compare --range-a <from:to> --range-b <from:to>`
- list categories:
  `harness observe scan <session-id> --action list-categories`
- list focus presets:
  `harness observe scan <session-id> --action list-focus-presets`
- mute:
  `harness observe scan <session-id> --project-hint <hint> --action mute --codes <csv>`
- unmute:
  `harness observe scan <session-id> --project-hint <hint> --action unmute --codes <csv>`

## Machine-readable output

- issue JSON is one line per issue and uses nested sections:
  `id`, `location`, `classification`, `source`, `message`, `remediation`
- summary JSON is the final line when `--summary` is set and uses:
  `status`, `cursor.last_line`, `issues.total`, `issues.by_severity[]`, `issues.by_category[]`
- top causes use:
  `causes[]` with `code`, `occurrences`, and `summary`
- SARIF remains SARIF `2.1.0`, with harness-specific properties nested under:
  `properties.harnessObserve`
