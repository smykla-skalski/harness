import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Task-board runtime-secret migration")
struct TaskBoardRuntimeSecretMigrationTests {
  @Test("Skips drain when the managed-ownership flag is already set")
  func skipsWhenFlagAlreadySet() async {
    let client = RecordingHarnessClient()
    let defaults = makeEmptyDefaults()
    defaults.set(
      true,
      forKey: HarnessMonitorStore.taskBoardRuntimeSecretsMigrationKey(for: .managed)
    )
    let keychain = InMemoryKeychainBundle()

    let baseline = client.recordedCalls().count
    await HarnessMonitorStore.migrateRuntimeSecretsIfNeeded(
      client: client,
      ownership: .managed,
      userDefaults: defaults,
      keychain: keychain.persistence
    )

    let newCalls = Array(client.recordedCalls().dropFirst(baseline))
    #expect(
      newCalls.contains { call in
        if case .drainTaskBoardGitRuntimeSecrets = call { return true }
        return false
      } == false
    )
    #expect(keychain.savedSnapshots.isEmpty)
  }

  @Test("Sets the per-ownership flag without writing to Keychain when drained == false")
  func recordsFlagWhenNothingToDrain() async {
    let client = RecordingHarnessClient()
    let defaults = makeEmptyDefaults()
    let keychain = InMemoryKeychainBundle()

    await HarnessMonitorStore.migrateRuntimeSecretsIfNeeded(
      client: client,
      ownership: .managed,
      userDefaults: defaults,
      keychain: keychain.persistence
    )

    #expect(
      defaults.bool(
        forKey: HarnessMonitorStore.taskBoardRuntimeSecretsMigrationKey(for: .managed)
      )
    )
    #expect(keychain.savedSnapshots.isEmpty)
    let calls = client.recordedCalls()
    #expect(
      calls.contains { call in
        if case .drainTaskBoardGitRuntimeSecrets = call { return true }
        return false
      }
    )
  }

  @Test("Mirrors drained secrets into Keychain and flips the flag exactly once")
  func mirrorsDrainedSecretsAndSetsFlag() async {
    let client = RecordingHarnessClient()
    client.taskBoardGitRuntimeDrainSecretsValue = TaskBoardGitRuntimeDrainSecretsResponse(
      drained: true,
      runtime: TaskBoardGitRuntimeConfig(
        global: TaskBoardGitRuntimeProfile(
          sshKeyPath: "/keys/id_ed25519",
          sshPrivateKey: "global-ssh-secret",
          sshPrivateKeyPassphrase: "global-ssh-pass",
          signing: TaskBoardGitSigningConfig(
            mode: .gpg,
            gpgKeyId: "ABC123",
            gpgPrivateKey: "global-gpg-secret",
            gpgPrivateKeyPassphrase: "global-gpg-pass"
          )
        ),
        repositoryOverrides: [
          TaskBoardGitRepositoryOverride(
            repository: "owner/repo",
            profile: TaskBoardGitRuntimeProfile(
              sshPrivateKey: "repo-ssh-secret"
            )
          )
        ]
      )
    )
    let defaults = makeEmptyDefaults()
    let keychain = InMemoryKeychainBundle()

    await HarnessMonitorStore.migrateRuntimeSecretsIfNeeded(
      client: client,
      ownership: .managed,
      userDefaults: defaults,
      keychain: keychain.persistence
    )

    #expect(
      defaults.bool(
        forKey: HarnessMonitorStore.taskBoardRuntimeSecretsMigrationKey(for: .managed)
      )
    )
    let globalSSH = keychain.ssh.snapshots[.global]
    #expect(globalSSH?.privateKey == "global-ssh-secret")
    #expect(globalSSH?.passphrase == "global-ssh-pass")
    #expect(globalSSH?.keyPath == "/keys/id_ed25519")
    let globalGPG = keychain.gpg.snapshots[.global]
    #expect(globalGPG?.privateKey == "global-gpg-secret")
    #expect(globalGPG?.keyId == "ABC123")
    let repoSSH = keychain.ssh.snapshots[.repository("owner/repo")]
    #expect(repoSSH?.privateKey == "repo-ssh-secret")

    let preSecondCount = client.recordedCalls().count
    await HarnessMonitorStore.migrateRuntimeSecretsIfNeeded(
      client: client,
      ownership: .managed,
      userDefaults: defaults,
      keychain: keychain.persistence
    )
    #expect(client.recordedCalls().count == preSecondCount)
  }

  @Test("Drain failure leaves the flag unset so the next snapshot retries")
  func drainFailureKeepsRetrying() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardGitRuntimeDrainSecretsError(
      HarnessMonitorAPIError.server(code: 404, message: "older daemon")
    )
    let defaults = makeEmptyDefaults()
    let keychain = InMemoryKeychainBundle()

    await HarnessMonitorStore.migrateRuntimeSecretsIfNeeded(
      client: client,
      ownership: .managed,
      userDefaults: defaults,
      keychain: keychain.persistence
    )

    #expect(
      defaults.bool(forKey: HarnessMonitorStore.taskBoardRuntimeSecretsMigrationKey(for: .managed))
        == false
    )
    #expect(keychain.savedSnapshots.isEmpty)
  }

  @Test("Managed-side migration does not block external-side migration")
  func managedFlagDoesNotBlockExternal() async {
    let client = RecordingHarnessClient()
    client.taskBoardGitRuntimeDrainSecretsValue = TaskBoardGitRuntimeDrainSecretsResponse(
      drained: true,
      runtime: TaskBoardGitRuntimeConfig(
        global: TaskBoardGitRuntimeProfile(sshPrivateKey: "external-only-secret")
      )
    )
    let defaults = makeEmptyDefaults()
    defaults.set(
      true,
      forKey: HarnessMonitorStore.taskBoardRuntimeSecretsMigrationKey(for: .managed)
    )
    let keychain = InMemoryKeychainBundle()

    await HarnessMonitorStore.migrateRuntimeSecretsIfNeeded(
      client: client,
      ownership: .external,
      userDefaults: defaults,
      keychain: keychain.persistence
    )

    #expect(
      defaults.bool(
        forKey: HarnessMonitorStore.taskBoardRuntimeSecretsMigrationKey(for: .external)
      )
    )
    #expect(keychain.ssh.snapshots[.global]?.privateKey == "external-only-secret")
  }

  @Test("Managed and external ownership produce distinct flag keys")
  func keysAreDistinctPerOwnership() {
    let managedKey = HarnessMonitorStore.taskBoardRuntimeSecretsMigrationKey(for: .managed)
    let externalKey = HarnessMonitorStore.taskBoardRuntimeSecretsMigrationKey(for: .external)
    #expect(managedKey != externalKey)
    #expect(managedKey.hasSuffix(".managed"))
    #expect(externalKey.hasSuffix(".external"))
  }

  private func makeEmptyDefaults() -> UserDefaults {
    let suite = "harness.migration.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }
}

