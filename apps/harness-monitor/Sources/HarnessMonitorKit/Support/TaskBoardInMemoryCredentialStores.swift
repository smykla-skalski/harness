import Foundation

/// Process-wide in-memory stand-in for the GitHub task-board credential
/// Keychain entry. Used whenever the running process is xctest so test code
/// does not prompt the user for Keychain access.
final class InMemoryTaskBoardGitHubCredentialStore:
  TaskBoardGitHubCredentialPersisting, @unchecked Sendable
{
  private let lock = NSLock()
  private var snapshotsValue: [TaskBoardCredentialScope: TaskBoardGitHubCredentialSnapshot] = [:]
  private var savedSnapshotsValue: [TaskBoardGitHubCredentialSnapshot] = []

  var snapshot: TaskBoardGitHubCredentialSnapshot {
    (try? load(scope: .legacy)) ?? TaskBoardGitHubCredentialSnapshot()
  }

  var savedSnapshots: [TaskBoardGitHubCredentialSnapshot] {
    lock.lock()
    defer { lock.unlock() }
    return savedSnapshotsValue
  }

  func load(
    scope: TaskBoardCredentialScope = .legacy
  ) throws -> TaskBoardGitHubCredentialSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return snapshotsValue[scope] ?? TaskBoardGitHubCredentialSnapshot()
  }

  func save(
    _ snapshot: TaskBoardGitHubCredentialSnapshot,
    scope: TaskBoardCredentialScope = .legacy
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    if snapshot.isEmpty {
      snapshotsValue.removeValue(forKey: scope)
    } else {
      snapshotsValue[scope] = snapshot
    }
    savedSnapshotsValue.append(snapshot)
  }

  func delete(scope: TaskBoardCredentialScope = .legacy) throws {
    lock.lock()
    defer { lock.unlock() }
    snapshotsValue.removeValue(forKey: scope)
  }
}

final class InMemoryTaskBoardTodoistCredentialStore:
  TaskBoardTodoistCredentialPersisting, @unchecked Sendable
{
  private let lock = NSLock()
  private var snapshotsValue: [TaskBoardCredentialScope: TaskBoardTodoistCredentialSnapshot] = [:]

  var snapshot: TaskBoardTodoistCredentialSnapshot {
    (try? load(scope: .legacy)) ?? TaskBoardTodoistCredentialSnapshot()
  }

  func load(
    scope: TaskBoardCredentialScope = .legacy
  ) throws -> TaskBoardTodoistCredentialSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return snapshotsValue[scope] ?? TaskBoardTodoistCredentialSnapshot()
  }

  func save(
    _ snapshot: TaskBoardTodoistCredentialSnapshot,
    scope: TaskBoardCredentialScope = .legacy
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    if snapshot.isEmpty {
      snapshotsValue.removeValue(forKey: scope)
    } else {
      snapshotsValue[scope] = snapshot
    }
  }

  func delete(scope: TaskBoardCredentialScope = .legacy) throws {
    lock.lock()
    defer { lock.unlock() }
    snapshotsValue.removeValue(forKey: scope)
  }
}

final class InMemoryTaskBoardOpenRouterCredentialStore:
  TaskBoardOpenRouterCredentialPersisting, @unchecked Sendable
{
  private let lock = NSLock()
  private var snapshotsValue: [TaskBoardCredentialScope: TaskBoardOpenRouterCredentialSnapshot] =
    [:]

  var snapshot: TaskBoardOpenRouterCredentialSnapshot {
    (try? load(scope: .legacy)) ?? TaskBoardOpenRouterCredentialSnapshot()
  }

  func load(
    scope: TaskBoardCredentialScope = .legacy
  ) throws -> TaskBoardOpenRouterCredentialSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return snapshotsValue[scope] ?? TaskBoardOpenRouterCredentialSnapshot()
  }

  func save(
    _ snapshot: TaskBoardOpenRouterCredentialSnapshot,
    scope: TaskBoardCredentialScope = .legacy
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    if snapshot.isEmpty {
      snapshotsValue.removeValue(forKey: scope)
    } else {
      snapshotsValue[scope] = snapshot
    }
  }

  func delete(scope: TaskBoardCredentialScope = .legacy) throws {
    lock.lock()
    defer { lock.unlock() }
    snapshotsValue.removeValue(forKey: scope)
  }
}

final class InMemoryTaskBoardKeyMaterialStore: TaskBoardKeyMaterialPersisting, @unchecked Sendable {
  private let lock = NSLock()
  private var snapshotsValue: [TaskBoardKeyMaterialStore.Scope: TaskBoardKeyMaterialSnapshot] = [:]
  private var recordedValue: [(TaskBoardKeyMaterialStore.Scope, TaskBoardKeyMaterialSnapshot)] = []

  var snapshots: [TaskBoardKeyMaterialStore.Scope: TaskBoardKeyMaterialSnapshot] {
    lock.lock()
    defer { lock.unlock() }
    return snapshotsValue
  }

  var recorded: [(TaskBoardKeyMaterialStore.Scope, TaskBoardKeyMaterialSnapshot)] {
    lock.lock()
    defer { lock.unlock() }
    return recordedValue
  }

  func load(scope: TaskBoardKeyMaterialStore.Scope) throws -> TaskBoardKeyMaterialSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return snapshotsValue[scope] ?? TaskBoardKeyMaterialSnapshot()
  }

  func save(_ snapshot: TaskBoardKeyMaterialSnapshot, scope: TaskBoardKeyMaterialStore.Scope) throws
  {
    lock.lock()
    defer { lock.unlock() }
    snapshotsValue[scope] = snapshot
    if !snapshot.isEmpty {
      recordedValue.append((scope, snapshot))
    }
  }

  func delete(scope: TaskBoardKeyMaterialStore.Scope) throws {
    lock.lock()
    defer { lock.unlock() }
    snapshotsValue.removeValue(forKey: scope)
  }
}

extension TaskBoardCredentialPersistence {
  static var inMemory: Self {
    Self(
      github: InMemoryTaskBoardGitHubCredentialStore(),
      todoist: InMemoryTaskBoardTodoistCredentialStore(),
      openRouter: InMemoryTaskBoardOpenRouterCredentialStore()
    )
  }
}

extension TaskBoardKeyMaterialPersistence {
  public static var inMemory: Self {
    Self(
      ssh: InMemoryTaskBoardKeyMaterialStore(),
      signingSsh: InMemoryTaskBoardKeyMaterialStore(),
      gpg: InMemoryTaskBoardKeyMaterialStore()
    )
  }
}
