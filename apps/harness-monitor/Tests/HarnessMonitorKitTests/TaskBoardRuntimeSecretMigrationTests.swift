import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Task-board runtime-secret migration")
struct TaskBoardRuntimeSecretMigrationTests {
  private let instanceID = "database-one"

  @Test("Prepare remains server-authoritative across repeated connections")
  func repeatedConnectionsQueryPrepare() async {
    let client = RecordingHarnessClient()
    let keychain = InMemoryKeychainBundle()

    let first = await HarnessMonitorStore.migrateRuntimeSecretsIfNeeded(
      client: client,
      instanceID: instanceID,
      ownership: .managed,
      keychain: keychain.persistence
    )
    let second = await HarnessMonitorStore.migrateRuntimeSecretsIfNeeded(
      client: client,
      instanceID: instanceID,
      ownership: .managed,
      keychain: keychain.persistence
    )

    #expect(first)
    #expect(second)
    #expect(
      client.recordedCalls().filter { call in
        if case .prepareTaskBoardSecretHandoff = call { return true }
        return false
      }.count == 2
    )
  }

  @Test("Prepared secrets are verified in the database scope before acknowledgement")
  func verifiesPreparedSecretsThenAcknowledges() async {
    let client = RecordingHarnessClient()
    client.taskBoardSecretHandoffPrepareValue =
      TaskBoardGitRuntimeSecretHandoffPrepareResponse(
        prepared: true,
        migrationID: "migration-1",
        digest: "digest-1",
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
    let keychain = InMemoryKeychainBundle()

    let succeeded = await HarnessMonitorStore.migrateRuntimeSecretsIfNeeded(
      client: client,
      instanceID: instanceID,
      ownership: .managed,
      keychain: keychain.persistence
    )

    #expect(succeeded)
    let globalSSH = keychain.ssh.snapshots[.databaseGlobal(instanceID)]
    #expect(globalSSH?.privateKey == "global-ssh-secret")
    #expect(globalSSH?.passphrase == "global-ssh-pass")
    #expect(globalSSH?.keyPath == "/keys/id_ed25519")
    let globalGPG = keychain.gpg.snapshots[.databaseGlobal(instanceID)]
    #expect(globalGPG?.privateKey == "global-gpg-secret")
    #expect(globalGPG?.keyId == "ABC123")
    let repoSSH = keychain.ssh.snapshots[.databaseRepository(instanceID, "owner/repo")]
    #expect(repoSSH?.privateKey == "repo-ssh-secret")
    #expect(
      client.recordedCalls().contains(
        .ackTaskBoardSecretHandoff(
          migrationID: "migration-1",
          digest: "digest-1"
        )
      )
    )

  }

  @Test("Same-ownership databases use isolated Keychain scopes")
  func databaseScopesStayIsolated() throws {
    let keychain = InMemoryKeychainBundle()
    try HarnessMonitorStore.persistKeyMaterial(
      runtime: TaskBoardGitRuntimeConfig(
        global: TaskBoardGitRuntimeProfile(sshPrivateKey: "first")
      ),
      instanceID: "database-one",
      ownership: .external,
      keychain: keychain.persistence
    )
    try HarnessMonitorStore.persistKeyMaterial(
      runtime: TaskBoardGitRuntimeConfig(
        global: TaskBoardGitRuntimeProfile(sshPrivateKey: "second")
      ),
      instanceID: "database-two",
      ownership: .external,
      keychain: keychain.persistence
    )

    #expect(keychain.ssh.snapshots[.databaseGlobal("database-one")]?.privateKey == "first")
    #expect(keychain.ssh.snapshots[.databaseGlobal("database-two")]?.privateKey == "second")
  }

  @Test("Read-back mismatch does not acknowledge")
  func readBackMismatchDoesNotAcknowledge() async {
    let client = RecordingHarnessClient()
    client.taskBoardSecretHandoffPrepareValue =
      TaskBoardGitRuntimeSecretHandoffPrepareResponse(
        prepared: true,
        migrationID: "migration-corrupt",
        digest: "digest-corrupt",
        runtime: TaskBoardGitRuntimeConfig(
          global: TaskBoardGitRuntimeProfile(sshPrivateKey: "secret")
        )
      )
    let keychain = InMemoryKeychainBundle()
    keychain.ssh.corruptReads = true

    let succeeded = await HarnessMonitorStore.migrateRuntimeSecretsIfNeeded(
      client: client,
      instanceID: instanceID,
      ownership: .managed,
      keychain: keychain.persistence
    )

    #expect(!succeeded)
    #expect(
      client.recordedCalls().contains { call in
        if case .ackTaskBoardSecretHandoff = call { return true }
        return false
      } == false
    )
  }

  @Test("Acknowledgement failure retries the same prepared handoff")
  func acknowledgementFailureKeepsRetrying() async {
    let client = RecordingHarnessClient()
    client.taskBoardSecretHandoffPrepareValue =
      TaskBoardGitRuntimeSecretHandoffPrepareResponse(
        prepared: true,
        migrationID: "migration-retry",
        digest: "digest-retry",
        runtime: TaskBoardGitRuntimeConfig(
          global: TaskBoardGitRuntimeProfile(sshPrivateKey: "secret")
        )
      )
    client.configureTaskBoardSecretHandoffAckError(
      HarnessMonitorAPIError.server(code: 503, message: "retry")
    )
    let keychain = InMemoryKeychainBundle()

    let first = await HarnessMonitorStore.migrateRuntimeSecretsIfNeeded(
      client: client,
      instanceID: instanceID,
      ownership: .managed,
      keychain: keychain.persistence
    )
    client.configureTaskBoardSecretHandoffAckError(nil)
    let second = await HarnessMonitorStore.migrateRuntimeSecretsIfNeeded(
      client: client,
      instanceID: instanceID,
      ownership: .managed,
      keychain: keychain.persistence
    )

    #expect(!first)
    #expect(second)
    #expect(keychain.ssh.snapshots[.databaseGlobal(instanceID)]?.privateKey == "secret")
  }

  @Test("Redacted configured runtime keeps its secret-presence flags")
  func redactedRuntimeKeepsConfiguredFlags() {
    let runtime = TaskBoardGitRuntimeConfig(
      global: TaskBoardGitRuntimeProfile(
        sshPrivateKeyConfigured: true,
        sshPrivateKeyPassphraseConfigured: true,
        signing: TaskBoardGitSigningConfig(
          sshPrivateKeyConfigured: true,
          sshPrivateKeyPassphraseConfigured: true,
          gpgPrivateKeyConfigured: true,
          gpgPrivateKeyPassphraseConfigured: true
        )
      )
    )

    let hydrated = HarnessMonitorStore.hydrateKeyMaterial(
      into: runtime,
      instanceID: instanceID,
      ownership: .external,
      keychain: InMemoryKeychainBundle().persistence
    )

    #expect(hydrated.global.sshPrivateKey == nil)
    #expect(hydrated.global.sshPrivateKeyConfigured)
    #expect(hydrated.global.sshPrivateKeyPassphraseConfigured)
    #expect(hydrated.global.signing.sshPrivateKeyConfigured)
    #expect(hydrated.global.signing.sshPrivateKeyPassphraseConfigured)
    #expect(hydrated.global.signing.gpgPrivateKeyConfigured)
    #expect(hydrated.global.signing.gpgPrivateKeyPassphraseConfigured)
  }

  @Test("Handoff merges file secrets with existing legacy Keychain material")
  func handoffMergesMixedLegacySources() async {
    let client = RecordingHarnessClient()
    client.taskBoardSecretHandoffPrepareValue =
      TaskBoardGitRuntimeSecretHandoffPrepareResponse(
        prepared: true,
        migrationID: "migration-mixed",
        digest: "digest-mixed",
        runtime: TaskBoardGitRuntimeConfig(
          global: TaskBoardGitRuntimeProfile(
            sshPrivateKey: "file-ssh-wins",
            signing: TaskBoardGitSigningConfig(
              mode: .gpg,
              gpgPrivateKey: "file-gpg",
              gpgPrivateKeyPassphrase: "file-gpg-passphrase"
            )
          )
        )
      )
    let keychain = InMemoryKeychainBundle()
    keychain.ssh.snapshots[.global] = TaskBoardKeyMaterialSnapshot(
      privateKey: "legacy-ssh",
      passphrase: "legacy-ssh-passphrase"
    )

    let succeeded = await HarnessMonitorStore.migrateRuntimeSecretsIfNeeded(
      client: client,
      instanceID: instanceID,
      ownership: .managed,
      keychain: keychain.persistence
    )

    #expect(succeeded)
    let ssh = keychain.ssh.snapshots[.databaseGlobal(instanceID)]
    #expect(ssh?.privateKey == "file-ssh-wins")
    #expect(ssh?.passphrase == "legacy-ssh-passphrase")
    let gpg = keychain.gpg.snapshots[.databaseGlobal(instanceID)]
    #expect(gpg?.privateKey == "file-gpg")
    #expect(gpg?.passphrase == "file-gpg-passphrase")
    #expect(keychain.ssh.snapshots[.global] == nil)
    #expect(
      client.recordedCalls().contains(
        .ackTaskBoardSecretHandoff(migrationID: "migration-mixed", digest: "digest-mixed")
      )
    )
  }

  @Test("Managed legacy material moves once and clearing cannot resurrect it")
  func legacyMaterialMovesThenClears() throws {
    let keychain = InMemoryKeychainBundle()
    keychain.ssh.snapshots[.global] = TaskBoardKeyMaterialSnapshot(privateKey: "legacy")

    let hydrated = HarnessMonitorStore.hydrateKeyMaterial(
      into: TaskBoardGitRuntimeConfig(),
      instanceID: instanceID,
      ownership: .managed,
      keychain: keychain.persistence
    )
    #expect(hydrated.global.sshPrivateKey == "legacy")
    #expect(keychain.ssh.snapshots[.global] == nil)

    try HarnessMonitorStore.persistKeyMaterial(
      runtime: TaskBoardGitRuntimeConfig(),
      instanceID: instanceID,
      ownership: .managed,
      keychain: keychain.persistence
    )
    let afterClear = HarnessMonitorStore.hydrateKeyMaterial(
      into: TaskBoardGitRuntimeConfig(),
      instanceID: instanceID,
      ownership: .managed,
      keychain: keychain.persistence
    )
    #expect(afterClear.global.sshPrivateKey == nil)
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
  var corruptReads = false

  func load(scope: TaskBoardKeyMaterialStore.Scope) throws -> TaskBoardKeyMaterialSnapshot {
    if corruptReads {
      return TaskBoardKeyMaterialSnapshot()
    }
    return snapshots[scope] ?? TaskBoardKeyMaterialSnapshot()
  }

  func save(_ snapshot: TaskBoardKeyMaterialSnapshot, scope: TaskBoardKeyMaterialStore.Scope) throws
  {
    if snapshot.isEmpty {
      snapshots.removeValue(forKey: scope)
    } else {
      snapshots[scope] = snapshot
      recorded.append((scope, snapshot))
    }
  }

  func delete(scope: TaskBoardKeyMaterialStore.Scope) throws {
    snapshots.removeValue(forKey: scope)
  }
}