@MainActor
private final class InMemoryKeychainBundle {
  let ssh = InMemoryKeyMaterialStore()
  let signingSsh = InMemoryKeyMaterialStore()
  let gpg = InMemoryKeyMaterialStore()

  var savedSnapshots: [(TaskBoardKeyMaterialStore.Scope, TaskBoardKeyMaterialSnapshot)] {
    let kinds: [InMemoryKeyMaterialStore] = [ssh, signingSsh, gpg]
    return kinds.flatMap { $0.recorded }
  }

  var persistence: TaskBoardKeyMaterialPersistence {
    TaskBoardKeyMaterialPersistence(
      ssh: ssh,
      signingSsh: signingSsh,
      gpg: gpg
    )
  }
}

private final class InMemoryKeyMaterialStore: TaskBoardKeyMaterialPersisting, @unchecked Sendable {
  var snapshots: [TaskBoardKeyMaterialStore.Scope: TaskBoardKeyMaterialSnapshot] = [:]
  var recorded: [(TaskBoardKeyMaterialStore.Scope, TaskBoardKeyMaterialSnapshot)] = []

  func load(scope: TaskBoardKeyMaterialStore.Scope) throws -> TaskBoardKeyMaterialSnapshot {
    snapshots[scope] ?? TaskBoardKeyMaterialSnapshot()
  }

  func save(_ snapshot: TaskBoardKeyMaterialSnapshot, scope: TaskBoardKeyMaterialStore.Scope) throws
  {
    snapshots[scope] = snapshot
    if !snapshot.isEmpty {
      recorded.append((scope, snapshot))
    }
  }

  func delete(scope: TaskBoardKeyMaterialStore.Scope) throws {
    snapshots.removeValue(forKey: scope)
  }
}
