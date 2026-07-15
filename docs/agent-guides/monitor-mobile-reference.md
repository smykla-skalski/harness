# Harness Monitor mobile and watch reference

This is the canonical guide for the Harness Monitor companion surfaces: the iOS app (`HarnessMonitorMobile`), the watchOS app (`HarnessMonitorWatch`), their widget extensions, and the shared frameworks that connect them to the Mac (`HarnessMonitorCore`, `HarnessMonitorCrypto`, `HarnessMonitorCloudMirror`, `HarnessMonitorMacRelay`). The repo-root `AGENTS.md` and `apps/harness-monitor/AGENTS.md` still apply; this file adds the mobile/watch detail they point to.

The macOS app itself is covered by `apps/harness-monitor/AGENTS.md` and `monitor-reference.md`. Read those first for Tuist generation, lanes, daemon modes, and SwiftUI rules — the same build wrapper, lanes, signing, and SwiftUI conventions apply to every target in this project.

## Product shape

Harness Monitor on the phone and watch is a mobile control surface with two credential-driven transports:

1. A remote-daemon profile connects directly over pinned HTTPS. The phone or watch claims a one-time remote pairing invitation, stores the bearer credential in its own Keychain, fetches authenticated session snapshots, and executes role-scoped commands against daemon HTTP routes. The watch can also use the same direct path after the phone transfers its profile through WatchConnectivity.
2. A local-relay profile uses `HarnessMonitorMacRelay` and `HarnessMonitorCloudMirror`. The Mac redacts and encrypts a full snapshot, CloudKit carries only encrypted records plus routing metadata, and the phone/watch decrypt the mirror. Signed commands return through the same relay for the Mac to validate and execute.

When a credential has both transports, direct snapshot access is tried first. CloudMirror snapshot fallback is used only for reachability/TLS failures or remote 5xx responses; remote `401` and `403` responses fail closed. Commands use direct execution whenever the remote profile has write scope and never fall back after a direct attempt, avoiding duplicate side effects after an ambiguous network failure. A read-only direct profile may still use an independently configured CloudMirror command channel. Local-relay pairing still runs through the phone. Remote-daemon pairing can run on either the phone or watch.

## Target and framework map

All Apple targets live in `apps/harness-monitor/Project.swift`. Mobile and watch sources are globbed, so new Swift files in an existing target root need no manifest edit.

| Target | Product | Platforms | Bundle id | Purpose |
| --- | --- | --- | --- | --- |
| `HarnessMonitorCore` | static framework | mac, iOS, watch | `io.harnessmonitor.core` | Foundation-only shared models: `MobileMirrorSnapshot` and its sub-models, command models, notification models, live-activity models, the app-group `MobileSharedSnapshotStore`, demo fixtures, async timeout helper. No AppKit, no UIKit, no CloudKit, no SwiftData. |
| `HarnessMonitorCrypto` | static framework | mac, iOS, watch | `io.harnessmonitor.crypto` | AEAD cipher (`MobilePayloadCipher`), device identity + Keychain stores, paired-station credential + Keychain stores, the pairing handshake (`MobilePairing*`, invitation codec), and the phone-to-watch transfer bundle. CryptoKit + Security only. |
| `HarnessMonitorCloudMirror` | static framework | mac, iOS, watch | `io.harnessmonitor.cloudmirror` | The CloudKit transport: schema, record codec, live database, snapshot writer, command queue, subscription registrar, background refresher, privacy service, and the device-side `MobileCloudMirrorSyncClient`. Depends on Core + Crypto. |
| `HarnessMonitorMacRelay` | framework | mac only | `io.harnessmonitor.mac-relay` | The Mac side: `MobileMacRelayService`, the daemon-backed snapshot source, the command executor, the local-network pairing HTTP server, and the Mac-side identity/trust stores. Embedded in the macOS app. |
| `HarnessMonitorMobile` | app | iOS | `io.harnessmonitor.app.ios` | The iOS app ("Harness Monitor"). The shared `MirrorStore`, five-tab UI, QR pairing, command composer, live activity, notifications, and WatchConnectivity bridge. Embeds the watch app. |
| `HarnessMonitorMobileWidgets` | app extension | iOS | `io.harnessmonitor.app.ios.widgets` | iOS Home Screen widgets (needs-you, command queue, station health) plus the command Live Activity. |
| `HarnessMonitorWatch` | app | watchOS | `io.harnessmonitor.app.ios.watch` | The watchOS app. The watch-configured `MirrorStore`, root view, command composer, direct remote pairer, and pairing-transfer receiver. Embedded inside the iOS app. |
| `HarnessMonitorWatchWidgets` | app extension | watchOS | `io.harnessmonitor.app.ios.watch.widgets` | watchOS accessory complications: the legacy NeedsMe count plus the encrypted-mirror timeline. |
| `HarnessMonitorCloudKit` | static framework | mac, iOS, watch | `io.harnessmonitor.cloudkit` | The older, separate NeedsMe count path (`NeedsMeSnapshot`). Distinct from CloudMirror. See the "NeedsMe vs CloudMirror" section. |

