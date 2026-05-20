import HarnessMonitorKit
import SwiftUI

public enum SessionCreateKind: String, Codable, Hashable, Sendable {
  case agent
  case task
  case decision

  public var createShortcut: KeyboardShortcutDescriptor {
    switch self {
    case .agent:
      .init(modifiers: [.option, .command], keyEquivalent: "a", keyLabel: "A")
    case .task:
      .init(modifiers: [.option, .command], keyEquivalent: "t", keyLabel: "T")
    case .decision:
      .init(modifiers: [.option, .command], keyEquivalent: "d", keyLabel: "D")
    }
  }

  public var route: SessionWindowRoute {
    switch self {
    case .agent: .agents
    case .task: .tasks
    case .decision: .decisions
    }
  }

  public var createShortcutKey: KeyEquivalent {
    createShortcut.keyEquivalent
  }

  public var createShortcutModifiers: EventModifiers {
    createShortcut.requiredEventModifiers
  }

  public var createShortcutHint: String {
    createShortcut.hint
  }
}

public struct SessionCreateDraft: Codable, Hashable, Sendable {
  public var kind: SessionCreateKind
  public var title: String
  public var prompt: String
  public var runtime: String
  public var modelByRuntime: [String: String]
  public var customModelByRuntime: [String: String]
  public var effortByRuntime: [String: String]
  public var roleRawValue: String?
  public var fallbackRoleRawValue: String?
  public var personaID: String
  public var projectDir: String
  public var argvOverride: String
  public var taskSeverityRawValue: String?
  public var sessionID: String
  public var useCodex: Bool
  public var codexModeRawValue: String?
  public var codexModel: String
  public var codexEffort: String
  public var codexAllowCustomModel: Bool

  public init(
    kind: SessionCreateKind,
    title: String = "",
    prompt: String = "",
    runtime: String = AgentTuiRuntime.codex.rawValue,
    modelByRuntime: [String: String] = [:],
    customModelByRuntime: [String: String] = [:],
    effortByRuntime: [String: String] = [:],
    role: SessionRole = .worker,
    fallbackRole: SessionRole = .worker,
    personaID: String = "",
    projectDir: String = "",
    argvOverride: String = "",
    taskSeverity: TaskSeverity = .medium,
    sessionID: String,
    useCodex: Bool = false,
    codexMode: CodexRunMode = .report,
    codexModel: String = "",
    codexEffort: String = "",
    codexAllowCustomModel: Bool = false
  ) {
    self.kind = kind
    self.title = title
    self.prompt = prompt
    self.runtime = runtime
    self.modelByRuntime = modelByRuntime
    self.customModelByRuntime = customModelByRuntime
    self.effortByRuntime = effortByRuntime
    roleRawValue = role.rawValue
    fallbackRoleRawValue = fallbackRole.rawValue
    self.personaID = personaID
    self.projectDir = projectDir
    self.argvOverride = argvOverride
    taskSeverityRawValue = taskSeverity.rawValue
    self.sessionID = sessionID
    self.useCodex = useCodex
    codexModeRawValue = codexMode.rawValue
    self.codexModel = codexModel
    self.codexEffort = codexEffort
    self.codexAllowCustomModel = codexAllowCustomModel
  }

  public var taskSeverity: TaskSeverity {
    get {
      taskSeverityRawValue.flatMap(TaskSeverity.init(rawValue:)) ?? .medium
    }
    set {
      taskSeverityRawValue = newValue.rawValue
    }
  }

  public var role: SessionRole {
    get {
      roleRawValue.flatMap(SessionRole.init(rawValue:)) ?? .worker
    }
    set {
      roleRawValue = newValue.rawValue
    }
  }

  public var fallbackRole: SessionRole {
    get {
      fallbackRoleRawValue.flatMap(SessionRole.init(rawValue:)) ?? .worker
    }
    set {
      fallbackRoleRawValue = newValue.rawValue
    }
  }

  public var normalizedArgvOverride: [String] {
    argvOverride
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  public var codexMode: CodexRunMode {
    get {
      codexModeRawValue.flatMap(CodexRunMode.init(rawValue:)) ?? .report
    }
    set {
      codexModeRawValue = newValue.rawValue
    }
  }
}

public enum SessionSelection: Hashable, Sendable {
  case route(SessionWindowRoute)
  case agent(sessionID: String, agentID: String)
  case codexRun(sessionID: String, runID: String)
  case openRouterRun(sessionID: String, runID: String)
  case decision(sessionID: String, decisionID: String)
  case task(sessionID: String, taskID: String)
  case create(SessionCreateDraft)

  public var route: SessionWindowRoute? {
    guard case .route(let route) = self else { return nil }
    return route
  }

  public var agentID: String? {
    guard case .agent(_, let agentID) = self else { return nil }
    return agentID
  }

  public var codexRunID: String? {
    guard case .codexRun(_, let runID) = self else { return nil }
    return runID
  }

  public var openRouterRunID: String? {
    guard case .openRouterRun(_, let runID) = self else { return nil }
    return runID
  }

  public var decisionID: String? {
    guard case .decision(_, let decisionID) = self else { return nil }
    return decisionID
  }

  public var taskID: String? {
    guard case .task(_, let taskID) = self else { return nil }
    return taskID
  }

  public var createDraft: SessionCreateDraft? {
    guard case .create(let draft) = self else { return nil }
    return draft
  }

  /// The cross-domain search domain implied by this selection, when one
  /// exists. Drilled-in selections (`.agent`, `.decision`, `.task`) imply
  /// their parent route's domain. `.codexRun`, `.openRouterRun`, `.create`
  /// and routes without a search domain (`.overview`) return `nil`.
  public var routeDomain: AppSearchDomain? {
    switch self {
    case .agent: .agents
    case .decision: .decisions
    case .task: .tasks
    case .codexRun, .openRouterRun, .create: nil
    case .route(let route): route.appSearchDomain
    }
  }

  public var primaryCreateKind: SessionCreateKind {
    switch self {
    case .agent, .codexRun, .openRouterRun:
      .agent
    case .task:
      .task
    case .decision:
      .decision
    case .create(let draft):
      draft.kind
    case .route(let route):
      switch route {
      case .tasks:
        .task
      case .decisions:
        .decision
      case .agents, .overview, .policyCanvas, .timeline:
        .agent
      }
    }
  }
}

public enum SessionSelectionSource: Hashable, Sendable {
  case programmatic
  case sidebar
  case keyboard
  case pointer
}

public enum SessionSelectedDecisionVisibility: Equatable, Sendable {
  case none
  case visible
  case hidden
  case missing
}
