# Swift FS audit (sub-project A, Task 11)

Inventory of every FS access site in the Swift codebase, classified by whether it stays
inside the app sandbox container, the app group container, or requires bookmark-mediated access.

Grep command used:

```
grep -rn "FileManager\|URL(fileURLWithPath:\|homeDirectoryForCurrentUser\|applicationSupportDirectory\|NSHomeDirectory" \
  apps/harness-monitor-macos/Sources/
```

Total raw hits: 49 lines across 25 files.

---

## Bucket 1: App sandbox container (no action)

| File | Line | Call | Notes |
| --- | --- | --- | --- |
| `HarnessMonitorAppConfiguration.swift` | 163 | `FileManager.default.temporaryDirectory` | Temp dir is sandboxed container when sandboxed; used for UI-test data root only |
| `DaemonController.swift` | 251 | `Bundle.main.bundleURL` | App bundle; always in-container |

## Bucket 2: App group container (no action; via containerURL(...))

| File | Line | Call | Notes |
| --- | --- | --- | --- |
| `Sandbox/SandboxPaths.swift` | 5 | `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)` | Direct group container resolution |
| `MCP/HarnessMonitorMCPPreferences.swift` | 53-64 | `fileManager.containerURL(forSecurityApplicationGroupIdentifier:)` | MCP socket path inside group container |
| `Sandbox/BookmarkStore.swift` | 23, 35, 137, 149, 151 | `FileManager.default.*` on `storeFile` | `storeFile` is rooted at `SandboxPaths.bookmarksFileURL(containerURL:)` - group container |
| `Persistence/HarnessMonitorModelContainer.swift` | 10, 15 | `FileManager.default.createDirectory` / `HarnessMonitorPaths.cacheStoreURL` | Routed via `harnessRoot()` - group container after Task 11 |
| `Support/HarnessMonitorNotificationAssets.swift` | 24-28 | `FileManager.default.*` on `HarnessMonitorPaths.harnessRoot()` | Group-rooted after Task 11 |
| `Support/HarnessMonitorObservabilityConfig.swift` | 147 | `FileManager.default.fileExists` on `HarnessMonitorPaths.sharedObservabilityConfigURL` | Config URL; observability root is app-support fallback (see Bucket 4) |
| `Support/HarnessMonitorTelemetry+BufferedExporters.swift` | 82, 94 | `FileManager.default.createDirectory` on `HarnessMonitorPaths.harnessRoot()` | Group-rooted after Task 11 |
| `Support/HarnessMonitorTelemetry+HTTPClient.swift` | 17 | `FileManager.default.attributesOfItem` on SwiftData store paths | Paths sourced from `HarnessMonitorPaths.harnessRoot()` - group-rooted |
| `Stores/HarnessMonitorStore+Streaming.swift` | 269, 278 | `FileManager.default.*` on `manifestURL` | `manifestURL` from `HarnessMonitorPaths.manifestURL()` - group-rooted |
| `Stores/HarnessMonitorStore+BridgeControl.swift` | 76-80 | `FileManager.default.*` on `manifestURL` | Same as above |
| `Stores/HarnessMonitorStore+Database.swift` | 213 | `FileManager.default.attributesOfItem` on SwiftData store paths | Paths sourced from `HarnessMonitorPaths.harnessRoot()` - group-rooted |
| `API/DaemonController+WarmUpManagedLaunchAgent.swift` | 52, 62, 79 | `FileManager.default.*` on `HarnessMonitorPaths.managedLaunchAgentBundleStampURL` | Group-rooted via `daemonRoot()` |
| `API/ManifestWatcher.swift` | 156-160 | `FileManager.default.*` on `manifestPath` | Derived from `HarnessMonitorPaths.manifestURL()` - group-rooted |
| `API/DaemonController+ManifestLoading.swift` | 12, 16, 71 | `FileManager.default.*` on `manifestURL` | Group-rooted |
| `HarnessMonitorUIPreviewable/Support/BackgroundThumbnailCache+DiskCache.swift` | 19-20, 62, 90, 93, 100, 103 | `FileManager.default.*` on `cacheDirectory` | `cacheDirectory` defaults to `HarnessMonitorPaths.thumbnailCacheRoot()` - group-rooted |
| `HarnessMonitorUIPreviewable/Support/BackgroundThumbnailCache+ImageProcessing.swift` | 78 | `FileManager.default.attributesOfItem` on `path` | Path is a disk-cache entry under `cacheDirectory` - group-rooted |