The macOS app, the iOS app, and the watch app all share the same iCloud container, app group, and `MobileMirrorSnapshot` model. The strict separation of Core (Foundation-only) from everything platform-specific is what lets one snapshot model compile on all three OSes.

## End-to-end data flow

### Mac to device (snapshot)

`HarnessMonitorClientMobileMirrorSnapshotSource` (in `HarnessMonitorMacRelay`) pulls live state from the harness daemon client and assembles a `MobileMirrorSnapshot`: stations, sessions, reviews, task-board items, attention items, pending commands, a monotonic `revision`, and a `generatedAt` timestamp. Redaction happens at this boundary (`+Redaction`), so secret-bearing fields never enter the snapshot in cleartext.

`MobileMacRelayService.publishSnapshot()` runs the snapshot through a `MobileMirrorSecretRedactor`, folds in the current pending-command queue and per-station command counts, then writes it to the `MobileMirrorSnapshotSink`. The live sink (`MobileCloudMirrorRelaySnapshotSink`) encrypts the payload into a `MobileEncryptedEnvelope` and upserts it as a CloudKit record. Large snapshots are split into chunk records referenced by `chunkIDs`.

On a relay-paired device, `MobileCloudMirrorSyncClient.fetchLatestSnapshot(stationID:now:)` fetches the record(s), checks the `expiresAt` TTL (a stale record raises `MobileCloudMirrorSyncError.staleSnapshot`), decrypts and verifies the envelope with the per-station symmetric key, reassembles chunks, and returns a `MobileMirrorSnapshot`.

On a remote-paired device, `MobileRemoteDaemonSyncClient.fetchLatestSnapshot(stationID:now:)` sends authenticated requests through the pinned endpoint for sessions, active-session managed agents, task-board items, and the paired Reviews query. It maps terminal, Codex, and ACP agents into redacted mobile session details, including role-gated ACP permission and blocked-agent attention. A missing managed-agent or task-board route remains compatible with older servers; authentication failures fail closed, while reachability and server failures follow the CloudMirror fallback policy described above. The shared `MirrorStore.refresh()` aggregates every paired station through the same `MobileMonitorSyncClient` protocol.

### Device command paths

A command authored on the phone or watch is a `MobileCommandRecord` whose `kind` is one of a fixed `MobileCommandKind` set: resolve an ACP permission, start/stop/prompt an agent, dispatch a task or approve a task-board plan, approve/label/merge a pull request or rerun its checks, or a plain refresh. The device encrypts and signs it with the command-signing key established at pairing, then `MobileCloudMirrorSyncClient.queueCommand(_:currentRevision:now:)` writes it to the queue with the snapshot `revision` it was authored against (optimistic concurrency).

