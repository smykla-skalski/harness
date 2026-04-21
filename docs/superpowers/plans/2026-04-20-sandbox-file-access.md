# Sandbox-compliant file access - Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `docs/superpowers/specs/2026-04-20-sandbox-file-access-design.md`

**Goal:** Let the sandboxed Monitor app reach arbitrary user-picked folders via security-scoped bookmarks, move app-owned data into the app group container, and remove the daemon's `temporary-exception` entitlement.

**Architecture:** Swift creates app-scope bookmarks via `.fileImporter`, persists them as typed JSON in the shared app-group container. Rust daemon resolves the same bookmarks via the `security-framework` crate, gated on `HARNESS_SANDBOXED=1`. Every filesystem access site wraps resolution in `URL.withSecurityScope { ... }` or `URL.withSecurityScopeAsync { ... }` (Swift) or a `BookmarkScope` RAII guard (Rust). App-owned data migrates from `~/Library/Application Support/harness/` to the app-group-backed `harness_data_root()` on macOS via a silent one-shot migration.

**Tech stack:** Swift 6 (actors, async/await), SwiftUI (.fileImporter, Settings scene), Rust 2024 (clippy pedantic), `security-framework = "3"` crate, XcodeGen, SwiftLint.

**Version impact:** Minor bump (new capability, backward-compatible for users via migration). Bump `Cargo.toml` from current version to next minor at the end; run `mise run version:sync`.

---

## File structure

### New Swift files

| Path | Responsibility |
| --- | --- |
| `Sources/HarnessMonitorKit/Sandbox/URL+SecurityScope.swift` | `URL.withSecurityScope` + `URL.withSecurityScopeAsync` helpers |
| `Sources/HarnessMonitorKit/Sandbox/BookmarkRecord.swift` | `BookmarkStore.Record` / `PersistedStore`, `Kind` enum, schema version constant |
| `Sources/HarnessMonitorKit/Sandbox/BookmarkStore.swift` | `BookmarkStore` actor, persistence, MRU, stale auto-refresh |
| `Sources/HarnessMonitorKit/Sandbox/BookmarkStoreError.swift` | Typed errors (`.unsupportedSchemaVersion`, `.unresolvable`, `.ioError`) |
| `Sources/HarnessMonitorKit/Sandbox/SandboxPaths.swift` | `bookmarksFileURL`, app group root helpers |
| `Sources/HarnessMonitorUI/Views/Preferences/AuthorizedFoldersSection.swift` | Settings section with row list + actions |
| `Sources/HarnessMonitor/Commands/OpenFolderCommand.swift` | `CommandMenu` entry with ⌘⇧O + `.fileImporter` binding |
| `Tests/HarnessMonitorKitTests/Sandbox/URLSecurityScopeTests.swift` | Balance tests (throws, async) |
| `Tests/HarnessMonitorKitTests/Sandbox/BookmarkStoreTests.swift` | Round-trip, MRU, stale, schema-version |
| `Tests/HarnessMonitorUITests/AuthorizedFoldersTests.swift` | UI flow through Open Folder… to store |

### Modified Swift files

| Path | Change |
| --- | --- |
| `HarnessMonitor.entitlements` | Add `user-selected.read-write`, `bookmarks.app-scope`, `bookmarks.document-scope` |
| `HarnessMonitorDaemon.entitlements` | Add `bookmarks.app-scope`; remove `temporary-exception.files.home-relative-path.read-write` |
| `HarnessMonitorUITestHost.entitlements` | Mirror app additions |
| `project.yml` | Register new Swift sources with XcodeGen |
| `Sources/HarnessMonitorKit/Support/HarnessMonitorPaths.swift` | Use the current `resolveBaseRoot` precedence chain; managed builds fatalError if the group container is unavailable |
| `Sources/HarnessMonitorUI/Views/PreferencesView.swift` | Insert `AuthorizedFoldersSection` |
| `Sources/HarnessMonitor/HarnessMonitorApp.swift` | Register `OpenFolderCommand` in `.commands { ... }` |
| `.swiftlint.yml` | Custom rule forbidding `startAccessingSecurityScopedResource` outside the helper file |
| `Resources/PrivacyInfo.xcprivacy` | (review only - existing file timestamp entry covers bookmark I/O) |

### New Rust files

| Path | Responsibility |
| --- | --- |
| `src/sandbox/mod.rs` | Module root, public surface |
| `src/sandbox/bookmarks.rs` | `BookmarkRecord` struct, JSON load/save, MRU helpers |
| `src/sandbox/bookmarks/tests.rs` | Store round-trip tests |
| `src/sandbox/resolver.rs` | `resolve`, `BookmarkScope` RAII (macOS-only via cfg) |
| `src/sandbox/resolver/tests.rs` | FFI round-trip (`#[cfg(target_os = "macos")]`) |
| `src/sandbox/migration.rs` | Old-path → app-group one-shot migration (`run_startup_migration()`) |
| `src/sandbox/migration/tests.rs` | Fixture-based migration tests |
| `tests/integration/sandbox/bookmark_resolution.rs` | End-to-end Swift-written bookmark → Rust resolves |
| `tests/integration/sandbox/mod.rs` | Module root |

### Modified Rust files

| Path | Change |
| --- | --- |
| `Cargo.toml` | `security-framework = "3"` dependency, macOS-only cfg |
| `src/lib.rs` | Register `pub mod sandbox;` |
| `src/workspace/session.rs:15` (`data_root`) | `XDG_DATA_HOME` -> macOS `HARNESS_APP_GROUP_ID` group container -> `user_dirs::data_dir()` fallback |
| `src/workspace/paths.rs` | `harness_data_root()` appends `/harness`; legacy macOS root helper remains separate |
| `src/app/cli.rs` | Call `sandbox::migration::run_startup_migration()` early in CLI dispatch on macOS |
| `tests/integration/mod.rs` | Register new `sandbox` integration module |

### Modified scripts + config

| Path | Change |
| --- | --- |
| `apps/harness-monitor-macos/Scripts/run-quality-gates.sh` | Add `codesign --display --entitlements :-` assertion that `temporary-exception` is absent and new entitlements are present |
| `.gitignore` / `.git/info/exclude` | No change |

---

## Task 1: Add entitlements

**Files:**
- Modify: `apps/harness-monitor-macos/HarnessMonitor.entitlements`
- Modify: `apps/harness-monitor-macos/HarnessMonitorUITestHost.entitlements`
- Modify: `apps/harness-monitor-macos/HarnessMonitorDaemon.entitlements` (add only - remove happens in Task 10)

- [ ] **Step 1: Add three app-side entitlements**

Edit `HarnessMonitor.entitlements` - insert before closing `</dict>`:

```xml
	<key>com.apple.security.files.user-selected.read-write</key>
	<true/>
	<key>com.apple.security.files.bookmarks.app-scope</key>
	<true/>
	<key>com.apple.security.files.bookmarks.document-scope</key>
	<true/>
```

- [ ] **Step 2: Mirror on UI test host**

Edit `HarnessMonitorUITestHost.entitlements` - insert the same three keys before `</dict>`.

- [ ] **Step 3: Add bookmark resolution on daemon**

Edit `HarnessMonitorDaemon.entitlements` - insert before `</dict>`:

```xml
	<key>com.apple.security.files.bookmarks.app-scope</key>
	<true/>
```

Do NOT remove the `temporary-exception` key yet - Task 10 does that once all paths are migrated.

- [ ] **Step 4: Build + verify entitlements on built app**

Run from repo root:

```bash
xcodebuild -project 'apps/harness-monitor-macos/HarnessMonitor.xcodeproj' \
  -scheme HarnessMonitor -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath xcode-derived \
  -skipPackagePluginValidation build
```

Expected: build succeeds.

Verify the entitlements are embedded:

```bash
codesign --display --entitlements :- \
  xcode-derived/Build/Products/Debug/Harness\ Monitor.app 2>&1 \
  | grep -E "user-selected|bookmarks.app-scope|bookmarks.document-scope"
```

Expected: three lines, one per key.

- [ ] **Step 5: Commit**

```bash
git add apps/harness-monitor-macos/HarnessMonitor.entitlements \
        apps/harness-monitor-macos/HarnessMonitorUITestHost.entitlements \
        apps/harness-monitor-macos/HarnessMonitorDaemon.entitlements
git -c commit.gpgsign=true commit -sS -m "feat(sandbox): add bookmark entitlements"
```

