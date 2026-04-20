# Sandbox-compliant file access (sub-project A)

## Background

Harness Monitor ships as a sandboxed macOS app. Today it reaches outside-container state through two mechanisms:

- `com.apple.security.application-groups` on `Q498EB36N4.io.harnessmonitor` (app + daemon both hold it) - used for the daemon manifest, SQLite DB, lockfile, and `codex-endpoint.json`.
- `com.apple.security.temporary-exception.files.home-relative-path.read-write` on the daemon only, for `~/Library/Application Support/harness/` - where session state, agent signals, and project registries live.

Neither mechanism lets the app reach user-picked directories such as a Kuma or Harness checkout. IDEs typically have unrestricted FS access because they ship unsandboxed (Xcode, VS Code). We want IDE-like reach while staying sandboxed, using the model that BBEdit / CotEditor / Nova use: user-selected entitlements plus security-scoped bookmarks.

The temporary-exception entitlement is scrutinized by App Store review and is a long-term liability. This spec also removes it.

## Goals

1. Let the user authorize arbitrary project directories (Kuma, Harness, other checkouts) for read-write access. Access persists across launches.
2. Share authorized access between the Swift app and the Rust daemon that runs under `SMAppService`.
3. Replace the daemon's `temporary-exception.files.home-relative-path.read-write` with a clean design.
4. Leave a foundation that sub-projects C (session creation UI) and D (external session discovery) can consume without further entitlement work.

## Non-goals

- Creating worktrees, shared directories, or any per-session layout. That is sub-project B.
- Building session-creation UI or external-session attach flows. Those are C and D.
- Letting the user pick individual files. Folder-level access only; folders give recursive access to their subtree.
- Supporting unsandboxed release builds. The app ships sandboxed.

## Key decisions

| Decision | Choice | Rationale |
| --- | --- | --- |
| Data root location | Move to app group container: `~/Library/Group Containers/Q498EB36N4.io.harnessmonitor/harness/` | Eliminates the need for a data-root bookmark. App and daemon both have `application-groups` already; CLI (unsandboxed) reads the same path directly. |
| Migration from old data root | Silent on first run | User confirmed. Old path exists at `~/Library/Application Support/harness/`. If new path is empty and old has data, move. |
| Bookmark persistence format | Typed JSON in the app group container | Cross-process readable (Swift + Rust). Schema versioned. Easier to audit than UserDefaults binary plist. |
| Rust FFI | `security-framework` crate | Maintained, safe bindings. Avoids owning raw `extern "C"` CFURL bindings. |
| Daemon resolver gate | `HARNESS_SANDBOXED=1` env var | Matches existing gate pattern. Dev-mode daemon skips resolution (already has unrestricted FS). |
| Bookmark scope | App-scope only for Sub-project A | Document-scope reserved for drag-drop / Open Recent in later sub-projects. Entitlement added now to avoid a re-sign later. |
| FS access wrapping | Closure-based RAII extension on `URL` | Guarantees balanced start/stop even on throw. No bare `startAccessingSecurityScopedResource` sites remain. |

## Architecture

```
Swift app process                                  Rust daemon process
┌──────────────────────────────────┐              ┌──────────────────────────────────┐
│ SwiftUI .fileImporter            │              │                                  │
│         │                        │              │                                  │
│         ▼                        │              │                                  │
│ BookmarkStore (actor)            │              │ BookmarkResolver module          │
│  - load/save bookmarks.json      │◄── shared ──►│  - reads bookmarks.json          │
│  - MRU ordering                  │   JSON file  │  - security-framework crate      │
│  - stale-bookmark refresh        │              │  - gated on HARNESS_SANDBOXED=1  │
│         │                        │              │         │                        │
│         ▼                        │              │         ▼                        │
│ URL.withSecurityScope closure    │              │ BookmarkScope RAII struct        │
│         │                        │              │         │                        │
│         ▼                        │              │         ▼                        │
│ FileManager / NSFileCoordinator  │              │ std::fs / tokio::fs             │
└──────────────────────────────────┘              └──────────────────────────────────┘

                  App group container
                  ~/Library/Group Containers/Q498EB36N4.io.harnessmonitor/
                  ├── harness/              (new data root)
                  │   ├── daemon/
                  │   │   ├── manifest.json
                  │   │   ├── harness.db
                  │   │   └── codex-endpoint.json
                  │   ├── projects/
                  │   └── ... (moved from ~/Library/Application Support/harness/)
                  └── sandbox/
                      └── bookmarks.json    (authorized folders)
```

## Components

### 1. Entitlements

**`HarnessMonitor.entitlements`** (app) - add:

```xml
<key>com.apple.security.files.user-selected.read-write</key><true/>
<key>com.apple.security.files.bookmarks.app-scope</key><true/>
<key>com.apple.security.files.bookmarks.document-scope</key><true/>
```