On the Mac, `MobileMacRelayService.executePendingCommands()` walks the pending queue. For each command it: validates the queue envelope (`validatingForQueue`), validates fresh state (`validatingFreshState` rejects a command whose authored revision no longer matches the current one), records an `accepted` then `running` receipt, runs the `MobileRelayCommandExecutor`, and records a terminal receipt (`succeeded`, `failed`, `expired`). Executor output is run back through the secret redactor. Receipts flow to the device through the same encrypted mirror, so the command tab reflects accepted → running → terminal transitions.

Commands are idempotent on the Mac: `executedCommandIDs` guards against re-running a command if a duplicate mirror pass sees it again before its terminal receipt has propagated.

For a write-scoped remote profile, `MobileRemoteDaemonSyncClient.queueCommand` executes the command immediately against the corresponding authenticated daemon route. ACP permission, task-board dispatch/plan approval, terminal/Codex/ACP start-stop-prompt, pull-request actions, and refresh scopes all use the same pinned URLSession and per-client bearer headers as snapshots. Stop and prompt first resolve the managed-agent kind so the client chooses the correct terminal, Codex, or ACP mutation. Review actions first resolve the referenced pull request through the daemon and build the mutation target from that fresh response; stale target IDs, policy flags, checks, and head SHA values from the mobile command are never trusted. A successful response becomes a terminal local receipt instead of a relay queue record, so no invented relay revision or cancellation window is needed.

Remote mutation requests are attributed to a token-free structured actor principal containing the authenticated client id, platform, role, and scopes. Caller-supplied actor values are replaced for both HTTP and WebSocket mutations, including review workflow requests that preserve local agent actors. Viewer/read-only profiles do not expose direct commands. Admin profiles retain write access before local scope expansion, while operator profiles require the returned `write` scope.

## Pairing

### Phone to Mac (local network)

The Mac runs `MobilePairingHTTPServer`, an `NWListener` bound to `127.0.0.1` (or a configured public endpoint) that serves a single `POST /pair` route. Starting it produces a `MobilePairingInvitation` carrying the endpoint, a one-shot `nonce`, and a TTL (default 300 seconds). The invitation is encoded as a `harness://` URL and rendered as a QR code in the macOS app's relay settings panel (`MobileRelayPairingSettingsPanel`).

The phone scans the QR with `MobilePairingScannerView` (VisionKit). `LiveMobileMonitorCredentialPairer` decodes the invitation, runs the handshake against the Mac over HTTP, and on success stores a `MobilePairedStationCredential` (per-station symmetric key + command-signing key id) in the Keychain, keyed to a `MobileDeviceIdentity` also held in the Keychain. The Mac records the device in its trusted-device store.

Because the handshake uses the local network, the iOS app surfaces a dedicated `localNetworkDenied` sync state: if iOS has blocked Local Network access the QR scan cannot reach the Mac, and the app deep-links the user to Settings to grant it.

### Phone to remote daemon (internet)

`harness-daemon remote pair create` produces a short-lived `harness://remote-pair` invitation containing the HTTPS endpoint, one-time code, requested role/scopes, expiry, and the daemon certificate's SPKI SHA-256 pin. The phone accepts the same QR, deep-link, and manual-entry flows as local pairing. `URLSessionMobileRemoteDaemonPairingTransport` claims `POST /v1/remote/pair/claim` through a pinning URLSession and binds the claim to a stable client id derived from the phone identity.

The daemon returns an opaque per-client bearer token. `MobileRemoteDaemonPairingCoordinator` stores it only inside the existing Keychain-backed `MobilePairedStationCredential`, together with the endpoint, client id, role/scopes, token hint, paired time, and SPKI pin. Invitation endpoints must be plain HTTPS origins with no credentials, query, fragment, or path.

### Watch to remote daemon (internet)

