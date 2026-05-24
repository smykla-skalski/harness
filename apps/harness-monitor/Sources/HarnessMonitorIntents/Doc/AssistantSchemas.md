# Apple Intelligence assistant schemas

Status as of macOS 26 (2026-05-24): **not adopted, by intent**.

Apple's `@AssistantIntent(schema:)` catalog at macOS 26 covers consumer
domains (Mail, Photos, Calendar, Reminders, Notes, Files, Browser,
Phone, Music, Books, Health) plus the Office-style schemas
(Spreadsheets, Presentations). There is no schema for source control,
code review, or developer tools.

Forcing one of the existing schemas onto our intents would mislead
routing - Apple Intelligence would treat "Approve this pull request" as
a mail or file operation and prompt the user accordingly. The cost
(wrong UI, confused user) outweighs the benefit (slightly better
visibility in Spotlight than the current keyword search already gives).

The intents are already surfaced through:

- `AppShortcutsProvider` with 10 voice phrases (Spotlight + Siri)
- `IntentDescription` with `categoryName` + `searchKeywords` (Shortcuts
  editor discoverability)
- `OpenIntent` conformance on `OpenPullRequestIntent` (the protocol
  Apple recommends for "show me this entity" intents)
- `ProvidesDialog` + `ShowsSnippetView` on `GetNeedsMeCountIntent` (rich
  Siri result rendering)
- `IntentDonationManager.donate` after every user-driven action (Apple's
  predictor learns over weeks)

If Apple publishes a developer-tools or source-control schema in a
future macOS release, revisit this file and adopt the matching schemas
on `SearchPullRequestsIntent`, `ListTaskBoardItemsIntent`,
`OpenPullRequestIntent`, and the read-only count / list intents.

Files to touch when that day comes:

- `Sources/HarnessMonitorIntents/Intents/Reviews/` - per-intent
  `@AssistantIntent(schema:)` annotations
- `Sources/HarnessMonitorIntents/Entities/PullRequestEntity.swift` - may
  need an `@AssistantEntity(schema:)` conformance to match
- `Sources/HarnessMonitorIntents/Entities/TaskBoardItemEntity.swift` -
  same
- This file - flip the status line and document the schema picks
