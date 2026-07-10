import Foundation
import HarnessMonitorKit

enum DispatchStatusFilterChoice: String, CaseIterable, Hashable {
  case all
  case umbrella
  case todo
  case planning
  case inProgress
  case agenticReview
  case testing
  case inReview
  case toReview
  case humanRequired
  case failed
  case done
  case new
  case planReview
  case needsYou
  case blocked

  private static let statusChoices: [TaskBoardStatus: Self] = [
    .umbrella: .umbrella,
    .todo: .todo,
    .planning: .planning,
    .inProgress: .inProgress,
    .agenticReview: .agenticReview,
    .testing: .testing,
    .inReview: .inReview,
    .toReview: .toReview,
    .humanRequired: .humanRequired,
    .failed: .failed,
    .done: .done,
    .new: .new,
    .planReview: .planReview,
    .needsYou: .needsYou,
    .blocked: .blocked,
  ]

  init(status: TaskBoardStatus?) {
    self = status.flatMap { Self.statusChoices[$0] } ?? .all
  }
}

extension DispatchStatusFilterChoice {
  var title: String {
    switch self {
    case .all: "All Items"
    case .umbrella: "Umbrella"
    case .todo: "Todo"
    case .planning: "Planning"
    case .inProgress: "In Progress"
    case .agenticReview: "Agentic Review"
    case .testing: "Testing"
    case .inReview: "In Review"
    case .toReview: "To Review"
    case .humanRequired: "Human Required"
    case .failed: "Failed"
    case .done: "Done"
    case .new: "New"
    case .planReview: "Plan Review"
    case .needsYou: "Needs You"
    case .blocked: "Blocked"
    }
  }

  var status: TaskBoardStatus? {
    switch self {
    case .all: nil
    case .umbrella: .umbrella
    case .todo: .todo
    case .planning: .planning
    case .inProgress: .inProgress
    case .agenticReview: .agenticReview
    case .testing: .testing
    case .inReview: .inReview
    case .toReview: .toReview
    case .humanRequired: .humanRequired
    case .failed: .failed
    case .done: .done
    case .new: .new
    case .planReview: .planReview
    case .needsYou: .needsYou
    case .blocked: .blocked
    }
  }
}

extension TaskBoardOrchestratorWorkflow {
  var title: String {
    switch self {
    case .defaultTask: "Default Task"
    case .prFix: "PR Fix"
    case .prReview: "PR Review"
    case .review: "Review"
    case .unknown(let raw): raw
    }
  }
}

extension TaskBoardGitHubMergeMethod {
  var title: String {
    switch self {
    case .squash: "Squash"
    case .merge: "Merge Commit"
    case .rebase: "Rebase"
    case .unknown(let raw): raw
    }
  }
}

extension TaskBoardGitHubAutomation {
  var title: String {
    switch self {
    case .syncTaskBoard: "Sync Task Board"
    case .createBranch: "Create Branch"
    case .openPullRequest: "Open Pull Request"
    case .watchChecks: "Watch Checks"
    case .requestReview: "Request Review"
    case .autoMerge: "Auto Merge"
    }
  }
}

struct TaskBoardRepositoryOverrideDraft: Identifiable, Equatable {
  let id: UUID
  var repository = ""
  var authorName = ""
  var authorEmail = ""
  var sshKeyPath = ""
  var sshPrivateKey: TaskBoardSecretField = .notConfigured
  var sshPrivateKeyPassphrase: TaskBoardSecretField = .notConfigured
  var signingMode: TaskBoardGitSigningMode = .none
  var signingSSHKeyPath = ""
  var signingSSHPrivateKey: TaskBoardSecretField = .notConfigured
  var signingSSHPrivateKeyPassphrase: TaskBoardSecretField = .notConfigured
  var gpgKeyId = ""
  var gpgPrivateKeyPath = ""
  var gpgPrivateKey: TaskBoardSecretField = .notConfigured
  var gpgPrivateKeyPassphrase: TaskBoardSecretField = .notConfigured
  var token: TaskBoardSecretField = .notConfigured

  init(
    id: UUID = UUID(),
    repository: String = "",
    authorName: String = "",
    authorEmail: String = "",
    sshKeyPath: String = "",
    sshPrivateKey: TaskBoardSecretField = .notConfigured,
    sshPrivateKeyPassphrase: TaskBoardSecretField = .notConfigured,
    signingMode: TaskBoardGitSigningMode = .none,
    signingSSHKeyPath: String = "",
    signingSSHPrivateKey: TaskBoardSecretField = .notConfigured,
    signingSSHPrivateKeyPassphrase: TaskBoardSecretField = .notConfigured,
    gpgKeyId: String = "",
    gpgPrivateKeyPath: String = "",
    gpgPrivateKey: TaskBoardSecretField = .notConfigured,
    gpgPrivateKeyPassphrase: TaskBoardSecretField = .notConfigured,
    token: TaskBoardSecretField = .notConfigured
  ) {
    self.id = id
    self.repository = repository
    self.authorName = authorName
    self.authorEmail = authorEmail
    self.sshKeyPath = sshKeyPath
    self.sshPrivateKey = sshPrivateKey
    self.sshPrivateKeyPassphrase = sshPrivateKeyPassphrase
    self.signingMode = signingMode
    self.signingSSHKeyPath = signingSSHKeyPath
    self.signingSSHPrivateKey = signingSSHPrivateKey
    self.signingSSHPrivateKeyPassphrase = signingSSHPrivateKeyPassphrase
    self.gpgKeyId = gpgKeyId
    self.gpgPrivateKeyPath = gpgPrivateKeyPath
    self.gpgPrivateKey = gpgPrivateKey
    self.gpgPrivateKeyPassphrase = gpgPrivateKeyPassphrase
    self.token = token
  }