The watch accepts a `harness://remote-pair` value through the privacy-sensitive, single-line Remote Pairing form; the paired iPhone keyboard can paste the full invitation without typing it on the watch. The app also keeps an `onOpenURL` route for watchOS delivery contexts that forward its registered scheme, but direct pairing does not depend on Launch Services opening a custom URL. The form clears the one-time value before starting the claim. `LiveWatchRemoteDaemonCredentialPairer` delegates the claim to the same pinned transport and coordinator as the phone, but selects `MobileRemoteDaemonPairingDevice.watchOS`. That device profile uses a separate `default-watch-device` identity and a `watchos-` client id, so the daemon can audit and revoke the watch independently from the phone.

The direct watch credential takes precedence over an iPhone-transferred credential for the same station. `MobileWatchPairingTransfer.preservingLocallyPairedRemoteCredentials` reconciles each incoming transfer before it reaches the watch Keychain, retaining the watch-owned token and identity while still adding, rotating, and removing other phone-managed stations. The watch status section exposes a destructive removal action only for watch-owned profiles. Successful removal deletes the watch token and private identity, then immediately requests a fresh iPhone transfer as fallback.

### Phone to watch (WatchConnectivity)

After the phone pairs, `MobileWatchPairingSessionBridge` serializes the device identities, station credentials, and an optional latest snapshot into a `MobileWatchPairingTransfer` and pushes it to the watch over WatchConnectivity. It uses all three delivery mechanisms for resilience: `sendMessage` when reachable, plus `updateApplicationContext` and `transferUserInfo` for background delivery. The watch can also pull on demand by sending a request payload, which the bridge answers from its cached or stored pairings. Payloads are capped at 60 KB. On the watch, `WatchPairingSessionReceiver` reconciles the transfer with any direct watch-owned profile before writing credential/identity material into the watch Keychain. Relay credentials select CloudMirror; remote credentials select the pinned direct client.

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
- Remote TLS pinning. Remote pairing and snapshots require HTTPS and validate both platform trust and the invitation's SPKI SHA-256 pin. A mismatched or untrusted certificate fails the request.
- Remote bearer isolation. Each remote client has its own opaque token and client id. The token is persisted only in the device Keychain and redacted from debug descriptions. Authentication and authorization failures never trigger CloudMirror fallback.
- Secret redaction. The Mac redacts secrets twice: once while building the snapshot (`+Redaction`) and again on command-execution output, via `MobileMirrorSecretRedactor`. Redaction runs before encryption, so a key compromise still does not expose un-redacted secrets that were never put in the payload.
- Command integrity. CloudMirror commands are signed with a command-signing key distinct from the snapshot key, and the Mac rejects any command whose authored `revision` no longer matches current state. Direct commands use pinned TLS, per-client bearer authentication, route authorization, and authenticated actor rebinding; they execute immediately and never retry through CloudMirror after a direct mutation attempt.
- Direct trust is per device. A phone and a directly paired watch have separate `MobileDeviceIdentity`, client id, and bearer token values. An iPhone-transferred watch fallback intentionally mirrors the phone credential until the watch claims its own profile. Removing a direct watch profile deletes only its credential and identity, then asks the phone for that fallback again.
- Biometric gate. Both apps link `LocalAuthentication` to gate sensitive command actions behind Face ID / Touch ID / wrist-detection.
- Privacy controls. `MobileCloudMirrorPrivacyService` lets the user inventory and delete the records mirrored for their devices; the iOS Settings tab exposes this when at least one station is mirrored.

## iOS app structure

Entry point `HarnessMonitorMobileApp` installs a `MobileAppDelegate` (UIKit adaptor) and constructs a single `MirrorStore` with Keychain-backed identity and credential stores, the live pairer, and the WatchConnectivity bridge.