**`HarnessMonitorDaemon.entitlements`** (daemon) - add and remove:

```diff
+ <key>com.apple.security.files.bookmarks.app-scope</key>
+ <true/>
- <key>com.apple.security.temporary-exception.files.home-relative-path.read-write</key>
- <array><string>/Library/Application Support/harness/</string></array>
```

**`HarnessMonitorUITestHost.entitlements`** - mirror the app additions so UI tests can exercise the folder picker.

**`HarnessMonitorPreviewHost.entitlements`** - unchanged; previews do not touch FS bookmarks.

Privacy manifest (`Resources/PrivacyInfo.xcprivacy`) already declares file timestamp access. No change.

### 2. Data root relocation

Rust `harness_data_root()` resolution order becomes:

1. `HARNESS_DATA_ROOT` env var (unchanged).
2. On macOS, if `~/Library/Group Containers/Q498EB36N4.io.harnessmonitor/` exists: return `<group>/harness/`.
3. Fall back to XDG (`~/.local/share/harness/` on non-macOS; `~/Library/Application Support/harness/` was the previous macOS default and is now the migration source only).

The app group container is created by the system when either the Monitor app or the sandboxed daemon is installed. CLI-only users without the Monitor app keep using XDG. Mixed users - Monitor installed, CLI occasionally invoked - both point at the app group container.

Migration lives in `src/bootstrap/data_root_migration.rs`:

- Runs once on daemon startup and once on CLI startup per binary.
- If new path is absent or empty AND `~/Library/Application Support/harness/` has content: rename (same-volume fast path) or copy-then-delete (cross-volume). Atomic enough that a crash mid-migration leaves both paths in a recoverable state.
- If both new and old paths have content: new wins, old is left alone, `warn!` is emitted with both paths so support can diagnose the split state. No automatic merge (would risk data divergence).
- Writes a `.migrated-from` marker at the new path with the old path and timestamp so support can diagnose later.
- Idempotent - a second run finds the marker and does nothing.
- Tracing: `info!` for success, `warn!` on partial state.

No user confirmation. Consented in this spec.

### 3. BookmarkStore (Swift)

Location: `Sources/HarnessMonitorKit/Sandbox/BookmarkStore.swift` (new module).

```swift
public actor BookmarkStore {
    public struct Record: Codable, Sendable, Identifiable {
        public enum Kind: String, Codable, Sendable {
            case projectRoot = "project-root"
            case sessionDirectory = "session-directory"
        }
        public let id: String
        public var kind: Kind
        public var displayName: String
        public var lastResolvedPath: String
        public var bookmarkData: Data
        public var createdAt: Date
        public var lastAccessedAt: Date
        public var staleCount: Int
    }

    public static let mruCap = 20

    public init(containerURL: URL)

    public func all() -> [Record]
    public func add(url: URL, kind: Record.Kind) throws -> Record
    public func remove(id: String)
    public func touch(id: String)
    public func resolve(id: String) throws -> ResolvedScope
    public func refreshStale(id: String, resolved: URL) throws
}

public struct ResolvedScope: Sendable {
    public let url: URL
    public let isStale: Bool
}
```

Persistence:

- File: `<group-container>/sandbox/bookmarks.json`
- Atomic writes via `Data.write(to:options:[.atomic])`
- Schema versioned; unknown future versions refuse to load and surface an `.unsupportedSchemaVersion` error to the caller. The UI renders a recoverable banner ("Your bookmarks file was written by a newer build; please upgrade or remove `bookmarks.json`") rather than silently wiping the file.

Access API: consumers call `resolve(id:)` which returns a `ResolvedScope`. The caller is responsible for invoking `url.withSecurityScope { ... }` around I/O. Resolving does NOT implicitly start the scope - that belongs at the call site so scope lifetime matches I/O lifetime.

Stale handling: when `URL(resolvingBookmarkData:...)` returns `isStale == true`, `resolve` records `staleCount += 1` and surfaces the resolved URL; the caller can optionally regenerate by calling `refreshStale(id:resolved:)` with a fresh bookmark from the resolved URL. If resolution fails with `NSFileReadUnknownError`, the record is marked unresolvable (UI shows "Reconnect" action that re-prompts the picker).

### 4. URL security-scope helper

Location: `Sources/HarnessMonitorKit/Sandbox/URL+SecurityScope.swift`.

```swift
public extension URL {
    func withSecurityScope<T>(_ body: (URL) throws -> T) rethrows -> T {
        let started = startAccessingSecurityScopedResource()
        defer { if started { stopAccessingSecurityScopedResource() } }
        return try body(self)
    }

    func withSecurityScope<T>(_ body: (URL) async throws -> T) async rethrows -> T {
        let started = startAccessingSecurityScopedResource()
        defer { if started { stopAccessingSecurityScopedResource() } }
        return try await body(self)
    }
}
```

