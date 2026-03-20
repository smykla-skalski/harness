# Command surface

Supported invocation shapes for `harness observe`.

## Scan and watch

- one-shot scan:
  `harness observe scan <session-id> --project-hint <hint> --json --summary`
- filtered scan:
  `harness observe scan <session-id> --project-hint <hint> --from-line <n> --focus <preset> --severity <level> --category <csv> --exclude <csv> --fixable --json --summary`
- watch mode:
  `harness observe watch <session-id> --project-hint <hint> --from-line <n> --poll-interval 3 --timeout 90 --json --summary`
- raw dump:
  `harness observe dump <session-id> --project-hint <hint> --from-line <n> --to-line <m>`
- context dump:
  `harness observe dump <session-id> --project-hint <hint> --context-line <line> --context-window 20`

## Maintenance actions

Maintenance actions go through `scan --action`:

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
- doctor:
  `harness observe scan <session-id> --action doctor`
- mute:
  `harness observe scan <session-id> --project-hint <hint> --action mute --codes <csv>`
- unmute:
  `harness observe scan <session-id> --project-hint <hint> --action unmute --codes <csv>`