- State. `MirrorStore` is a `@MainActor @Observable` class holding the aggregate `snapshot`, `selectedStationID`, `syncStatus`, paired credentials, and notification settings. It builds one `MobileMonitorSyncClient` per paired station through a factory, selecting direct, CloudMirror, or direct-first-with-fallback from the credential. Its extensions split by concern: `+Sync` (refresh/pairing/unpair), `+Commands`, `+Privacy`, `+Internals`.
- Tabs. `MobileRootView` is a `TabView`: Today, Sessions, Reviews, Commands, Settings. `MobileRootTab` also parses `harness://` deep links to a tab.
- Sync status. `MobileMonitorSyncStatus` is the single source of UI truth for connection state: `unpaired`, `demo`, `pairing`, `syncing`, `live`, `stale`, `localNetworkDenied`, `paired`, `privacy`, and the command outcomes. Each case carries a title, subtitle, and SF Symbol.
- Demo mode. On by default in the Simulator (App Review and screenshots get `MobileDemoFixtures` data with no real Mac), off on device. Pairing a real Mac clears demo mode.
- Push + background. `MobileAppDelegate` registers for remote notifications and registers both the NeedsMe and CloudMirror CloudKit subscriptions. A silent push runs `MobileCloudMirrorBackgroundRefresher`, schedules notifications for what changed, posts a refresh request, and reloads widget timelines. It observes `CKAccountChanged` to invalidate and re-register subscriptions on iCloud sign-in/out.
- Notifications. Tapping a notification routes to the right tab and station via `MobileNotificationNavigation`. Categories map command-status notifications to the Commands tab.
- Live Activity. `MobileCommandLiveActivityCoordinator` drives a Dynamic Island / Lock Screen activity (ActivityKit) for a running command.
- Widgets. The iOS widget extension and the watch both read the app-group `MobileSharedSnapshotStore`, which the store persists on every applied snapshot, so widgets render the last known mirror without a network round-trip.

## Watch app structure

The watch app is a separate watchOS product embedded in the iOS app, not a macOS extension. It configures the shared `MirrorStore` with the watch profile and builds direct and/or CloudMirror clients from credentials claimed on-watch or transferred by the phone. `HarnessMonitorWatchApp` routes delivered remote pairing links, `WatchRemoteDaemonPairingView` handles in-app link entry, `RootView` and `WatchCommandComposerView` make up the UI, the shared store owns the refresh loop, and `WatchPairingSessionReceiver` ingests reconciled WatchConnectivity transfers.

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
- `HarnessMonitorMobileFoundationTests` — runs the five shared-framework test targets together with coverage: `HarnessMonitorCoreTests`, `HarnessMonitorMirrorStoreTests`, `HarnessMonitorCryptoTests`, `HarnessMonitorCloudMirrorTests`, and `HarnessMonitorMacRelayTests`. There are also per-framework test schemes.

Where the logic is tested: the iOS app and watch app targets have no unit tests of their own — they are thin SwiftUI shells over the shared frameworks. The behavior lives in (and is tested through) the five framework test targets, all of which run on the macOS destination. That is why the mobile/watch test gate is a macOS test run, not a Simulator run.

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

- Shared store, distinct profiles. iOS and watchOS both construct `MirrorStore`, but the watch uses `.watch` profile behavior and its own device identity. Changes to mirror handling belong in the shared store unless the behavior is app-specific.
- Core is Foundation-only on purpose. Do not add AppKit, UIKit, SwiftData, or CloudKit imports to `HarnessMonitorCore`; doing so breaks the watchOS build. CloudKit belongs in CloudMirror/CloudKit, UI belongs in the app targets.
- Re-link traps. `HarnessMonitorMacRelay` embeds Core/Crypto/CloudMirror as a dynamic framework; the MacRelay test target depends only on MacRelay and imports the rest transitively. Same pattern for Kit and CloudKit. Adding the embedded static products as direct test dependencies re-links them into the test bundle.
- Demo mode masks real failures. In the Simulator the iOS app is in demo mode by default, so a broken live sync path can look healthy. Test live paths on device or with demo mode forced off.
- Container coupling. NeedsMe and CloudMirror share `iCloud.io.harnessmonitor`. A CloudKit schema or account-state change can affect both the watch count complications and the full mirror at once.
- Local Network permission. The phone-to-Mac handshake needs iOS Local Network access. A denied permission is not a bug in the handshake; it is the `localNetworkDenied` state, recovered through Settings.