## Bucket 3: Outside sandbox - migrated to app group (Task 11 action)

| File | Line | Call | Notes |
| --- | --- | --- | --- |
| `Support/HarnessMonitorPaths.swift` | 102-146 | `harnessRoot()` delegated to `dataRoot()` which had a `DaemonOwnership.external` bypass returning `~/Library/Application Support` | Rewritten to use shared `resolveBaseRoot(using:preferExternalDaemon:)` helper; external-daemon bypass is PRESERVED symmetrically (same ordering as `dataRoot`); managed builds fatalError when group container is unavailable instead of silently falling back to a sandbox-denied path |

## Bucket 4: Outside sandbox - bookmark-mediated (deferred to C/D consumers)

| File | Line | Call | Notes |
| --- | --- | --- | --- |
| `Support/HarnessMonitorPaths.swift` | 9 | `FileManager.default.homeDirectoryForCurrentUser` in `HarnessMonitorEnvironment.init` | Injected dependency for testing; not a direct FS operation by the app |
| `Support/HarnessMonitorPaths.swift` | 90, 96 | `URL(fileURLWithPath: daemonDataHomeValue/xdgDataHomeValue)` | Dev env-var overrides (`HARNESS_DAEMON_DATA_HOME`, `XDG_DATA_HOME`); non-sandboxed dev mode only |
| `Support/HarnessMonitorPaths.swift` | `sharedObservabilityRoot` | `environment.homeDirectory/Library/Application Support` fallback | Reads observability config written by the Rust daemon outside the container; deferred to sub-project C/D bookmark handshake |
| `HarnessMonitorUIPreviewable/Theme/HarnessMonitorFormatters.swift` | 233 | `FileManager.default.homeDirectoryForCurrentUser` | Display-only path abbreviation for UI; no file I/O |
| `HarnessMonitorUIPreviewable/Theme/HarnessMonitorThemeMode.swift` | 102, 165 | `FileManager.default.contentsOfDirectory` / `fileExists` on `/System/Library/Desktop Pictures` | System read-only directory; no user data; security-validated before use |
| `HarnessMonitorUIPreviewable/Support/BackgroundThumbnailCache.swift` | 157, 185, 200, 221 | `URL(fileURLWithPath: wallpaper.imagePath)` / `FileManager.default.attributesOfItem` | Source images from `/System/Library/` - validated against `allowedPathPrefixes`; user-picked wallpaper paths will need bookmark wrap (sub-project C) |
| `HarnessMonitorUIPreviewable/Views/AgentTuiWindowView+Actions.swift` | 222 | `URL(fileURLWithPath: tui.transcriptPath)` passed to `NSWorkspace.activateFileViewerSelecting` | Transcript path from daemon; Finder reveal requires security-scoped bookmark when sandboxed; deferred to sub-project C |
| `HarnessMonitorKit/Models/DaemonModels.swift` | 281 | `URL(fileURLWithPath: daemonRoot)` | Decode-time path construction from daemon JSON; display/routing only, no I/O here |
| `HarnessMonitorKit/Models/HarnessMonitorSessionModels.swift` | 175 | `URL(fileURLWithPath: checkoutRoot).lastPathComponent` | Display-only; no I/O |
| `API/DaemonController+ManifestLoading.swift` | 56 | `URL(fileURLWithPath: path).standardizedFileURL` for auth token | Token path provided by daemon manifest; deferred to sub-project D auth handshake |

## Summary

- Total FS access sites: 49 grep hits (25 files)
- Migrated to app group in this task: 1 (`harnessRoot()` now routes through `resolveBaseRoot` which always prefers the group container; external-daemon bypass preserved symmetrically with `dataRoot`)
- Remaining bookmark-mediated sites: 10 (handled by sub-projects C and D)
- No per-site wraps added in this task - all app-owned data paths resolve via the updated `harnessRoot()` and need no individual changes