---

## Task 2: URL security-scope helper + tests

**Files:**
- Create: `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Sandbox/URL+SecurityScope.swift`
- Create: `apps/harness-monitor-macos/Tests/HarnessMonitorKitTests/Sandbox/URLSecurityScopeTests.swift`
- Modify: `apps/harness-monitor-macos/project.yml` (register new sources)

- [ ] **Step 1: Write the failing test**

Create `URLSecurityScopeTests.swift`:

```swift
import XCTest
@testable import HarnessMonitorKit

final class URLSecurityScopeTests: XCTestCase {
    func testSyncBodyReceivesSameURL() throws {
        let tmp = FileManager.default.temporaryDirectory
        let received = try tmp.withSecurityScope { $0 }
        XCTAssertEqual(received, tmp)
    }

    func testSyncBodyStopsOnThrow() {
        struct Boom: Error {}
        let tmp = FileManager.default.temporaryDirectory
        XCTAssertThrowsError(
            try tmp.withSecurityScope { _ in throw Boom() }
        ) { error in
            XCTAssertTrue(error is Boom)
        }
    }

    func testAsyncBodyReceivesSameURL() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let received = try await tmp.withSecurityScopeAsync { $0 }
        XCTAssertEqual(received, tmp)
    }

    func testAsyncBodyStopsOnThrow() async {
        struct Boom: Error {}
        let tmp = FileManager.default.temporaryDirectory
        do {
            try await tmp.withSecurityScopeAsync { _ in throw Boom() }
            XCTFail("expected throw")
        } catch is Boom {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
```

- [ ] **Step 2: Register the new test + source in project.yml**

Edit `apps/harness-monitor-macos/project.yml` - the `HarnessMonitorKit` target already globs `Sources/HarnessMonitorKit/**/*.swift`; verify the glob includes `Sandbox/`. Tests target globs similarly - verify. If either needs an explicit include, add the path.

Regenerate:

```bash
apps/harness-monitor-macos/Scripts/generate-project.sh
```

- [ ] **Step 3: Run test to confirm it fails (red)**

```bash
xcodebuild -project 'apps/harness-monitor-macos/HarnessMonitor.xcodeproj' \
  -scheme HarnessMonitor -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath xcode-derived \
  -skipPackagePluginValidation test \
  -only-testing:HarnessMonitorKitTests/URLSecurityScopeTests
```

Expected: compile error ("Value of type 'URL' has no member 'withSecurityScope'").

- [ ] **Step 4: Implement the helper**

> **Deviation from the original sketch:** Swift 6 overload resolution picks the sync variant over the async variant when the closure is `{ $0 }` in an async context, generating spurious `await` warnings under warnings-as-errors. The async variant is named separately as `withSecurityScopeAsync` to avoid the ambiguity. Current async call sites already use `withSecurityScopeAsync`.

Create `URL+SecurityScope.swift`:

```swift
import Foundation

extension URL {
  /// Runs `body` with `startAccessingSecurityScopedResource` held for the
  /// duration of the call. The scope is released even when `body` throws.
  public func withSecurityScope<T>(_ body: (URL) throws -> T) rethrows -> T {
    let started = startAccessingSecurityScopedResource()
    defer { if started { stopAccessingSecurityScopedResource() } }
    return try body(self)
  }

  /// Async counterpart; separate name avoids Swift 6 overload ambiguity.
  public func withSecurityScopeAsync<T>(_ body: @Sendable (URL) async throws -> T) async rethrows -> T {
    let started = startAccessingSecurityScopedResource()
    defer { if started { stopAccessingSecurityScopedResource() } }
    return try await body(self)
  }
}
```

- [ ] **Step 5: Run test to confirm green**

Same xcodebuild command as step 3. Expected: 4/4 tests pass.

- [ ] **Step 6: SwiftLint custom rule to forbid raw usage**

Edit `.swiftlint.yml` - add under `custom_rules:`:

```yaml
  forbid_raw_security_scoped_resource:
    name: "Raw security-scoped resource access"
    regex: '\.startAccessingSecurityScopedResource\(\)'
    match_kinds:
      - identifier
    excluded:
      - "apps/harness-monitor-macos/Sources/HarnessMonitorKit/Sandbox/URL+SecurityScope.swift"
    message: "Use URL.withSecurityScope { ... } instead."
    severity: error
```

Run `apps/harness-monitor-macos/Scripts/run-quality-gates.sh`. Expected: green.

- [ ] **Step 7: Commit**

```bash
git add apps/harness-monitor-macos/Sources/HarnessMonitorKit/Sandbox/URL+SecurityScope.swift \
        apps/harness-monitor-macos/Tests/HarnessMonitorKitTests/Sandbox/URLSecurityScopeTests.swift \
        apps/harness-monitor-macos/project.yml \
        apps/harness-monitor-macos/HarnessMonitor.xcodeproj \
        .swiftlint.yml
git -c commit.gpgsign=true commit -sS -m "feat(sandbox): add URL security-scope helper"
```

---

## Task 3: BookmarkRecord + error types

**Files:**
- Create: `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Sandbox/BookmarkRecord.swift`
- Create: `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Sandbox/BookmarkStoreError.swift`

- [ ] **Step 1: Write the record + error types (no tests yet - consumed by Task 4)**

`BookmarkRecord.swift`:

```swift
import Foundation

public extension BookmarkStore {
    struct Record: Codable, Sendable, Identifiable, Equatable {
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

        public init(
            id: String = "B-" + UUID().uuidString.lowercased(),
            kind: Kind,
            displayName: String,
            lastResolvedPath: String,
            bookmarkData: Data,
            createdAt: Date = .now,
            lastAccessedAt: Date = .now,
            staleCount: Int = 0
        ) {
            self.id = id
            self.kind = kind
            self.displayName = displayName
            self.lastResolvedPath = lastResolvedPath
            self.bookmarkData = bookmarkData
            self.createdAt = createdAt
            self.lastAccessedAt = lastAccessedAt
            self.staleCount = staleCount
        }
    }

    struct PersistedStore: Codable, Sendable {
        public static let currentSchemaVersion: Int = 1
        public var schemaVersion: Int
        public var bookmarks: [Record]

        public init(schemaVersion: Int = Self.currentSchemaVersion, bookmarks: [Record] = []) {
            self.schemaVersion = schemaVersion
            self.bookmarks = bookmarks
        }
    }
}
```

`BookmarkStoreError.swift`:

```swift
import Foundation

public enum BookmarkStoreError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(found: Int, expected: Int)
    case unresolvable(id: String, underlying: String)
    case ioError(String)
    case notFound(id: String)
}
```

- [ ] **Step 2: Verify compilation**

```bash
xcodebuild -project 'apps/harness-monitor-macos/HarnessMonitor.xcodeproj' \
  -scheme HarnessMonitor -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath xcode-derived \
  -skipPackagePluginValidation build
```

Expected: types compile. The current codebase already has `BookmarkStore` in `BookmarkStore.swift`; this task record reflects the original plan, while the live implementation keeps `Record` / `PersistedStore` in `BookmarkRecord.swift` and `BookmarkStoreError` separate.

```swift
public actor BookmarkStore {}
```

Verify build succeeds.

- [ ] **Step 3: Commit**

```bash
git add apps/harness-monitor-macos/Sources/HarnessMonitorKit/Sandbox/BookmarkRecord.swift \
        apps/harness-monitor-macos/Sources/HarnessMonitorKit/Sandbox/BookmarkStoreError.swift
git -c commit.gpgsign=true commit -sS -m "feat(sandbox): add bookmark record types"
```

---

## Task 4: BookmarkStore actor + tests

Current code note: `BookmarkStore` already lives in `BookmarkStore.swift`. The live implementation also auto-refreshes stale bookmarks during `resolve(id:)` and persists through a temp file plus `FileManager.replaceItemAt(_:withItemAt:)`.

**Files:**
- Modify: `Sources/HarnessMonitorKit/Sandbox/BookmarkRecord.swift` (remove stub actor declaration in the original plan; the live actor already exists in `BookmarkStore.swift`)
- Create: `Sources/HarnessMonitorKit/Sandbox/BookmarkStore.swift`
- Create: `Sources/HarnessMonitorKit/Sandbox/SandboxPaths.swift`
- Create: `Tests/HarnessMonitorKitTests/Sandbox/BookmarkStoreTests.swift`

