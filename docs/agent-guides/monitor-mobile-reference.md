# Harness Monitor mobile and watch reference

This is the canonical guide for the Harness Monitor companion surfaces: the iOS app (`HarnessMonitorMobile`), the watchOS app (`HarnessMonitorWatch`), their widget extensions, and the shared frameworks that connect them to the Mac (`HarnessMonitorCore`, `HarnessMonitorCrypto`, `HarnessMonitorCloudMirror`, `HarnessMonitorMacRelay`). The repo-root `AGENTS.md` and `apps/harness-monitor/AGENTS.md` still apply; this file adds the mobile/watch detail they point to.

The macOS app itself is covered by `apps/harness-monitor/AGENTS.md` and `monitor-reference.md`. Read those first for Tuist generation, lanes, daemon modes, and SwiftUI rules — the same build wrapper, lanes, signing, and SwiftUI conventions apply to every target in this project.

## Product shape

Harness Monitor on the phone and watch is a read-mostly mirror of the Mac's live monitor state with a narrow, audited write path back. There is no direct phone-to-daemon connection over the internet. Everything flows through three stages:

1. The Mac (`HarnessMonitorMacRelay`, embedded in the macOS app) reads live state from the harness daemon, redacts secrets, encrypts a snapshot, and publishes it.
2. CloudKit (`HarnessMonitorCloudMirror`) carries opaque encrypted records between devices. Apple's servers only ever see ciphertext plus cleartext routing metadata.
3. The phone and watch fetch and decrypt the mirror, render it, and can queue signed commands that travel back the same way for the Mac to validate and execute.

The phone is the pairing hub. You pair a phone to a Mac once over the local network, then the phone hands the resulting trust material to the watch over WatchConnectivity. The watch never runs the local-network pairing handshake itself.

## Target and framework map

All Apple targets live in `apps/harness-monitor/Project.swift`. Mobile and watch sources are globbed, so new Swift files in an existing target root need no manifest edit.

| Target | Product | Platforms | Bundle id | Purpose |
| --- | --- | --- | --- | --- |
| `HarnessMonitorCore` | static framework | mac, iOS, watch | `io.harnessmonitor.core` | Foundation-only shared models: `MobileMirrorSnapshot` and its sub-models, command models, notification models, live-activity models, the app-group `MobileSharedSnapshotStore`, demo fixtures, async timeout helper. No AppKit, no UIKit, no CloudKit, no SwiftData. |
| `HarnessMonitorCrypto` | static framework | mac, iOS, watch | `io.harnessmonitor.crypto` | AEAD cipher (`MobilePayloadCipher`), device identity + Keychain stores, paired-station credential + Keychain stores, the pairing handshake (`MobilePairing*`, invitation codec), and the phone-to-watch transfer bundle. CryptoKit + Security only. |
| `HarnessMonitorCloudMirror` | static framework | mac, iOS, watch | `io.harnessmonitor.cloudmirror` | The CloudKit transport: schema, record codec, live database, snapshot writer, command queue, subscription registrar, background refresher, privacy service, and the device-side `MobileCloudMirrorSyncClient`. Depends on Core + Crypto. |
| `HarnessMonitorMacRelay` | framework | mac only | `io.harnessmonitor.mac-relay` | The Mac side: `MobileMacRelayService`, the daemon-backed snapshot source, the command executor, the local-network pairing HTTP server, and the Mac-side identity/trust stores. Embedded in the macOS app. |
| `HarnessMonitorMobile` | app | iOS | `io.harnessmonitor.app.ios` | The iOS app ("Harness Monitor"). `MobileMonitorStore`, the five-tab UI, QR pairing, command composer, live activity, notifications, and the WatchConnectivity bridge. Embeds the watch app. |
| `HarnessMonitorMobileWidgets` | app extension | iOS | `io.harnessmonitor.app.ios.widgets` | iOS Home Screen widgets (needs-you, command queue, station health) plus the command Live Activity. |
| `HarnessMonitorWatch` | app | watchOS | `io.harnessmonitor.app.ios.watch` | The watchOS app. `WatchMonitorStore`, root view, command composer, and the pairing-transfer receiver. Embedded inside the iOS app. |
| `HarnessMonitorWatchWidgets` | app extension | watchOS | `io.harnessmonitor.app.ios.watch.widgets` | watchOS accessory complications: the legacy NeedsMe count plus the encrypted-mirror timeline. |
| `HarnessMonitorCloudKit` | static framework | mac, iOS, watch | `io.harnessmonitor.cloudkit` | The older, separate NeedsMe count path (`NeedsMeSnapshot`). Distinct from CloudMirror. See the "NeedsMe vs CloudMirror" section. |