Swift lint rule: forbid `startAccessingSecurityScopedResource` at source sites other than this file. Enforced via `.swiftlint.yml` custom rule.

### 5. Swift FS audit + wrapping

Every call site that touches a path outside the app's container and outside the app group container must either:

1. Be migrated to the app group container (app-owned data), or
2. Go through a `BookmarkStore` record + `withSecurityScope`.

Current inventory (to be updated during implementation):

| File | Operation | Action |
| --- | --- | --- |
| `HarnessMonitorKit/Support/HarnessMonitorPaths.swift` | Resolves `~/Library/Application Support/harness/` | Switch to app group container path. |
| `HarnessMonitorKit/API/DaemonController+ManifestLoading.swift` | Reads `manifest.json`, token attributes | Path resolves via new data root (app group). No bookmark needed. |
| (any others found during the sweep) | - | Audit spreadsheet added to the plan doc. |

The sweep runs as a dedicated plan step and produces an exhaustive list. The spec commits to "every outside-sandbox read is either app-group-direct or bookmark-mediated" and the final audit in the plan artifact proves compliance.

### 6. Folder picker + "Open Folder…" command

- New menu item under File: "Open Folder…" with `⌘⇧O` shortcut.
- Opens an `NSOpenPanel` via SwiftUI `.fileImporter(isPresented:allowedContentTypes:)` with `canChooseDirectories = true`, `canChooseFiles = false`, `allowsMultipleSelection = false`.
- On selection: creates an app-scope bookmark, inserts into `BookmarkStore` with `kind = .projectRoot`.
- Success feedback: toast "Added kuma to authorized folders."

### 7. Authorized Folders preferences pane

- New settings section in `PreferencesView`.
- Shows `BookmarkStore.all()` as a list (display name, last-resolved path, last-accessed date, stale indicator).
- Row actions: Reveal in Finder, Re-authorize, Remove.
- "Add Folder…" button at the top re-uses the Open Folder… flow.
- Target rows have accessibility identifiers for UI tests.

### 8. Rust BookmarkResolver

Location: `src/sandbox/bookmarks.rs` (new module).

```rust
#[cfg(target_os = "macos")]
pub struct ResolvedBookmark {
    pub path: PathBuf,
    pub is_stale: bool,
    scope: BookmarkScope,
}

#[cfg(target_os = "macos")]
pub struct BookmarkScope { /* holds CFURL, releases on Drop */ }

#[cfg(target_os = "macos")]
pub fn resolve(bytes: &[u8]) -> Result<ResolvedBookmark, BookmarkError>;

#[cfg(target_os = "macos")]
pub fn is_sandboxed() -> bool {
    std::env::var_os("HARNESS_SANDBOXED").is_some()
}
```

Depends on `security-framework = "3"` (or current major). Uses `kCFURLBookmarkResolutionWithSecurityScope | kCFURLBookmarkResolutionWithoutUI`. `BookmarkScope::Drop` calls `CFURLStopAccessingSecurityScopedResource` to prevent sandbox extension leaks.

Callers that currently read user-picked paths (there are none yet in A - consumers come in C and D) first check `is_sandboxed()` and skip resolution when false.

### 9. Gated entitlement for daemon

The daemon only needs `com.apple.security.files.bookmarks.app-scope` to resolve bookmarks the app created and stored in the shared app group JSON. No `user-selected.*` entitlement on the daemon - it never picks files.

After the data-root migration lands, the `temporary-exception` entitlement is removed in the same commit that cuts over the path resolution. A CI validation step runs `codesign --display --entitlements :- <app>` and fails if the exception is present.

### 10. Observability

- Swift: `os_log` category `sandbox` for add/remove/resolve events. Include bookmark `id`, not path.
- Rust: `tracing` with `target = "harness::sandbox"`. `info!` for successful resolve, `warn!` on stale, `error!` on unresolvable.
- Privacy: never log full paths at `info` level - log at `debug` only, redacted at `info`.

## Testing strategy

### Unit (Swift)

- `BookmarkStoreTests`: round-trip add → save → reload → resolve. Verify MRU cap evicts oldest. Verify stale refresh replaces bytes. Verify schema-version mismatch refuses to load.
- `URLSecurityScopeTests`: verify `withSecurityScope` balances start/stop even when body throws.

### Unit (Rust)

- `sandbox::bookmarks::tests`: on macOS only (`#[cfg(target_os = "macos")]`). Create a minimal bookmark from a known path via `security-framework`, resolve it, assert path round-trips. Assert `BookmarkScope::Drop` decrements the scope count (check via `CFURLStopAccessing…` return).
- `data_root_migration::tests`: fixture with old path populated + new path empty → after `migrate()`, new has data, marker present. Idempotent.