- [ ] **Step 1: Write failing tests first**

`BookmarkStoreTests.swift`:

```swift
import XCTest
@testable import HarnessMonitorKit

final class BookmarkStoreTests: XCTestCase {
    func testAddThenReloadRoundTrips() async throws {
        let dir = try makeTempDir()
        let store = BookmarkStore(containerURL: dir)
        let tmp = FileManager.default.temporaryDirectory

        let record = try await store.add(url: tmp, kind: .projectRoot)
        XCTAssertEqual(record.displayName, tmp.lastPathComponent)
        XCTAssertFalse(record.bookmarkData.isEmpty)

        let reloaded = BookmarkStore(containerURL: dir)
        let all = await reloaded.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, record.id)
    }

    func testMRUCapEvictsOldest() async throws {
        let dir = try makeTempDir()
        let store = BookmarkStore(containerURL: dir)
        let tmp = FileManager.default.temporaryDirectory

        for _ in 0..<(BookmarkStore.mruCap + 5) {
            _ = try await store.add(url: tmp, kind: .projectRoot)
        }
        let all = await store.all()
        XCTAssertEqual(all.count, BookmarkStore.mruCap)
    }

    func testUnsupportedSchemaVersionThrows() async throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("bookmarks.json")
        try Data(#"{"schemaVersion": 99, "bookmarks": []}"#.utf8).write(to: url)

        let store = BookmarkStore(containerURL: dir)
        do {
            _ = try await store.loadAndValidate()
            XCTFail("expected throw")
        } catch BookmarkStoreError.unsupportedSchemaVersion(let found, let expected) {
            XCTAssertEqual(found, 99)
            XCTAssertEqual(expected, BookmarkStore.PersistedStore.currentSchemaVersion)
        }
    }

    func testResolveReturnsScopedURL() async throws {
        let dir = try makeTempDir()
        let store = BookmarkStore(containerURL: dir)
        let tmp = FileManager.default.temporaryDirectory

        let record = try await store.add(url: tmp, kind: .projectRoot)
        let resolved = try await store.resolve(id: record.id)
        XCTAssertEqual(resolved.url.path, tmp.path)
        XCTAssertFalse(resolved.isStale)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookmarkStoreTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
```

- [ ] **Step 2: Run to confirm red**

```bash
xcodebuild ... test -only-testing:HarnessMonitorKitTests/BookmarkStoreTests
```

Expected: compile error - `BookmarkStore.mruCap`, `init(containerURL:)`, `add`, `all`, `resolve`, `loadAndValidate`, `ResolvedScope` missing.

- [ ] **Step 3: Implement SandboxPaths**

Create `SandboxPaths.swift`:

```swift
import Foundation

public enum SandboxPaths {
    public static func appGroupContainerURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: HarnessMonitorAppGroup.identifier
        )
    }

    public static func bookmarksFileURL(containerURL: URL) -> URL {
        containerURL.appendingPathComponent("sandbox", isDirectory: true)
            .appendingPathComponent("bookmarks.json")
    }
}
```

- [ ] **Step 4: Implement BookmarkStore**

Replace the stub `public actor BookmarkStore {}` in `BookmarkRecord.swift` by *removing* that line (and keeping the extension). Create `BookmarkStore.swift`:

```swift
import Foundation
import os

public actor BookmarkStore {
    public static let mruCap = 20
    public static let logger = Logger(subsystem: "io.harnessmonitor", category: "sandbox")

    public struct ResolvedScope: Sendable {
        public let url: URL
        public let isStale: Bool
    }

    private let storeFile: URL
    private var cached: PersistedStore?

    public init(containerURL: URL) {
        self.storeFile = SandboxPaths.bookmarksFileURL(containerURL: containerURL)
        try? FileManager.default.createDirectory(
            at: storeFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    public func all() -> [Record] {
        (try? loadAndValidate().bookmarks) ?? []
    }

    public func loadAndValidate() throws -> PersistedStore {
        if let cached { return cached }
        guard FileManager.default.fileExists(atPath: storeFile.path) else {
            let fresh = PersistedStore()
            cached = fresh
            return fresh
        }
        let data: Data
        do {
            data = try Data(contentsOf: storeFile)
        } catch {
            throw BookmarkStoreError.ioError(String(describing: error))
        }
        let decoded = try JSONDecoder.iso8601.decode(PersistedStore.self, from: data)
        if decoded.schemaVersion != PersistedStore.currentSchemaVersion {
            throw BookmarkStoreError.unsupportedSchemaVersion(
                found: decoded.schemaVersion,
                expected: PersistedStore.currentSchemaVersion
            )
        }
        cached = decoded
        return decoded
    }

    public func add(url: URL, kind: Record.Kind) throws -> Record {
        let bookmark = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var store = (try? loadAndValidate()) ?? PersistedStore()
        let record = Record(
            kind: kind,
            displayName: url.lastPathComponent,
            lastResolvedPath: url.path,
            bookmarkData: bookmark
        )
        store.bookmarks.insert(record, at: 0)
        if store.bookmarks.count > Self.mruCap {
            store.bookmarks.removeLast(store.bookmarks.count - Self.mruCap)
        }
        try save(store)
        return record
    }

    public func remove(id: String) throws {
        var store = (try? loadAndValidate()) ?? PersistedStore()
        store.bookmarks.removeAll { $0.id == id }
        try save(store)
    }

    public func touch(id: String) throws {
        var store = (try? loadAndValidate()) ?? PersistedStore()
        guard let idx = store.bookmarks.firstIndex(where: { $0.id == id }) else {
            throw BookmarkStoreError.notFound(id: id)
        }
        var rec = store.bookmarks.remove(at: idx)
        rec.lastAccessedAt = .now
        store.bookmarks.insert(rec, at: 0)
        try save(store)
    }

    public func resolve(id: String) throws -> ResolvedScope {
        var store = (try? loadAndValidate()) ?? PersistedStore()
        guard let idx = store.bookmarks.firstIndex(where: { $0.id == id }) else {
            throw BookmarkStoreError.notFound(id: id)
        }
        var record = store.bookmarks[idx]
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: record.bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw BookmarkStoreError.unresolvable(id: id, underlying: String(describing: error))
        }
        if isStale {
            record.staleCount += 1
            let refreshed = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            record.bookmarkData = refreshed
        }
        record.lastResolvedPath = url.path
        record.lastAccessedAt = .now
        store.bookmarks[idx] = record
        try save(store)
        return ResolvedScope(url: url, isStale: isStale)
    }

    private func save(_ store: PersistedStore) throws {
        let data = try JSONEncoder.iso8601Pretty.encode(store)
        try data.write(to: storeFile, options: .atomic)
        cached = store
    }
}

private extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

private extension JSONEncoder {
    static let iso8601Pretty: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
```

- [ ] **Step 5: Run tests to confirm green**

```bash
xcodebuild ... test -only-testing:HarnessMonitorKitTests/BookmarkStoreTests
```

Expected: 4/4 pass.

- [ ] **Step 6: Run quality gates**

```bash
apps/harness-monitor-macos/Scripts/run-quality-gates.sh
```

Expected: green (SwiftLint + swift-format clean).

- [ ] **Step 7: Commit**

```bash
git add apps/harness-monitor-macos/Sources/HarnessMonitorKit/Sandbox/ \
        apps/harness-monitor-macos/Tests/HarnessMonitorKitTests/Sandbox/BookmarkStoreTests.swift \
        apps/harness-monitor-macos/project.yml \
        apps/harness-monitor-macos/HarnessMonitor.xcodeproj
git -c commit.gpgsign=true commit -sS -m "feat(sandbox): add BookmarkStore actor"
```

---

## Task 5: Rust sandbox module skeleton + security-framework dep

**Files:**
- Modify: `Cargo.toml`
- Create: `src/sandbox/mod.rs`
- Create: `src/sandbox/bookmarks.rs`
- Create: `src/sandbox/bookmarks/tests.rs`
- Modify: `src/lib.rs`

- [ ] **Step 1: Add dependency**

Edit `Cargo.toml` - add under `[dependencies]`:

```toml
[target.'cfg(target_os = "macos")'.dependencies]
security-framework = "3"
core-foundation = "0.10"
```