The macOS app, the iOS app, and the watch app all share the same iCloud container, app group, and `MobileMirrorSnapshot` model. The strict separation of Core (Foundation-only) from everything platform-specific is what lets one snapshot model compile on all three OSes.

## End-to-end data flow

### Mac to device (snapshot)

`HarnessMonitorClientMobileMirrorSnapshotSource` (in `HarnessMonitorMacRelay`) pulls live state from the harness daemon client and assembles a `MobileMirrorSnapshot`: stations, sessions, reviews, task-board items, attention items, pending commands, a monotonic `revision`, and a `generatedAt` timestamp. Redaction happens at this boundary (`+Redaction`), so secret-bearing fields never enter the snapshot in cleartext.

`MobileMacRelayService.publishSnapshot()` runs the snapshot through a `MobileMirrorSecretRedactor`, folds in the current pending-command queue and per-station command counts, then writes it to the `MobileMirrorSnapshotSink`. The live sink (`MobileCloudMirrorRelaySnapshotSink`) encrypts the payload into a `MobileEncryptedEnvelope` and upserts it as a CloudKit record. Large snapshots are split into chunk records referenced by `chunkIDs`.

On the device, `MobileCloudMirrorSyncClient.fetchLatestSnapshot(stationID:now:)` fetches the record(s), checks the `expiresAt` TTL (a stale record raises `MobileCloudMirrorSyncError.staleSnapshot`), decrypts and verifies the envelope with the per-station symmetric key, reassembles chunks, and returns a `MobileMirrorSnapshot`. The iOS `MobileMonitorStore.refresh()` aggregates across every paired station, merging each station's snapshot into one combined view via `mergingStationSnapshot`.

### Device to Mac (command)

A command authored on the phone or watch is a `MobileCommandRecord` whose `kind` is one of a fixed `MobileCommandKind` set: resolve an ACP permission, start/stop/prompt an agent, dispatch a task or approve a task-board plan, approve/label/merge a pull request or rerun its checks, or a plain refresh. The device encrypts and signs it with the command-signing key established at pairing, then `MobileCloudMirrorSyncClient.queueCommand(_:currentRevision:now:)` writes it to the queue with the snapshot `revision` it was authored against (optimistic concurrency).

On the Mac, `MobileMacRelayService.executePendingCommands()` walks the pending queue. For each command it: validates the queue envelope (`validatingForQueue`), validates fresh state (`validatingFreshState` rejects a command whose authored revision no longer matches the current one), records an `accepted` then `running` receipt, runs the `MobileRelayCommandExecutor`, and records a terminal receipt (`succeeded`, `failed`, `expired`). Executor output is run back through the secret redactor. Receipts flow to the device through the same encrypted mirror, so the command tab reflects accepted → running → terminal transitions.

Commands are idempotent on the Mac: `executedCommandIDs` guards against re-running a command if a duplicate mirror pass sees it again before its terminal receipt has propagated.

## Pairing

### Phone to Mac (local network)

The Mac runs `MobilePairingHTTPServer`, an `NWListener` bound to `127.0.0.1` (or a configured public endpoint) that serves a single `POST /pair` route. Starting it produces a `MobilePairingInvitation` carrying the endpoint, a one-shot `nonce`, and a TTL (default 300 seconds). The invitation is encoded as a `harness://` URL and rendered as a QR code in the macOS app's relay settings panel (`MobileRelayPairingSettingsPanel`).