### Integration

- `tests/integration/sandbox/bookmark_share.rs`: write a bookmark JSON into a fake app group dir, invoke daemon startup flow, observe resolution succeeds under `HARNESS_SANDBOXED=1`.
- Swift UI test (`HarnessMonitorUITests/AuthorizedFoldersTests`): launch isolated UI host, invoke Open Folder… via keyboard shortcut with a temp directory argument injected through a test-only env var (the picker can be bypassed in UI tests by preseeding a record directly).

### Quality gates

- `cargo fmt --check && cargo clippy --lib -- -D warnings` clean.
- `mise run check` on Rust.
- `apps/harness-monitor-macos/Scripts/run-quality-gates.sh` for Swift.
- `codesign --display --entitlements :-` on built app + daemon, parsed to assert temporary-exception is gone and new entitlements are present.

## Rollout & risks

- **Risk: migration failure corrupts data.** Mitigation: copy-then-delete on cross-volume, rename on same-volume. Marker file records source for manual recovery. Test coverage for partial failures.
- **Risk: bookmark resolution silently breaks for user when macOS quarantine / reinstall invalidates a bookmark.** Mitigation: stale counter + UI Re-authorize action. Daemon logs at `warn` on unresolvable bookmarks.
- **Risk: daemon tries to resolve before app group bookmarks.json exists.** Mitigation: daemon treats missing file as empty store, no error.
- **Risk: app group container does not exist on first launch.** Mitigation: Swift app creates `<group>/harness/` and `<group>/sandbox/` during boot. Daemon creates them idempotently too.
- **Risk: security-framework major-version bump breaks FFI.** Mitigation: pin minor version in `Cargo.toml`. Integration test exercises the exact path.

## Execution order (for the plan)

1. Entitlements + privacy manifest + `codesign` validation in `run-quality-gates.sh`.
2. `URL.withSecurityScope` helper + unit tests (red → green).
3. `BookmarkStore` actor + schema + unit tests.
4. Rust `src/sandbox/bookmarks.rs` module + FFI + unit tests.
5. Data-root resolution change in `harness_data_root()` + migration module + Rust tests.
6. Daemon path references retargeted to new data root.
7. Daemon entitlement removal (temporary-exception out; bookmarks.app-scope in) + `codesign` assertion.
8. Swift FS audit sweep: inventory every outside-container read; wrap or move.
9. "Open Folder…" command + Authorized Folders preferences section.
10. UI test for picker flow + bookmark persistence.
11. Final cross-stack gate: both `mise run check` and `run-quality-gates.sh` green; clean codesign.

Each step lands as its own `-sS` signed commit. Version bump policy: the cumulative change is a **minor** bump (new capability, backward-compatible behavior for existing CLI users via migration).

## Out of scope / later

- Per-file bookmarks (individual files rather than folders). YAGNI for now.
- iCloud Drive or network-volume specifics.
- Multiple named bookmark profiles (e.g., per-user workspace sets). YAGNI.
- Granular read-only vs read-write at the UI level. All bookmarks are read-write.
- Sandbox escape for specific system directories (Desktop, Documents, Downloads) - these follow normal TCC prompts when the user picks them.

## Follow-ups (sub-projects C and D)

This spec covers sub-project **A** only. Two sibling sub-projects consume the infrastructure landed here and are planned to ship after A **and** B are merged:

- **Sub-project C - Session creation from the Monitor app.** Introduces the UI flow that lets the user pick a project root (via A's Open Folder…), name a session, and have the daemon create it (using B's worktree-per-session layout). Wires the `projectRoot` bookmark records into `POST /v1/sessions`. Requires A for the picker and bookmark resolution; requires B for the on-disk session layout. Will be brainstormed + spec'd + implemented as its own cycle after A and B land on main.
- **Sub-project D - External session discovery and attachment.** Introduces the UI flow that lets the user point at a directory containing a harness session started outside the Monitor (CLI or external tooling) and attach it. Uses the `sessionDirectory` bookmark kind (already reserved in A's `BookmarkStore.Record.Kind`). Requires A only. Also a separate brainstorm + spec + implement cycle, sequenced after A ships (can run in parallel with B or C).

Neither C nor D requires additional entitlements, additional bookmark-store fields, or additional daemon FFI - A's design is intentionally general enough for both. If a C/D implementation uncovers a gap, we extend A's schema with a backward-compatible v2 rather than rewriting.

## Open questions

None. Every design decision has a chosen value. Questions that emerge during implementation are resolved against this doc; if they require a new decision, we update the doc in the same PR.