- [ ] **Step 2: Write failing test**

Create `src/sandbox/bookmarks/tests.rs`:

```rust
use super::*;
use std::io::Write;
use tempfile::TempDir;

#[test]
fn round_trip_save_load() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("bookmarks.json");

    let store = PersistedStore {
        schema_version: PersistedStore::CURRENT_SCHEMA_VERSION,
        bookmarks: vec![Record {
            id: "B-test".into(),
            kind: Kind::ProjectRoot,
            display_name: "kuma".into(),
            last_resolved_path: "/tmp/kuma".into(),
            bookmark_data: vec![1, 2, 3],
            created_at: chrono::Utc::now(),
            last_accessed_at: chrono::Utc::now(),
            stale_count: 0,
        }],
    };
    save(&path, &store).unwrap();

    let loaded = load(&path).unwrap();
    assert_eq!(loaded.bookmarks.len(), 1);
    assert_eq!(loaded.bookmarks[0].id, "B-test");
}

#[test]
fn load_unsupported_schema_version_errors() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("bookmarks.json");
    let mut f = std::fs::File::create(&path).unwrap();
    f.write_all(br#"{"schemaVersion": 99, "bookmarks": []}"#).unwrap();

    let err = load(&path).unwrap_err();
    match err {
        BookmarkError::UnsupportedSchemaVersion { found, expected } => {
            assert_eq!(found, 99);
            assert_eq!(expected, PersistedStore::CURRENT_SCHEMA_VERSION);
        }
        _ => panic!("unexpected error: {err:?}"),
    }
}

#[test]
fn load_missing_file_returns_empty() {
    let dir = TempDir::new().unwrap();
    let loaded = load(&dir.path().join("absent.json")).unwrap();
    assert!(loaded.bookmarks.is_empty());
    assert_eq!(loaded.schema_version, PersistedStore::CURRENT_SCHEMA_VERSION);
}
```

- [ ] **Step 3: Register module**

Create `src/sandbox/mod.rs`:

```rust
//! Sandbox-related helpers: security-scoped bookmark persistence and resolution.
//!
//! On macOS the Monitor app writes bookmarks here; the daemon reads them and
//! resolves them via `security-framework` when `HARNESS_SANDBOXED=1`.

pub mod bookmarks;

#[cfg(target_os = "macos")]
pub mod resolver;

pub mod migration;
```

Edit `src/lib.rs` - add `pub mod sandbox;` in module declaration section.

- [ ] **Step 4: Implement bookmarks module**

Create `src/sandbox/bookmarks.rs`:

```rust
//! JSON-backed store of security-scoped bookmarks shared with the Swift app.

use std::fs;
use std::io;
use std::path::Path;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum Kind {
    ProjectRoot,
    SessionDirectory,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Record {
    pub id: String,
    pub kind: Kind,
    pub display_name: String,
    pub last_resolved_path: String,
    #[serde(with = "base64_bytes")]
    pub bookmark_data: Vec<u8>,
    pub created_at: DateTime<Utc>,
    pub last_accessed_at: DateTime<Utc>,
    pub stale_count: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PersistedStore {
    pub schema_version: u32,
    pub bookmarks: Vec<Record>,
}

impl PersistedStore {
    pub const CURRENT_SCHEMA_VERSION: u32 = 1;
}

#[derive(Debug, Error)]
pub enum BookmarkError {
    #[error("I/O: {0}")]
    Io(#[from] io::Error),
    #[error("JSON: {0}")]
    Json(#[from] serde_json::Error),
    #[error("unsupported bookmarks.json schema version: found {found}, expected {expected}")]
    UnsupportedSchemaVersion { found: u32, expected: u32 },
    #[error("bookmark id not found: {0}")]
    NotFound(String),
    #[cfg(target_os = "macos")]
    #[error("resolution failed: {0}")]
    Resolution(String),
}

pub fn load(path: &Path) -> Result<PersistedStore, BookmarkError> {
    if !path.exists() {
        return Ok(PersistedStore {
            schema_version: PersistedStore::CURRENT_SCHEMA_VERSION,
            bookmarks: Vec::new(),
        });
    }
    let bytes = fs::read(path)?;
    let store: PersistedStore = serde_json::from_slice(&bytes)?;
    if store.schema_version != PersistedStore::CURRENT_SCHEMA_VERSION {
        return Err(BookmarkError::UnsupportedSchemaVersion {
            found: store.schema_version,
            expected: PersistedStore::CURRENT_SCHEMA_VERSION,
        });
    }
    Ok(store)
}

pub fn save(path: &Path, store: &PersistedStore) -> Result<(), BookmarkError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let json = serde_json::to_vec_pretty(store)?;
    fs::write(path, json)?;
    Ok(())
}

pub fn find<'a>(store: &'a PersistedStore, id: &str) -> Option<&'a Record> {
    store.bookmarks.iter().find(|r| r.id == id)
}

mod base64_bytes {
    use base64::{engine::general_purpose::STANDARD, Engine as _};
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(bytes: &[u8], s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&STANDARD.encode(bytes))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<u8>, D::Error> {
        let raw = String::deserialize(d)?;
        STANDARD.decode(raw).map_err(serde::de::Error::custom)
    }
}

#[cfg(test)]
mod tests;
```

Add `base64 = "0.22"` to Cargo.toml dependencies if not present.

- [ ] **Step 5: Run tests to confirm green**

```bash
cargo test --lib sandbox::bookmarks
```

Expected: 3/3 pass.

- [ ] **Step 6: Run mise check**

```bash
mise run check
```

Expected: clippy + fmt + test green (zero warnings).

- [ ] **Step 7: Commit**

```bash
git add Cargo.toml Cargo.lock src/sandbox/ src/lib.rs
git -c commit.gpgsign=true commit -sS -m "feat(sandbox): add bookmark persistence"
```

---

## Task 6: Rust bookmark resolver (macOS FFI)

**Files:**
- Create: `src/sandbox/resolver.rs`
- Create: `src/sandbox/resolver/tests.rs`

- [ ] **Step 1: Write failing test**

Create `src/sandbox/resolver/tests.rs`:

```rust
#![cfg(target_os = "macos")]

use std::path::PathBuf;

use super::*;

#[test]
fn resolve_roundtrip_from_synthesized_bookmark() {
    let tmp = tempfile::tempdir().unwrap();
    let bytes = synthesize_bookmark(tmp.path());
    let resolved = resolve(&bytes).expect("resolve must succeed");
    assert_eq!(resolved.path(), tmp.path());
    assert!(!resolved.is_stale());
}

#[test]
fn is_sandboxed_reads_env() {
    let orig = std::env::var_os("HARNESS_SANDBOXED");
    unsafe { std::env::set_var("HARNESS_SANDBOXED", "1") };
    assert!(is_sandboxed());
    unsafe { std::env::remove_var("HARNESS_SANDBOXED") };
    assert!(!is_sandboxed());
    if let Some(v) = orig {
        unsafe { std::env::set_var("HARNESS_SANDBOXED", v) };
    }
}

fn synthesize_bookmark(path: &std::path::Path) -> Vec<u8> {
    use core_foundation::{base::TCFType, url::CFURL};
    use security_framework::os::macos::url_bookmark::CFURLBookmarkOptions;
    let cf_url = CFURL::from_path(path, true).unwrap();
    let data = cf_url.create_bookmark_data(
        CFURLBookmarkOptions::SECURITY_SCOPE,
        &[],
        None,
    ).unwrap();
    data.to_vec()
}
```