The phone scans the QR with `MobilePairingScannerView` (VisionKit). `LiveMobileMonitorCredentialPairer` decodes the invitation, runs the handshake against the Mac over HTTP, and on success stores a `MobilePairedStationCredential` (per-station symmetric key + command-signing key id) in the Keychain, keyed to a `MobileDeviceIdentity` also held in the Keychain. The Mac records the device in its trusted-device store.

Because the handshake uses the local network, the iOS app surfaces a dedicated `localNetworkDenied` sync state: if iOS has blocked Local Network access the QR scan cannot reach the Mac, and the app deep-links the user to Settings to grant it.

### Phone to watch (WatchConnectivity)

The watch does not run the HTTP handshake. After the phone pairs, `MobileWatchPairingSessionBridge` serializes the device identities, station credentials, and an optional latest snapshot into a `MobileWatchPairingTransfer` and pushes it to the watch over WatchConnectivity. It uses all three delivery mechanisms for resilience: `sendMessage` when reachable, plus `updateApplicationContext` and `transferUserInfo` for background delivery. The watch can also pull on demand by sending a request payload, which the bridge answers from its cached or stored pairings. Payloads are capped at 60 KB. On the watch, `WatchPairingSessionReceiver` ingests the transfer and writes the same credential/identity material into the watch Keychain, so the watch can then talk to CloudMirror directly.

## CloudKit schema

CloudMirror uses the private database of the `iCloud.io.harnessmonitor` container — the same container as the NeedsMe path, but a different record type and zone.

- Container: `iCloud.io.harnessmonitor` (private database)
- Zone: `HarnessMonitorMirror` (custom zone, `MobileCloudMirrorSchema.zoneName`)
- Record type: `MobileMirrorRecord`
- Subscription: a zone subscription with id `mobile-mirror-zone-changes` for silent push

Each record carries cleartext routing/metadata fields and an encrypted envelope. The metadata is intentionally readable so the device can route, order, and expire records without decrypting; the envelope holds the actual payload.

| Field | Meaning |
| --- | --- |
| `mirrorRecordType` | which kind of mirror record this is (`MobileMirrorRecordType`) |
| `stationID` | which paired Mac this record belongs to |
| `schemaVersion` | mirror schema version for forward-compat |
| `revision` | monotonic snapshot revision (drives fresh-state command validation) |
| `updatedAt` | last write time; newest wins on fetch |
| `expiresAt` | TTL; a fetched record past this is treated as stale |
| `tombstone` | soft-delete marker |
| `chunkIDs` | record ids of payload chunks for oversized snapshots |
| `envelope*` | AEAD envelope: `algorithm`, `keyID`, `nonce`, `ciphertext`, `tag`, `envelopeAAD`, `envelopeCreatedAt` |

The CloudKit schema must be deployed to the Production environment before TestFlight or release builds can read or write these records; a missing record type surfaces as `MobileCloudMirrorCloudKitError.schemaUnavailable` and the code degrades gracefully (empty fetches, skipped writes) rather than crashing. Adding a field is a CloudKit Dashboard deploy, same as the NeedsMe path.

## Security model

- End-to-end encryption. Payloads are sealed with `MobilePayloadCipher` (AEAD) under a per-station symmetric key that exists only on the paired Mac and the devices it trusts. CloudKit never holds the key.
- Secret redaction. The Mac redacts secrets twice: once while building the snapshot (`+Redaction`) and again on command-execution output, via `MobileMirrorSecretRedactor`. Redaction runs before encryption, so a key compromise still does not expose un-redacted secrets that were never put in the payload.
- Command signing + fresh-state validation. Commands are signed with a command-signing key distinct from the snapshot key, and the Mac rejects any command whose authored `revision` no longer matches current state. This prevents a stale or replayed command from acting on a board that has moved on.
- Trust is per device. Each phone/watch has its own `MobileDeviceIdentity`; unpairing one device deletes only its credential and, if no sibling credential shares the identity, its identity too.
- Biometric gate. Both apps link `LocalAuthentication` to gate sensitive command actions behind Face ID / Touch ID / wrist-detection.
- Privacy controls. `MobileCloudMirrorPrivacyService` lets the user inventory and delete the records mirrored for their devices; the iOS Settings tab exposes this when at least one station is mirrored.

