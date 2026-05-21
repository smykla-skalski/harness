import Foundation

struct TaskBoardStoredCredentialSnapshot: Sendable {
  let githubCredentials: TaskBoardGitHubCredentialSnapshot
  let todoistCredentials: TaskBoardTodoistCredentialSnapshot
  let openRouterCredentials: TaskBoardOpenRouterCredentialSnapshot
}

public enum TaskBoardSettingsSaveOrigin: String, Sendable {
  case settingsSecretsSaveButton
  case settingsRepositoriesSaveButton
}

protocol TaskBoardGitHubCredentialPersisting: Sendable {
  func load() throws -> TaskBoardGitHubCredentialSnapshot
  func save(_ snapshot: TaskBoardGitHubCredentialSnapshot) throws
  func delete() throws
}

protocol TaskBoardTodoistCredentialPersisting: Sendable {
  func load() throws -> TaskBoardTodoistCredentialSnapshot
  func save(_ snapshot: TaskBoardTodoistCredentialSnapshot) throws
  func delete() throws
}

protocol TaskBoardOpenRouterCredentialPersisting: Sendable {
  func load() throws -> TaskBoardOpenRouterCredentialSnapshot
  func save(_ snapshot: TaskBoardOpenRouterCredentialSnapshot) throws
  func delete() throws
}

struct TaskBoardCredentialPersistence: Sendable {
  let github: any TaskBoardGitHubCredentialPersisting
  let todoist: any TaskBoardTodoistCredentialPersisting
  let openRouter: any TaskBoardOpenRouterCredentialPersisting

  /// Real Keychain in normal runs; in-memory stand-ins under xctest so test
  /// processes never trigger the macOS Keychain access prompt.
  static var defaultKeychain: Self {
    if HarnessMonitorEnvironment.current.isXCTestProcess {
      return .inMemory
    }
    return Self(
      github: TaskBoardGitHubCredentialStore(),
      todoist: TaskBoardTodoistCredentialStore(),
      openRouter: TaskBoardOpenRouterCredentialStore()
    )
  }
}

actor TaskBoardSettingsWorker {
  private let credentialPersistence: TaskBoardCredentialPersistence
  private let keyMaterialPersistence: TaskBoardKeyMaterialPersistence

  init(
    credentialPersistence: TaskBoardCredentialPersistence = .defaultKeychain,
    keyMaterialPersistence: TaskBoardKeyMaterialPersistence = .defaultKeychain
  ) {
    self.credentialPersistence = credentialPersistence
    self.keyMaterialPersistence = keyMaterialPersistence
  }

  func loadStoredCredentials() throws -> TaskBoardStoredCredentialSnapshot {
    try TaskBoardStoredCredentialSnapshot(
      githubCredentials: credentialPersistence.github.load(),
      todoistCredentials: credentialPersistence.todoist.load(),
      openRouterCredentials: credentialPersistence.openRouter.load()
    )
  }

  func hydrateKeyMaterial(into runtime: TaskBoardGitRuntimeConfig) -> TaskBoardGitRuntimeConfig {
    HarnessMonitorStore.hydrateKeyMaterial(into: runtime, keychain: keyMaterialPersistence)
  }

  fileprivate func persistLocalSecrets(
    snapshot: TaskBoardGitSettingsSnapshot,
    origin: TaskBoardSettingsSaveOrigin
  ) throws {
    switch origin {
    case .settingsSecretsSaveButton, .settingsRepositoriesSaveButton:
      break
    }
    try credentialPersistence.github.save(snapshot.githubCredentials)
    try credentialPersistence.todoist.save(snapshot.todoistCredentials)
    try credentialPersistence.openRouter.save(snapshot.openRouterCredentials)
    try HarnessMonitorStore.persistKeyMaterial(
      runtime: snapshot.runtimeConfig,
      keychain: keyMaterialPersistence
    )
  }

  private func persistKeyMaterial(runtime: TaskBoardGitRuntimeConfig) throws {
    try HarnessMonitorStore.persistKeyMaterial(runtime: runtime, keychain: keyMaterialPersistence)
  }

  func drainRuntimeSecretsIfNeeded(
    client: any HarnessMonitorClientProtocol
  ) async -> Bool {
    do {
      let response = try await client.drainTaskBoardGitRuntimeSecrets()
      if response.drained {
        try persistKeyMaterial(runtime: response.runtime)
      }
      return true
    } catch {
      return false
    }
  }

  func waitForIdle() {}
}
