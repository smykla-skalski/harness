import Foundation

/// Process-wide in-memory stand-in for the GitHub task-board credential
/// Keychain entry. Used whenever the running process is xctest so test code
/// does not prompt the user for Keychain access.
final class InMemoryTaskBoardGitHubCredentialStore:
  TaskBoardGitHubCredentialPersisting, @unchecked Sendable
{
  private let lock = NSLock()
  private var snapshotValue = TaskBoardGitHubCredentialSnapshot()
  private var savedSnapshotsValue: [TaskBoardGitHubCredentialSnapshot] = []

  var snapshot: TaskBoardGitHubCredentialSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return snapshotValue
  }

  var savedSnapshots: [TaskBoardGitHubCredentialSnapshot] {
    lock.lock()
    defer { lock.unlock() }
    return savedSnapshotsValue
  }

  func load() throws -> TaskBoardGitHubCredentialSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return snapshotValue
  }

  func save(_ snapshot: TaskBoardGitHubCredentialSnapshot) throws {
    lock.lock()
    defer { lock.unlock() }
    snapshotValue = snapshot
    savedSnapshotsValue.append(snapshot)
  }

  func delete() throws {
    lock.lock()
    defer { lock.unlock() }
    snapshotValue = TaskBoardGitHubCredentialSnapshot()
  }
}

final class InMemoryTaskBoardTodoistCredentialStore:
  TaskBoardTodoistCredentialPersisting, @unchecked Sendable
{
  private let lock = NSLock()
  private var snapshotValue = TaskBoardTodoistCredentialSnapshot()

  var snapshot: TaskBoardTodoistCredentialSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return snapshotValue
  }

  func load() throws -> TaskBoardTodoistCredentialSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return snapshotValue
  }

  func save(_ snapshot: TaskBoardTodoistCredentialSnapshot) throws {
    lock.lock()
    defer { lock.unlock() }
    snapshotValue = snapshot
  }

  func delete() throws {
    lock.lock()
    defer { lock.unlock() }
    snapshotValue = TaskBoardTodoistCredentialSnapshot()
  }
}

final class InMemoryTaskBoardOpenRouterCredentialStore:
  TaskBoardOpenRouterCredentialPersisting, @unchecked Sendable
{
  private let lock = NSLock()
  private var snapshotValue = TaskBoardOpenRouterCredentialSnapshot()

  var snapshot: TaskBoardOpenRouterCredentialSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return snapshotValue
  }

  func load() throws -> TaskBoardOpenRouterCredentialSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return snapshotValue
  }

  func save(_ snapshot: TaskBoardOpenRouterCredentialSnapshot) throws {
    lock.lock()
    defer { lock.unlock() }
    snapshotValue = snapshot
  }

  func delete() throws {
    lock.lock()
    defer { lock.unlock() }
    snapshotValue = TaskBoardOpenRouterCredentialSnapshot()
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