NOTE: `security-framework` public surface for bookmark data may differ slightly by version. Adjust import path to the actual `security-framework = "3"` API after reading its docs. If the crate does not expose bookmark creation (it's resolve-focused), use `core-foundation`'s `CFURLCreateBookmarkData` via the FFI extern directly - add that helper in the impl step below.

- [ ] **Step 2: Run test to confirm red**

```bash
cargo test --lib sandbox::resolver -- --nocapture
```

Expected: compile error - `resolve`, `is_sandboxed`, `ResolvedBookmark` missing.

- [ ] **Step 3: Implement resolver**

Create `src/sandbox/resolver.rs`:

```rust
//! macOS-only resolver for security-scoped bookmarks.

#![cfg(target_os = "macos")]

use std::path::{Path, PathBuf};

use core_foundation::{
    base::{CFType, TCFType},
    data::CFData,
    url::{
        kCFURLBookmarkResolutionWithSecurityScope,
        kCFURLBookmarkResolutionWithoutUI,
        CFURL,
    },
};

use crate::sandbox::bookmarks::BookmarkError;

pub struct ResolvedBookmark {
    url: PathBuf,
    is_stale: bool,
    _scope: BookmarkScope,
}

impl ResolvedBookmark {
    pub fn path(&self) -> &Path {
        &self.url
    }
    pub fn is_stale(&self) -> bool {
        self.is_stale
    }
}

pub struct BookmarkScope {
    cf_url: CFURL,
    started: bool,
}

impl BookmarkScope {
    fn start(cf_url: CFURL) -> Self {
        let started = unsafe { CFURLStartAccessingSecurityScopedResource(cf_url.as_concrete_TypeRef()) } != 0;
        Self { cf_url, started }
    }
}

impl Drop for BookmarkScope {
    fn drop(&mut self) {
        if self.started {
            unsafe { CFURLStopAccessingSecurityScopedResource(self.cf_url.as_concrete_TypeRef()) };
        }
    }
}

pub fn is_sandboxed() -> bool {
    std::env::var_os("HARNESS_SANDBOXED").is_some()
}

pub fn resolve(bytes: &[u8]) -> Result<ResolvedBookmark, BookmarkError> {
    let cf_data = CFData::from_buffer(bytes);
    let mut is_stale: core_foundation::base::Boolean = 0;
    let mut err: core_foundation::error::CFErrorRef = std::ptr::null_mut();
    let cf_url_ref = unsafe {
        CFURLCreateByResolvingBookmarkData(
            std::ptr::null(),
            cf_data.as_concrete_TypeRef(),
            kCFURLBookmarkResolutionWithSecurityScope | kCFURLBookmarkResolutionWithoutUI,
            std::ptr::null(),
            std::ptr::null_mut(),
            &mut is_stale,
            &mut err,
        )
    };
    if cf_url_ref.is_null() {
        return Err(BookmarkError::Resolution(format!("CFURLCreateByResolvingBookmarkData returned null (err ptr: {:p})", err)));
    }
    let cf_url = unsafe { CFURL::wrap_under_create_rule(cf_url_ref) };
    let path = cf_url.to_path().ok_or_else(|| BookmarkError::Resolution("CFURL::to_path failed".into()))?;
    let scope = BookmarkScope::start(cf_url);
    Ok(ResolvedBookmark {
        url: path,
        is_stale: is_stale != 0,
        _scope: scope,
    })
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFURLCreateByResolvingBookmarkData(
        allocator: core_foundation::base::CFAllocatorRef,
        bookmark_data: core_foundation::data::CFDataRef,
        options: core_foundation::base::CFOptionFlags,
        relative_to_url: *const core_foundation::url::__CFURL,
        resource_property_keys: *mut core_foundation::array::__CFArray,
        is_stale: *mut core_foundation::base::Boolean,
        error: *mut core_foundation::error::CFErrorRef,
    ) -> core_foundation::url::CFURLRef;
    fn CFURLStartAccessingSecurityScopedResource(url: core_foundation::url::CFURLRef) -> core_foundation::base::Boolean;
    fn CFURLStopAccessingSecurityScopedResource(url: core_foundation::url::CFURLRef);
}

#[cfg(test)]
mod tests;
```

NOTE: adjust the `CFURL` and `CFData` imports if `core-foundation` 0.10 moved them. Run `cargo doc --package core-foundation` to browse. If the const `kCFURLBookmarkResolutionWithSecurityScope` isn't re-exported, add it via the extern block.

- [ ] **Step 4: Run tests green**

```bash
cargo test --lib sandbox::resolver
```

Expected: 2/2 pass on macOS. On Linux the whole module is `cfg`'d out.

- [ ] **Step 5: Full gate**

```bash
mise run check
```

Expected: green.

- [ ] **Step 6: Commit**

```bash
git add Cargo.toml Cargo.lock src/sandbox/resolver.rs src/sandbox/resolver/tests.rs src/sandbox/mod.rs
git -c commit.gpgsign=true commit -sS -m "feat(sandbox): add macOS bookmark resolver"
```

---

## Task 7: Data-root resolution change (prefer app group on macOS)

**Files:**
- Modify: `src/workspace/session.rs` (`data_root`)
- Modify: `src/workspace/session/tests.rs`

- [ ] **Step 1: Write failing test**

Append to `src/workspace/session/tests.rs`:

```rust
#[test]
#[cfg(target_os = "macos")]
fn data_root_prefers_app_group_container_when_present() {
    temp_env::with_vars(
        vec![
            ("XDG_DATA_HOME", None::<&str>),
            ("HARNESS_APP_GROUP_ID", Some("Q498EB36N4.io.harnessmonitor")),
        ],
        || {
            // When the group container path exists, data_root should point
            // into ~/Library/Group Containers/<id>/ rather than falling all
            // the way back to the generic data-dir fallback.
            // This test relies on the host actually having the group
            // container directory; if absent, it falls back to the current
            // data-dir behavior.
            let home = dirs_home();
            let group = home
                .join("Library")
                .join("Group Containers")
                .join("Q498EB36N4.io.harnessmonitor");
            let expected = if group.exists() {
                group
            } else {
                user_dirs::data_dir().unwrap_or_else(|| {
                    home.join("Library").join("Application Support")
                })
            };
            assert_eq!(super::data_root(), expected);
        },
    );
}
```

- [ ] **Step 2: Run red**

```bash
cargo test --lib workspace::session::tests::data_root_prefers_app_group_container_when_present
```

Expected: on the original red run this failed because the implementation returned `Application Support` when `HARNESS_APP_GROUP_ID` was set. The live code now uses the full precedence chain, so treat this as historical context.

- [ ] **Step 3: Implement**

Replace the macOS branch in `data_root()` (src/workspace/session.rs:19-22) with the current precedence chain:

```rust
    if let Some(value) = normalized_env_value("XDG_DATA_HOME") {
        return PathBuf::from(value);
    }
    #[cfg(target_os = "macos")]
    if let Some(group_id) = normalized_env_value("HARNESS_APP_GROUP_ID") {
        let group_root = host_home_dir()
            .join("Library")
            .join("Group Containers")
            .join(&group_id);
        if group_root.exists() {
            return group_root;
        }
    }
    user_dirs::data_dir().unwrap_or_else(|_| dirs_home().join(".local").join("share"))
```

- [ ] **Step 4: Run green + full session tests**

```bash
cargo test --lib workspace::session
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/workspace/session.rs src/workspace/session/tests.rs
git -c commit.gpgsign=true commit -sS -m "feat(sandbox): prefer app group data root"
```

---

## Task 8: Data-root migration module

Current code note: the live migration includes an advisory lock, symlink-preserving copy fallback, and the macOS entrypoint is `run_startup_migration()` in `src/sandbox/migration.rs`.

**Files:**
- Create: `src/sandbox/migration.rs`
- Create: `src/sandbox/migration/tests.rs`
- Modify: `src/sandbox/mod.rs` (already declared; ensure pub)

- [ ] **Step 1: Write failing tests**

`src/sandbox/migration/tests.rs`:

```rust
use super::*;
use std::fs;
use tempfile::TempDir;

#[test]
fn migrates_when_old_has_data_and_new_empty() {
    let tmp = TempDir::new().unwrap();
    let old = tmp.path().join("old/harness");
    let new = tmp.path().join("new/harness");
    fs::create_dir_all(&old).unwrap();
    fs::write(old.join("session.json"), b"{}").unwrap();
    fs::create_dir_all(new.parent().unwrap()).unwrap();

    let outcome = migrate(&old, &new).unwrap();
    assert!(matches!(outcome, MigrationOutcome::Migrated));
    assert!(new.join("session.json").exists());
    assert!(new.join(".migrated-from").exists());
    assert!(!old.exists() || fs::read_dir(&old).unwrap().next().is_none());
}

#[test]
fn skips_when_new_has_data() {
    let tmp = TempDir::new().unwrap();
    let old = tmp.path().join("old/harness");
    let new = tmp.path().join("new/harness");
    fs::create_dir_all(&old).unwrap();
    fs::write(old.join("a.json"), b"{}").unwrap();
    fs::create_dir_all(&new).unwrap();
    fs::write(new.join("b.json"), b"{}").unwrap();

    let outcome = migrate(&old, &new).unwrap();
    assert!(matches!(outcome, MigrationOutcome::SkippedNewNotEmpty));
    // Both paths remain.
    assert!(old.join("a.json").exists());
    assert!(new.join("b.json").exists());
}

#[test]
fn skips_when_old_absent() {
    let tmp = TempDir::new().unwrap();
    let old = tmp.path().join("old/harness");
    let new = tmp.path().join("new/harness");
    fs::create_dir_all(&new).unwrap();

    let outcome = migrate(&old, &new).unwrap();
    assert!(matches!(outcome, MigrationOutcome::SkippedOldAbsent));
}

#[test]
fn idempotent_after_marker() {
    let tmp = TempDir::new().unwrap();
    let old = tmp.path().join("old/harness");
    let new = tmp.path().join("new/harness");
    fs::create_dir_all(&old).unwrap();
    fs::write(old.join("x.json"), b"{}").unwrap();

    let first = migrate(&old, &new).unwrap();
    assert!(matches!(first, MigrationOutcome::Migrated));
    let second = migrate(&old, &new).unwrap();
    assert!(matches!(second, MigrationOutcome::AlreadyMigrated));
}
```

- [ ] **Step 2: Implement migration**

`src/sandbox/migration.rs`:

```rust
//! One-shot migration from the legacy `~/Library/Application Support/harness`
//! data root to the new app-group-container root.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use chrono::Utc;
use serde::Serialize;
use thiserror::Error;
use tracing::{info, warn};

#[derive(Debug)]
pub enum MigrationOutcome {
    Migrated,
    AlreadyMigrated,
    SkippedOldAbsent,
    SkippedNewNotEmpty,
}

#[derive(Debug, Error)]
pub enum MigrationError {
    #[error("I/O: {0}")]
    Io(#[from] io::Error),
    #[error("serde: {0}")]
    Serde(#[from] serde_json::Error),
}

const MARKER_NAME: &str = ".migrated-from";

#[derive(Debug, Serialize)]
struct Marker {
    from_path: PathBuf,
    migrated_at: String,
    harness_version: &'static str,
}

pub fn migrate(old_root: &Path, new_root: &Path) -> Result<MigrationOutcome, MigrationError> {
    if new_root.join(MARKER_NAME).exists() {
        return Ok(MigrationOutcome::AlreadyMigrated);
    }
    if !old_root.exists() || dir_is_empty(old_root)? {
        return Ok(MigrationOutcome::SkippedOldAbsent);
    }
    if new_root.exists() && !dir_is_empty(new_root)? {
        warn!(old = %old_root.display(), new = %new_root.display(),
              "data-root split: both old and new have content; new wins, leaving old in place");
        return Ok(MigrationOutcome::SkippedNewNotEmpty);
    }

    fs::create_dir_all(new_root)?;
    move_contents(old_root, new_root)?;
    write_marker(new_root, old_root)?;
    info!(from = %old_root.display(), to = %new_root.display(), "migrated data root");
    Ok(MigrationOutcome::Migrated)
}

fn dir_is_empty(p: &Path) -> io::Result<bool> {
    Ok(fs::read_dir(p)?.next().is_none())
}

fn move_contents(from: &Path, to: &Path) -> io::Result<()> {
    for entry in fs::read_dir(from)? {
        let entry = entry?;
        let source = entry.path();
        let target = to.join(entry.file_name());
        if let Err(rename_err) = fs::rename(&source, &target) {
            // Cross-volume fallback: copy then delete.
            if rename_err.raw_os_error() == Some(libc::EXDEV) {
                copy_recursive(&source, &target)?;
                remove_recursive(&source)?;
            } else {
                return Err(rename_err);
            }
        }
    }
    Ok(())
}

fn copy_recursive(src: &Path, dst: &Path) -> io::Result<()> {
    if src.is_dir() {
        fs::create_dir_all(dst)?;
        for entry in fs::read_dir(src)? {
            let entry = entry?;
            copy_recursive(&entry.path(), &dst.join(entry.file_name()))?;
        }
    } else {
        fs::copy(src, dst)?;
    }
    Ok(())
}

fn remove_recursive(path: &Path) -> io::Result<()> {
    if path.is_dir() {
        fs::remove_dir_all(path)
    } else {
        fs::remove_file(path)
    }
}

fn write_marker(new_root: &Path, old_root: &Path) -> Result<(), MigrationError> {
    let marker = Marker {
        from_path: old_root.to_path_buf(),
        migrated_at: Utc::now().to_rfc3339(),
        harness_version: env!("CARGO_PKG_VERSION"),
    };
    let bytes = serde_json::to_vec_pretty(&marker)?;
    fs::write(new_root.join(MARKER_NAME), bytes)?;
    Ok(())
}

#[cfg(test)]
mod tests;
```

Add `libc = "0.2"` to `Cargo.toml` if not present.

- [ ] **Step 3: Run tests green**

```bash
cargo test --lib sandbox::migration
```

Expected: 4/4 pass.

- [ ] **Step 4: Commit**

```bash
git add Cargo.toml Cargo.lock src/sandbox/migration.rs src/sandbox/migration/tests.rs src/sandbox/mod.rs
git -c commit.gpgsign=true commit -sS -m "feat(sandbox): add data-root migration"
```

---

## Task 9: Wire migration into CLI startup

**Files:**
- Modify: `src/app/cli.rs`

- [ ] **Step 1: Identify old + new data root helpers**

The macOS legacy path is `<home>/Library/Application Support/harness` and the current new path is computed by `harness_data_root()` in `src/workspace/paths.rs`. The helper `legacy_macos_root()` already exists next to it:

```rust
#[cfg(target_os = "macos")]
pub fn legacy_macos_root() -> PathBuf {
    super::paths::host_home_dir()
        .join("Library")
        .join("Application Support")
        .join("harness")
}
```

- [ ] **Step 2: Call migrate at CLI startup**

In `src/app/cli.rs`, at the top of `dispatch()` on macOS, call `crate::sandbox::migration::run_startup_migration()`. The current code does not wire a separate daemon startup hook.

- [ ] **Step 3: Keep the startup hook centralized**

Do not add a second `migrate(...)` call in `src/daemon/mod.rs`; the current implementation keeps startup migration in CLI dispatch only.

- [ ] **Step 4: Build + smoke test**

```bash
cargo build --bin harness
mise run test
```

Expected: green. If the migration path changes again, update the current `run_startup_migration()` entrypoint rather than duplicating startup hooks.

- [ ] **Step 5: Commit**

```bash
git add src/app/cli.rs
git -c commit.gpgsign=true commit -sS -m "feat(sandbox): run data-root migration at start"
```

---

## Task 10: Remove `temporary-exception` entitlement + codesign gate

**Files:**
- Modify: `apps/harness-monitor-macos/HarnessMonitorDaemon.entitlements`
- Modify: `apps/harness-monitor-macos/Scripts/run-quality-gates.sh`

- [ ] **Step 1: Update quality-gates script to assert entitlements**

Append at the end of `run-quality-gates.sh` (before `exit 0`):

```bash
# Verify sandbox entitlements on the built app + daemon
APP_PATH="xcode-derived/Build/Products/Debug/Harness Monitor.app"
DAEMON_PATH="$APP_PATH/Contents/Library/LaunchAgents/io.harnessmonitor.daemon"

if [[ -d "$APP_PATH" ]]; then
  entitlements="$(codesign --display --entitlements :- "$APP_PATH" 2>/dev/null || true)"
  for key in user-selected.read-write bookmarks.app-scope bookmarks.document-scope; do
    grep -q "com.apple.security.files.$key" <<<"$entitlements" \
      || { echo "missing app entitlement: $key"; exit 1; }
  done
fi

if [[ -x "$DAEMON_PATH" ]]; then
  daemon_ent="$(codesign --display --entitlements :- "$DAEMON_PATH" 2>/dev/null || true)"
  if grep -q "com.apple.security.temporary-exception.files.home-relative-path" <<<"$daemon_ent"; then
    echo "daemon still has temporary-exception entitlement"
    exit 1
  fi
  grep -q "com.apple.security.files.bookmarks.app-scope" <<<"$daemon_ent" \
    || { echo "daemon missing bookmarks.app-scope"; exit 1; }
fi
```

- [ ] **Step 2: Remove entitlement**

Edit `HarnessMonitorDaemon.entitlements` - delete:

```xml
	<key>com.apple.security.temporary-exception.files.home-relative-path.read-write</key>
	<array>
		<string>/Library/Application Support/harness/</string>
	</array>
```

- [ ] **Step 3: Build + run the gates**

```bash
xcodebuild ... build
apps/harness-monitor-macos/Scripts/run-quality-gates.sh
```

Expected: green. If the daemon binary can't find its data root at the old path, the migration from Task 9 should already have moved it to the new path.

- [ ] **Step 4: Commit**

```bash
git add apps/harness-monitor-macos/HarnessMonitorDaemon.entitlements \
        apps/harness-monitor-macos/Scripts/run-quality-gates.sh
git -c commit.gpgsign=true commit -sS -m "feat(sandbox): drop temporary-exception"
```

---

## Task 11: Swift FS audit sweep + HarnessMonitorPaths update

Current code note: `HarnessMonitorPaths` already uses `HARNESS_DAEMON_DATA_HOME`, `XDG_DATA_HOME`, `HARNESS_APP_GROUP_ID`, `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`, and a managed-build `fatalError` when the group container is unavailable. Keep this section aligned to that precedence chain rather than a simplified "always use the group container" sketch.

**Files:**
- Modify: `Sources/HarnessMonitorKit/Support/HarnessMonitorPaths.swift`
- Modify: `Sources/HarnessMonitorKit/API/DaemonController+ManifestLoading.swift` (and any others found)
- Create: `docs/superpowers/plans/2026-04-20-sandbox-file-access-fs-audit.md` (audit log)

- [ ] **Step 1: Enumerate every FS access site**

```bash
grep -rn "FileManager\|URL(fileURLWithPath:\|homeDirectoryForCurrentUser\|applicationSupportDirectory\|NSHomeDirectory" \
  apps/harness-monitor-macos/Sources/ \
  > tmp/sandbox-audit.txt
```

Review each hit. Classify into three buckets:

1. **App sandbox container** (e.g. `NSHomeDirectory()` when sandboxed returns the container - safe) - no action.
2. **App group container** (accessed via `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` - safe) - no action.
3. **Outside sandbox** (e.g. `~/Library/Application Support/harness/`, user-picked paths) - must either migrate into app group (for app-owned data) or go through bookmark + `withSecurityScope`.

Write the classified list to `docs/superpowers/plans/2026-04-20-sandbox-file-access-fs-audit.md`.

- [ ] **Step 2: Update `HarnessMonitorPaths` to match the current precedence chain**

`HarnessMonitorPaths.swift` - locate the `daemonRoot` / `harnessRoot` accessor (around lines 46-49 + 106-108 per the Explore agent). Keep the current precedence chain intact:

```swift
public static func harnessRoot(using environment: HarnessMonitorEnvironment = .current) -> URL {
    if let base = resolveBaseRoot(using: environment, preferExternalDaemon: true) {
        return base.appendingPathComponent("harness", isDirectory: true)
    }
    if DaemonOwnership(environment: environment) == .managed {
        fatalError("group container unavailable in managed build")
    }
    return environment.homeDirectory
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent("harness", isDirectory: true)
}
```

- [ ] **Step 3: Run Swift tests**

```bash
xcodebuild ... test -only-testing:HarnessMonitorKitTests
```

Expected: existing tests pass (path change is transparent since they resolve via `HarnessMonitorPaths`).

- [ ] **Step 4: For each bucket-3 audit site, wrap or migrate**

For each site identified in Step 1 as outside-sandbox:

- If app-owned data: ensure it resolves via `HarnessMonitorPaths` (now group-rooted). No bookmark needed.
- If user-picked: route through `BookmarkStore.resolve(id:).url.withSecurityScope { ... }`. Add a test per site.

Commit each fix separately. If the audit shows zero bucket-3 sites needing a bookmark (likely since C and D are the consumers), note that in the audit doc.

- [ ] **Step 5: Commit audit + path update**

```bash
git add apps/harness-monitor-macos/Sources/HarnessMonitorKit/Support/HarnessMonitorPaths.swift \
        docs/superpowers/plans/2026-04-20-sandbox-file-access-fs-audit.md
git -c commit.gpgsign=true commit -sS -m "refactor(monitor): route paths via app group"
```

---

## Task 12: "Open Folder…" command

**Files:**
- Create: `Sources/HarnessMonitor/Commands/OpenFolderCommand.swift`
- Modify: `Sources/HarnessMonitor/HarnessMonitorApp.swift`

- [ ] **Step 1: Implement the command**

`OpenFolderCommand.swift`:

```swift
import SwiftUI
import HarnessMonitorKit

struct OpenFolderCommand: Commands {
    @Binding var isPresented: Bool

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Folder…") { isPresented = true }
                .keyboardShortcut("O", modifiers: [.command, .shift])
        }
    }
}
```

- [ ] **Step 2: Wire into app scene**

Add to `HarnessMonitorApp.swift` inside `WindowGroup`:

```swift
@State private var showOpenFolder = false
// ...
.fileImporter(
    isPresented: $showOpenFolder,
    allowedContentTypes: [.folder],
    allowsMultipleSelection: false
) { result in
    Task {
        await handleOpenFolder(result)
    }
}
```

And `.commands { OpenFolderCommand(isPresented: $showOpenFolder) }`.

Add the handler:

```swift
@MainActor
private func handleOpenFolder(_ result: Result<[URL], Error>) async {
    switch result {
    case .success(let urls):
        guard let url = urls.first else { return }
        do {
            _ = try await store.bookmarkStore.add(url: url, kind: .projectRoot)
        } catch {
            Self.logger.error("bookmark add failed: \(error.localizedDescription)")
        }
    case .failure(let error):
        Self.logger.error("picker failed: \(error.localizedDescription)")
    }
}
```

Ensure `store.bookmarkStore: BookmarkStore` is provided. Add it to `HarnessMonitorStore` init wiring.

- [ ] **Step 3: Quality gates + targeted smoke**

```bash
apps/harness-monitor-macos/Scripts/run-quality-gates.sh
xcodebuild ... build
```

Expected: green.

- [ ] **Step 4: Commit**

```bash
git add apps/harness-monitor-macos/Sources/HarnessMonitor/Commands/OpenFolderCommand.swift \
        apps/harness-monitor-macos/Sources/HarnessMonitor/HarnessMonitorApp.swift \
        apps/harness-monitor-macos/Sources/HarnessMonitorKit/Stores/
git -c commit.gpgsign=true commit -sS -m "feat(monitor): add Open Folder command"
```

---

## Task 13: Authorized Folders preferences section

**Files:**
- Create: `Sources/HarnessMonitorUI/Views/Preferences/AuthorizedFoldersSection.swift`
- Modify: `Sources/HarnessMonitorUI/Views/PreferencesView.swift`

- [ ] **Step 1: Implement the section**

```swift
import SwiftUI
import HarnessMonitorKit

struct AuthorizedFoldersSection: View {
    @Environment(HarnessMonitorStore.self) private var store
    @State private var records: [BookmarkStore.Record] = []

    var body: some View {
        Section("Authorized Folders") {
            if records.isEmpty {
                ContentUnavailableView(
                    "No authorized folders",
                    systemImage: "folder.badge.questionmark",
                    description: Text("Use File > Open Folder… to authorize a project directory.")
                )
            } else {
                ForEach(records) { record in
                    row(for: record)
                }
            }
            Button("Add Folder…") { store.requestOpenFolder() }
        }
        .task { await reload() }
    }

    private func row(for record: BookmarkStore.Record) -> some View {
        LabeledContent(record.displayName) {
            HStack {
                Text(record.lastResolvedPath).font(.caption).foregroundStyle(.secondary)
                Menu {
                    Button("Reveal in Finder") { reveal(record) }
                    Button("Remove", role: .destructive) { Task { await remove(record) } }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
            }
        }
        .accessibilityIdentifier("authorized-folder-row-\(record.id)")
    }

    private func reload() async {
        records = await store.bookmarkStore.all()
    }

    private func remove(_ record: BookmarkStore.Record) async {
        do {
            try await store.bookmarkStore.remove(id: record.id)
            await reload()
        } catch {
            // TODO: surface via toast - handled by Task 14 if needed
        }
    }

    private func reveal(_ record: BookmarkStore.Record) {
        let url = URL(fileURLWithPath: record.lastResolvedPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
```

Add `requestOpenFolder()` on `HarnessMonitorStore` that flips the binding from Task 12.

- [ ] **Step 2: Insert into PreferencesView**

Add `AuthorizedFoldersSection()` inside the preferences sidebar or general pane.

- [ ] **Step 3: Quality gates**

```bash
apps/harness-monitor-macos/Scripts/run-quality-gates.sh
xcodebuild ... build
```

Expected: green.

- [ ] **Step 4: Commit**

```bash
git add apps/harness-monitor-macos/Sources/HarnessMonitorUI/Views/Preferences/AuthorizedFoldersSection.swift \
        apps/harness-monitor-macos/Sources/HarnessMonitorUI/Views/PreferencesView.swift \
        apps/harness-monitor-macos/Sources/HarnessMonitorKit/Stores/
git -c commit.gpgsign=true commit -sS -m "feat(monitor): add Authorized Folders prefs"
```

---

## Task 14: UI test - Open Folder flow

**Files:**
- Create: `apps/harness-monitor-macos/Tests/HarnessMonitorUITests/AuthorizedFoldersTests.swift`

- [ ] **Step 1: Implement test**

```swift
import XCTest

final class AuthorizedFoldersTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testAddFolderViaShortcutShowsInPrefs() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-HarnessMonitorPreseedBookmark", "1",
        ]
        app.launch()

        // Trigger Cmd+Shift+O (command uses preseed env var instead of the
        // real picker, inserts a temp dir as a project root)
        app.typeKey("O", modifierFlags: [.command, .shift])

        app.menuBars.menuBarItems["Harness Monitor"].click()
        app.menuBars.menuItems["Settings…"].click()

        let row = app.descendants(matching: .any)
            .matching(identifier: "authorized-folder-row-B-preseed").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }
}
```

- [ ] **Step 2: Add preseed hook in the app**

In `HarnessMonitorApp.swift`, at init, when `-HarnessMonitorPreseedBookmark` is 1, bypass the picker and insert a record keyed to `id = "B-preseed"` pointing at `FileManager.default.temporaryDirectory`. This keeps the real `.fileImporter` out of UI tests (which can't drive native file dialogs reliably).

- [ ] **Step 3: Run targeted UI test**

```bash
xcodebuild -project 'apps/harness-monitor-macos/HarnessMonitor.xcodeproj' \
  -scheme HarnessMonitor -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath xcode-derived \
  -skipPackagePluginValidation test \
  -only-testing:HarnessMonitorUITests/AuthorizedFoldersTests/testAddFolderViaShortcutShowsInPrefs
```

Expected: pass.

- [ ] **Step 4: Commit**

```bash
git add apps/harness-monitor-macos/Tests/HarnessMonitorUITests/AuthorizedFoldersTests.swift \
        apps/harness-monitor-macos/Sources/HarnessMonitor/HarnessMonitorApp.swift \
        apps/harness-monitor-macos/project.yml \
        apps/harness-monitor-macos/HarnessMonitor.xcodeproj
git -c commit.gpgsign=true commit -sS -m "test(monitor): cover Open Folder flow"
```

---

## Task 15: Integration test - daemon resolves Swift-written bookmark

**Files:**
- Create: `tests/integration/sandbox/mod.rs`
- Create: `tests/integration/sandbox/bookmark_resolution.rs`
- Modify: `tests/integration/mod.rs` (register `mod sandbox;`)

- [ ] **Step 1: Implement test (macOS-gated)**

`tests/integration/sandbox/bookmark_resolution.rs`:

```rust
#![cfg(target_os = "macos")]

use harness::sandbox::bookmarks::{load, save, PersistedStore, Record, Kind};
use harness::sandbox::resolver;
use tempfile::TempDir;

#[test]
fn roundtrip_through_shared_json() {
    let target = TempDir::new().unwrap();
    let container = TempDir::new().unwrap();
    let json_path = container.path().join("sandbox/bookmarks.json");

    // Synthesize a bookmark as the Swift side would.
    let bookmark_bytes = synthesize_bookmark(target.path());
    let store = PersistedStore {
        schema_version: PersistedStore::CURRENT_SCHEMA_VERSION,
        bookmarks: vec![Record {
            id: "B-integ".into(),
            kind: Kind::ProjectRoot,
            display_name: "integ".into(),
            last_resolved_path: target.path().display().to_string(),
            bookmark_data: bookmark_bytes,
            created_at: chrono::Utc::now(),
            last_accessed_at: chrono::Utc::now(),
            stale_count: 0,
        }],
    };
    save(&json_path, &store).unwrap();

    let reloaded = load(&json_path).unwrap();
    let bytes = &reloaded.bookmarks[0].bookmark_data;
    let resolved = resolver::resolve(bytes).expect("resolve");
    assert_eq!(resolved.path(), target.path());
}

fn synthesize_bookmark(path: &std::path::Path) -> Vec<u8> {
    // Same helper as resolver/tests.rs - factored into a common place.
    // If already pub, import it.
    harness::sandbox::resolver::tests::synthesize_bookmark_for(path)
}
```

- [ ] **Step 2: Run integration tests**

```bash
cargo test --test integration sandbox::bookmark_resolution
```

Expected: pass on macOS. Skipped on Linux via cfg.

- [ ] **Step 3: Commit**

```bash
git add tests/integration/sandbox/ tests/integration/mod.rs
git -c commit.gpgsign=true commit -sS -m "test(sandbox): cover bookmark share flow"
```

---

## Task 16: Version bump + final gates

**Files:**
- Modify: `Cargo.toml` (bump version)

- [ ] **Step 1: Bump version (minor)**

```bash
./scripts/version.sh set 27.3.0
mise run version:sync
```

- [ ] **Step 2: Run every gate**

```bash
mise run check
apps/harness-monitor-macos/Scripts/run-quality-gates.sh
xcodebuild -project 'apps/harness-monitor-macos/HarnessMonitor.xcodeproj' \
  -scheme HarnessMonitor -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath xcode-derived \
  -skipPackagePluginValidation test \
  -skip-testing:HarnessMonitorUITests
```

Expected: all green.

- [ ] **Step 3: Commit**

```bash
git add Cargo.toml Cargo.lock testkit/Cargo.toml \
        apps/harness-monitor-macos/project.yml \
        apps/harness-monitor-macos/HarnessMonitor.xcodeproj/project.pbxproj \
        apps/harness-monitor-macos/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist
git -c commit.gpgsign=true commit -sS -m "chore: bump to 27.3.0 for sandbox feature"
```

---

## Self-review notes

**Spec coverage check:**

| Spec section | Plan task(s) |
| --- | --- |
| Entitlements (app) | Task 1 |
| Entitlements (daemon) | Task 1 (add) + Task 10 (remove exception) |
| Data-root relocation | Task 7 + Task 8 + Task 9 |
| BookmarkStore (Swift) | Task 3 + Task 4 |
| URL.withSecurityScope | Task 2 |
| Swift FS audit + wrapping | Task 11 |
| Folder picker + menu command | Task 12 |
| Authorized Folders preferences | Task 13 |
| Rust BookmarkResolver | Task 5 + Task 6 |
| Gated on HARNESS_SANDBOXED | Task 6 (`is_sandboxed`) |
| Observability | Covered inline in Swift (os_log) + Rust (tracing) |
| Unit tests | Tasks 2, 4, 5, 6, 8 |
| Integration tests | Task 15 |
| UI test | Task 14 |
| `codesign` gate | Task 10 |
| Version bump | Task 16 |
| Follow-ups (C, D) | Out of scope - infrastructure is generic enough (noted in spec) |

**Placeholder scan:** Only `TODO: surface via toast` in Task 13 - acceptable, belongs to later UX polish, not a plan hole. No "TBD" or "implement later" remaining.

**Type consistency:** `BookmarkStore.Record.Kind` values (`projectRoot`, `sessionDirectory`) match Rust `Kind` (`ProjectRoot`, `SessionDirectory`) via serde rename. `PersistedStore.schemaVersion` / `PersistedStore.currentSchemaVersion` consistent across both.