## iOS app structure

Entry point `HarnessMonitorMobileApp` installs a `MobileAppDelegate` (UIKit adaptor) and constructs a single `MobileMonitorStore` with Keychain-backed identity and credential stores, the live pairer, and the WatchConnectivity bridge.

- State. `MobileMonitorStore` is a `@MainActor @Observable` class holding the aggregate `snapshot`, `selectedStationID`, `syncStatus`, paired credentials, and notification settings. It builds one `MobileMonitorSyncClient` per paired station through a factory, so the live path and tests can swap transports. Its extensions split by concern: `+Sync` (refresh/pairing/unpair), `+Commands`, `+Privacy`, `+Internals`.
- Tabs. `MobileRootView` is a `TabView`: Today, Sessions, Reviews, Commands, Settings. `MobileRootTab` also parses `harness://` deep links to a tab.
- Sync status. `MobileMonitorSyncStatus` is the single source of UI truth for connection state: `unpaired`, `demo`, `pairing`, `syncing`, `live`, `stale`, `localNetworkDenied`, `paired`, `privacy`, and the command outcomes. Each case carries a title, subtitle, and SF Symbol.
- Demo mode. On by default in the Simulator (App Review and screenshots get `MobileDemoFixtures` data with no real Mac), off on device. Pairing a real Mac clears demo mode.
- Push + background. `MobileAppDelegate` registers for remote notifications and registers both the NeedsMe and CloudMirror CloudKit subscriptions. A silent push runs `MobileCloudMirrorBackgroundRefresher`, schedules notifications for what changed, posts a refresh request, and reloads widget timelines. It observes `CKAccountChanged` to invalidate and re-register subscriptions on iCloud sign-in/out.
- Notifications. Tapping a notification routes to the right tab and station via `MobileNotificationNavigation`. Categories map command-status notifications to the Commands tab.
- Live Activity. `MobileCommandLiveActivityCoordinator` drives a Dynamic Island / Lock Screen activity (ActivityKit) for a running command.
- Widgets. The iOS widget extension and the watch both read the app-group `MobileSharedSnapshotStore`, which the store persists on every applied snapshot, so widgets render the last known mirror without a network round-trip.

## Watch app structure

The watch app is a separate watchOS product embedded in the iOS app, not a macOS extension. It has its own `WatchMonitorStore` (do not confuse it with the iOS `MobileMonitorStore`) that builds `MobileCloudMirrorSyncClient`s directly from the credentials the phone transferred. `RootView`, `WatchCommandComposerView`, and `WatchMonitorStoreRefresh` make up the UI and refresh loop; `WatchPairingSessionReceiver` ingests the WatchConnectivity transfer.

### NeedsMe vs CloudMirror

The watch consumes two independent CloudKit data paths, and they must not be conflated:

- NeedsMe (`HarnessMonitorCloudKit`, record type `NeedsMeSnapshot`, singleton record `current`). The older, lightweight "how many things need me" count. It powers the `NeedsMeCount*` accessory complications. The Mac writes it via `NeedsMeCloudKitWriter`. This is the path documented in the `apps/harness-monitor/AGENTS.md` "Watch app and CloudKit" section.
- CloudMirror (`HarnessMonitorCloudMirror`, record type `MobileMirrorRecord`). The full encrypted snapshot and command queue, identical to what the phone uses. It powers the `WatchMirror*` widgets and the watch app's main content and command composer.

Both live in the `iCloud.io.harnessmonitor` container. The iOS app registers and invalidates both subscription services together.

Watch widget gotcha (still true): every widget root view on watchOS must call `.containerBackground(for: .widget)` (clear material is fine). Omitting it makes the system fail to render and fall back to the `exclamationmark.triangle` glyph. CloudKit errors instead render typed states (`icloud.slash`, `wifi.slash`).

## Build and test