  func runtimeOverride(loaded: TaskBoardLoadedSecrets) -> TaskBoardGitRepositoryOverride? {
    guard let repository = normalized(repository), hasRuntimeOverride(loaded: loaded) else {
      return nil
    }
    let lowered = repository.lowercased()
    let perRepo = loaded.repositorySecrets(for: lowered)
    return TaskBoardGitRepositoryOverride(
      repository: lowered,
      profile: TaskBoardGitRuntimeProfile(
        authorName: normalized(authorName),
        authorEmail: normalized(authorEmail),
        sshKeyPath: normalized(sshKeyPath),
        sshPrivateKey: sshPrivateKey.materialized(loaded: perRepo.sshPrivateKey),
        sshPrivateKeyPassphrase: sshPrivateKeyPassphrase.materialized(
          loaded: perRepo.sshPrivateKeyPassphrase
        ),
        signing: TaskBoardGitSigningConfig(
          mode: signingMode,
          sshKeyPath: signingMode == .ssh ? normalized(signingSSHKeyPath) : nil,
          sshPrivateKey: signingMode == .ssh
            ? signingSSHPrivateKey.materialized(loaded: perRepo.signingSSHPrivateKey)
            : nil,
          sshPrivateKeyPassphrase: signingMode == .ssh
            ? signingSSHPrivateKeyPassphrase.materialized(
              loaded: perRepo.signingSSHPrivateKeyPassphrase
            )
            : nil,
          gpgKeyId: signingMode == .gpg ? normalized(gpgKeyId) : nil,
          gpgPrivateKeyPath: signingMode == .gpg ? normalized(gpgPrivateKeyPath) : nil,
          gpgPrivateKey: signingMode == .gpg
            ? gpgPrivateKey.materialized(loaded: perRepo.gpgPrivateKey)
            : nil,
          gpgPrivateKeyPassphrase: signingMode == .gpg
            ? gpgPrivateKeyPassphrase.materialized(loaded: perRepo.gpgPrivateKeyPassphrase)
            : nil
        )
      )
    )
  }

  func tokenOverride(loaded: TaskBoardLoadedSecrets) -> TaskBoardGitHubRepositoryToken? {
    guard let repository = normalized(repository)?.lowercased() else { return nil }
    let stored = loaded.repositoryToken(for: repository)
    guard let materialized = token.materialized(loaded: stored), !materialized.isEmpty else {
      return nil
    }
    return TaskBoardGitHubRepositoryToken(repository: repository, token: materialized)
  }

  private func hasRuntimeOverride(loaded: TaskBoardLoadedSecrets) -> Bool {
    let lowered = normalized(repository)?.lowercased()
    let perRepo = lowered.map { loaded.repositorySecrets(for: $0) }
    let hasAnySecret =
      sshPrivateKey.materialized(loaded: perRepo?.sshPrivateKey) != nil
      || sshPrivateKeyPassphrase.materialized(loaded: perRepo?.sshPrivateKeyPassphrase) != nil
      || (signingMode == .ssh
        && signingSSHPrivateKey.materialized(loaded: perRepo?.signingSSHPrivateKey) != nil)
      || (signingMode == .ssh
        && signingSSHPrivateKeyPassphrase.materialized(
          loaded: perRepo?.signingSSHPrivateKeyPassphrase
        ) != nil)
      || (signingMode == .gpg
        && gpgPrivateKey.materialized(loaded: perRepo?.gpgPrivateKey) != nil)
      || (signingMode == .gpg
        && gpgPrivateKeyPassphrase.materialized(loaded: perRepo?.gpgPrivateKeyPassphrase) != nil)
    return normalized(authorName) != nil
      || normalized(authorEmail) != nil
      || normalized(sshKeyPath) != nil
      || hasAnySecret
      || (signingMode == .ssh && normalized(signingSSHKeyPath) != nil)
      || (signingMode == .gpg && normalized(gpgKeyId) != nil)
      || (signingMode == .gpg && normalized(gpgPrivateKeyPath) != nil)
  }

  private func normalized(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

extension TaskBoardSecretField {
  static func secretFromLoaded(_ value: String?) -> Self {
    guard let value, !value.isEmpty else { return .notConfigured }
    return .configured
  }

  func materialized(loaded: String?) -> String? {
    switch self {
    case .notConfigured:
      return nil
    case .configured:
      return loaded
    case .editing(let value):
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
  }
}
