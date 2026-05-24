# Changelog

All notable user-facing changes to harness and Harness Monitor are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [39.0.0] - 2026-05-24

### Added

- Apple Watch complication that shows the count of pull requests waiting on your review, backed by CloudKit private database. Renders in the circular, rectangular, and inline accessory families. Add it via the watch's Complications editor.
- Companion watchOS app (`io.harnessmonitor.app.watch`) and widget extension (`io.harnessmonitor.app.watch.widgets`). The app shows the current count and sync state.
- `HarnessMonitorCloudKit` shared framework. Foundation plus CloudKit only, runs on mac and appleWatch destinations, hosts the snapshot DTO, persistent cache, store, account-change observer, and per-state rendering rules.
- CloudKit push subscription on the watchOS app. When the Mac writes a new count and the Watch is reachable, the widget reloads its timeline without waiting for the 15-minute fallback poll.

### Changed

- Mac app writes the review count to its CloudKit private database whenever the value changes, debounced 5 seconds. The daemon's loopback binding is unchanged; the Watch never reaches the Mac directly.
- Project version set to `39.0.0` across `Cargo.toml`, Tuist build settings, and derived release info.

### Notes

- Mac is the writer, Watch is the reader, CloudKit is the relay. The Watch works over cellular and stays useful while the Mac is asleep or offline; the widget shows a "synced X ago" or "May be outdated" hint when the snapshot is more than an hour old.
- iCloud sign-in is required on both devices for the complication to populate. Signed-out state renders an "iCloud sign-in needed" badge instead of a count.
- Live verification on a paired Apple Watch is pending.
