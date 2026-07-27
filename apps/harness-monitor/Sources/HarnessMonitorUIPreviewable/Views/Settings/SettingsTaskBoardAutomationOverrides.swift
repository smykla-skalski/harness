import HarnessMonitorKit

/// The publication conventions one repository can override, in the order the
/// settings pane lists them.
enum SettingsRepositoryAutomationOverrideKind: String, CaseIterable, Identifiable {
  case requestedReviewers
  case protectedPaths
  case labels
  case automations

  var id: String { rawValue }

  var title: String {
    switch self {
    case .requestedReviewers: "Requested Reviewers"
    case .protectedPaths: "Protected Paths"
    case .labels: "Labels"
    case .automations: "Automations"
    }
  }
}

/// Reads and writes one repository's publication overrides inside the task-board
/// draft. A `nil` group means the repository inherits the global value; the
/// daemon applies the same rule, so nothing here decides policy on its own.
extension TaskBoardGitSettingsDraft {
  var globalRequestedReviewers: GitHubRequestedReviewersWire {
    GitHubRequestedReviewersWire(
      reviewers: normalizedLines(from: requestedReviewersText),
      teamReviewers: normalizedLines(from: requestedTeamReviewersText)
    )
  }

  var globalProtectedPaths: [ProtectedPathRuleWire] {
    normalizedLines(from: protectedPathsText).map(ProtectedPathRuleWire.init(pattern:))
  }

  var globalLabels: GitHubAutomationLabelsWire {
    GitHubAutomationLabelsWire(
      managed: managedLabel,
      autoMerge: autoMergeLabel,
      needsHuman: needsHumanLabel,
      protectedPath: protectedPathLabel
    )
  }

  var globalAutomations: GitHubAutomationTogglesWire {
    GitHubAutomationTogglesWire(enabled: enabledAutomations.sorted { $0.rawValue < $1.rawValue })
  }

  func automationConfig(for repository: String) -> TaskBoardRepositoryAutomationConfig? {
    guard let slug = Self.canonicalSlug(repository) else { return nil }
    return automationRepositories.first { Self.canonicalSlug($0.repository) == slug }
  }

  func overriddenKinds(for repository: String) -> [SettingsRepositoryAutomationOverrideKind] {
    guard let config = automationConfig(for: repository) else { return [] }
    return SettingsRepositoryAutomationOverrideKind.allCases.filter { kind in
      switch kind {
      case .requestedReviewers: config.requestedReviewers != nil
      case .protectedPaths: config.protectedPaths != nil
      case .labels: config.labels != nil
      case .automations: config.enabledAutomations != nil
      }
    }
  }

  func overrides(_ kind: SettingsRepositoryAutomationOverrideKind, for repository: String) -> Bool {
    overriddenKinds(for: repository).contains(kind)
  }

  func requestedReviewers(for repository: String) -> GitHubRequestedReviewersWire {
    automationConfig(for: repository)?.requestedReviewers ?? globalRequestedReviewers
  }

  func protectedPaths(for repository: String) -> [ProtectedPathRuleWire] {
    automationConfig(for: repository)?.protectedPaths ?? globalProtectedPaths
  }

  func labels(for repository: String) -> GitHubAutomationLabelsWire {
    automationConfig(for: repository)?.labels ?? globalLabels
  }

  func automations(for repository: String) -> GitHubAutomationTogglesWire {
    automationConfig(for: repository)?.enabledAutomations ?? globalAutomations
  }

  mutating func setRequestedReviewers(
    _ value: GitHubRequestedReviewersWire?,
    for repository: String
  ) {
    updateAutomationConfig(for: repository) { $0.requestedReviewers = value }
  }

  mutating func setProtectedPaths(_ value: [ProtectedPathRuleWire]?, for repository: String) {
    updateAutomationConfig(for: repository) { $0.protectedPaths = value }
  }

  mutating func setLabels(_ value: GitHubAutomationLabelsWire?, for repository: String) {
    updateAutomationConfig(for: repository) { $0.labels = value }
  }

  mutating func setAutomations(_ value: GitHubAutomationTogglesWire?, for repository: String) {
    updateAutomationConfig(for: repository) { $0.enabledAutomations = value }
  }

  /// Start overriding `kind` from the value the repository resolves to today, so
  /// switching the override on changes nothing until the fields are edited.
  mutating func beginOverriding(
    _ kind: SettingsRepositoryAutomationOverrideKind,
    for repository: String
  ) {
    switch kind {
    case .requestedReviewers:
      setRequestedReviewers(requestedReviewers(for: repository), for: repository)
    case .protectedPaths:
      setProtectedPaths(protectedPaths(for: repository), for: repository)
    case .labels:
      setLabels(labels(for: repository), for: repository)
    case .automations:
      setAutomations(automations(for: repository), for: repository)
    }
  }

  mutating func stopOverriding(
    _ kind: SettingsRepositoryAutomationOverrideKind,
    for repository: String
  ) {
    switch kind {
    case .requestedReviewers: setRequestedReviewers(nil, for: repository)
    case .protectedPaths: setProtectedPaths(nil, for: repository)
    case .labels: setLabels(nil, for: repository)
    case .automations: setAutomations(nil, for: repository)
    }
  }

  private mutating func updateAutomationConfig(
    for repository: String,
    _ mutate: (inout TaskBoardRepositoryAutomationConfig) -> Void
  ) {
    guard let slug = Self.canonicalSlug(repository) else { return }
    let index = automationRepositories.firstIndex { Self.canonicalSlug($0.repository) == slug }
    var config =
      index.map { automationRepositories[$0] }
      ?? TaskBoardRepositoryAutomationConfig(repository: slug)
    mutate(&config)

    // An entry that says nothing is worse than no entry: it survives every save
    // and reads as configuration the repository does not actually carry.
    let isInert = config == TaskBoardRepositoryAutomationConfig(repository: config.repository)
    switch (index, isInert) {
    case (let index?, true): automationRepositories.remove(at: index)
    case (let index?, false): automationRepositories[index] = config
    case (nil, false): automationRepositories.append(config)
    case (nil, true): break
    }
  }

  /// Match the way the daemon canonicalizes a slug before it looks an override
  /// up. A stored value the daemon still resolves must not read as missing
  /// here, or the pane offers to configure a repository that already is.
  private static func canonicalSlug(_ repository: String) -> String? {
    SettingsGitHubRepositoryNormalization.repositoryEntry(repository)
  }

  private func normalizedLines(from value: String) -> [String] {
    var entries: [String] = []
    var seen: Set<String> = []
    for line in value.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
      entries.append(trimmed)
    }
    return entries
  }
}