There are no `mise` tasks for the mobile or watch targets. The `monitor:build`, `monitor:test`, `build-for-testing.sh`, and `test-swift.sh` paths hardcode `-scheme HarnessMonitor` and a macOS destination (`Scripts/lib/xcodebuild-destination.sh` only ever emits `platform=macOS`). They do not build the iOS or watch apps and do not run the mobile foundation tests. Use Xcode or an explicit `monitor:xcodebuild` invocation.

Shared schemes (in `Project.swift`):

- `HarnessMonitorMobile` — builds the iOS app + widgets + Core/Crypto/CloudMirror; run on an iOS Simulator or device.
- `HarnessMonitorWatch` — builds and runs the watch app on a watchOS Simulator or device.
- `HarnessMonitorMobileFoundationTests` — runs the four shared-framework test targets together with coverage: `HarnessMonitorCoreTests`, `HarnessMonitorCryptoTests`, `HarnessMonitorCloudMirrorTests`, `HarnessMonitorMacRelayTests`. There are also per-framework test schemes (`HarnessMonitorCryptoTests`, `HarnessMonitorCloudMirrorTests`, `HarnessMonitorMacRelayTests`).

Where the logic is tested: the iOS app and watch app targets have no unit tests of their own — they are thin SwiftUI shells over the shared frameworks. The behavior lives in (and is tested through) the four framework test targets, all of which run on the macOS destination. That is why the mobile/watch test gate is a macOS test run, not a Simulator run.

Run the shared-framework tests (macOS, no Simulator needed) through the xcodebuild lane wrapper from the repo root, in a dedicated build lane so you do not stomp the user's Cmd+R DerivedData:

```bash
HARNESS_MONITOR_BUILD_LANE=agent-<uuid> mise run monitor:xcodebuild -- \
  -workspace apps/harness-monitor/HarnessMonitor.xcworkspace \
  -scheme HarnessMonitorMobileFoundationTests \
  -destination "platform=macOS,arch=$(uname -m),name=My Mac" \
  test
```

Build the iOS app for the Simulator (override the destination, which otherwise defaults to macOS):

```bash
HARNESS_MONITOR_BUILD_LANE=agent-<uuid> mise run monitor:xcodebuild -- \
  -workspace apps/harness-monitor/HarnessMonitor.xcworkspace \
  -scheme HarnessMonitorMobile \
  -destination "generic/platform=iOS Simulator" \
  build
```

Swap the scheme to `HarnessMonitorWatch` and the destination to `generic/platform=watchOS Simulator` to build the watch app (a generic Simulator destination builds against the SDK without needing a specific booted device; name a concrete device only when you intend to run). All the lane, worktree, signing, and path-limited-commit rules from the root and app `AGENTS.md` apply unchanged.

## Gotchas

- Two stores, same prefix. `MobileMonitorStore` (iOS) and `WatchMonitorStore` (watchOS) are different types with overlapping shapes. Changes to mirror handling usually need to land in both, plus the shared client in CloudMirror.
- Core is Foundation-only on purpose. Do not add AppKit, UIKit, SwiftData, or CloudKit imports to `HarnessMonitorCore`; doing so breaks the watchOS build. CloudKit belongs in CloudMirror/CloudKit, UI belongs in the app targets.
- Re-link traps. `HarnessMonitorMacRelay` embeds Core/Crypto/CloudMirror as a dynamic framework; the MacRelay test target depends only on MacRelay and imports the rest transitively. Same pattern for Kit and CloudKit. Adding the embedded static products as direct test dependencies re-links them into the test bundle.
- Demo mode masks real failures. In the Simulator the iOS app is in demo mode by default, so a broken live sync path can look healthy. Test live paths on device or with demo mode forced off.
- Container coupling. NeedsMe and CloudMirror share `iCloud.io.harnessmonitor`. A CloudKit schema or account-state change can affect both the watch count complications and the full mirror at once.
- Local Network permission. The phone-to-Mac handshake needs iOS Local Network access. A denied permission is not a bug in the handshake; it is the `localNetworkDenied` state, recovered through Settings.
