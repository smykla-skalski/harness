import Foundation

public enum ReviewsPolicyDefaults {
    public static let workflowID = "reviews_auto"
}

public struct ReviewsPolicySubject: Codable, Equatable, Sendable {
    public var repository: String
    public var pullRequestNumber: UInt64

    public init(
        repository: String,
        pullRequestNumber: UInt64
    ) {
        self.repository = repository
        self.pullRequestNumber = pullRequestNumber
    }

    public init(target: ReviewTarget) {
        self.init(
            repository: target.repository,
            pullRequestNumber: target.number
        )
    }

    public var subjectKey: String {
        "\(repository)#\(pullRequestNumber)"
    }
}

public enum ReviewsPolicyTrigger: TaskBoardOpenEnum, CaseIterable, Identifiable {
    case manual
    case background
    case unknown(String)

    public static let allCases: [Self] = [.manual, .background]
    public var id: String { rawValue }

    public var rawValue: String {
        switch self {
        case .manual: "manual"
        case .background: "background"
        case .unknown(let raw): raw
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "manual": self = .manual
        case "background": self = .background
        default: self = .unknown(rawValue)
        }
    }
}

public enum ReviewsPolicyRunStatus: TaskBoardOpenEnum, CaseIterable, Identifiable {
    case pending
    case running
    case waiting
    case completed
    case failed
    case cancelled
    case unknown(String)

    public static let allCases: [Self] = [.pending, .running, .waiting, .completed, .failed, .cancelled]
    public var id: String { rawValue }

    public var rawValue: String {
        switch self {
        case .pending: "pending"
        case .running: "running"
        case .waiting: "waiting"
        case .completed: "completed"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .unknown(let raw): raw
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "pending": self = .pending
        case "running": self = .running
        case "waiting": self = .waiting
        case "completed": self = .completed
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        default: self = .unknown(rawValue)
        }
    }

    public var isActive: Bool {
        self == .pending || self == .running || self == .waiting
    }
}

public enum ReviewsPolicyStepType: TaskBoardOpenEnum, CaseIterable, Identifiable {
    case action
    case wait
    case unknown(String)

    public static let allCases: [Self] = [.action, .wait]
    public var id: String { rawValue }

    public var rawValue: String {
        switch self {
        case .action: "action"
        case .wait: "wait"
        case .unknown(let raw): raw
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "action": self = .action
        case "wait": self = .wait
        default: self = .unknown(rawValue)
        }
    }
}

public struct ReviewsPolicyWait: Codable, Equatable, Sendable {
    public var eventKey: String?
    public var durationSeconds: Int?

    public init(
        eventKey: String? = nil,
        durationSeconds: Int? = nil
    ) {
        self.eventKey = eventKey
        self.durationSeconds = durationSeconds
    }
}

public struct ReviewsPolicyPreviewStep: Codable, Equatable, Sendable {
    public var stepType: ReviewsPolicyStepType
    public var actionKey: String?
    public var waitingOn: ReviewsPolicyWait?

    public init(
        stepType: ReviewsPolicyStepType,
        actionKey: String? = nil,
        waitingOn: ReviewsPolicyWait? = nil
    ) {
        self.stepType = stepType
        self.actionKey = actionKey
        self.waitingOn = waitingOn
    }
}

public struct ReviewsPolicyPreviewRequest: Codable, Equatable, Sendable {
    public var target: ReviewTarget
    public var method: TaskBoardGitHubMergeMethod
    public var workflowID: String

    public init(
        target: ReviewTarget,
        method: TaskBoardGitHubMergeMethod,
        workflowID: String = ReviewsPolicyDefaults.workflowID
    ) {
        self.target = target
        self.method = method
        let trimmed = workflowID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.workflowID = trimmed.isEmpty ? ReviewsPolicyDefaults.workflowID : trimmed
    }

    public var normalizedWorkflowID: String {
        let trimmed = workflowID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ReviewsPolicyDefaults.workflowID : trimmed
    }

    enum CodingKeys: String, CodingKey {
        case target
        case method
        case workflowID = "workflowId"
    }
}

public struct ReviewsPolicyPreviewResponse: Codable, Equatable, Sendable {
    public var eligible: Bool
    public var reason: String?
    public var steps: [ReviewsPolicyPreviewStep]
    public var warnings: [String]

    public init(
        eligible: Bool,
        reason: String? = nil,
        steps: [ReviewsPolicyPreviewStep] = [],
        warnings: [String] = []
    ) {
        self.eligible = eligible
        self.reason = reason
        self.steps = steps
        self.warnings = warnings
    }
}

public struct ReviewsPolicyRunStartRequest: Codable, Equatable, Sendable {
    public var target: ReviewTarget
    public var method: TaskBoardGitHubMergeMethod
    public var workflowID: String
    public var trigger: ReviewsPolicyTrigger

    public init(
        target: ReviewTarget,
        method: TaskBoardGitHubMergeMethod,
        workflowID: String = ReviewsPolicyDefaults.workflowID,
        trigger: ReviewsPolicyTrigger = .manual
    ) {
        self.target = target
        self.method = method
        let trimmed = workflowID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.workflowID = trimmed.isEmpty ? ReviewsPolicyDefaults.workflowID : trimmed
        self.trigger = trigger
    }

    public var normalizedWorkflowID: String {
        let trimmed = workflowID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ReviewsPolicyDefaults.workflowID : trimmed
    }

    enum CodingKeys: String, CodingKey {
        case target
        case method
        case workflowID = "workflowId"
        case trigger
    }
}

public struct ReviewsPolicyRunStep: Codable, Equatable, Sendable {
    public var stepType: ReviewsPolicyStepType
    public var actionKey: String?
    public var waitingOn: ReviewsPolicyWait?
    public var recordedAt: String?

    public init(
        stepType: ReviewsPolicyStepType,
        actionKey: String? = nil,
        waitingOn: ReviewsPolicyWait? = nil,
        recordedAt: String? = nil
    ) {
        self.stepType = stepType
        self.actionKey = actionKey
        self.waitingOn = waitingOn
        self.recordedAt = recordedAt
    }
}

public struct ReviewsPolicyRunResponse: Codable, Equatable, Sendable {
    public var runID: String
    public var workflowID: String
    public var subject: ReviewsPolicySubject
    public var trigger: ReviewsPolicyTrigger
    public var status: ReviewsPolicyRunStatus
    public var startedAt: String
    public var updatedAt: String
    public var waitingOn: ReviewsPolicyWait?
    public var completedAt: String?
    public var errorMessage: String?
    public var steps: [ReviewsPolicyRunStep]

    public init(
        runID: String,
        workflowID: String = ReviewsPolicyDefaults.workflowID,
        subject: ReviewsPolicySubject,
        trigger: ReviewsPolicyTrigger,
        status: ReviewsPolicyRunStatus,
        startedAt: String,
        updatedAt: String,
        waitingOn: ReviewsPolicyWait? = nil,
        completedAt: String? = nil,
        errorMessage: String? = nil,
        steps: [ReviewsPolicyRunStep] = []
    ) {
        self.runID = runID
        self.workflowID = workflowID
        self.subject = subject
        self.trigger = trigger
        self.status = status
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.waitingOn = waitingOn
        self.completedAt = completedAt
        self.errorMessage = errorMessage
        self.steps = steps
    }

    enum CodingKeys: String, CodingKey {
        case runID = "runId"
        case workflowID = "workflowId"
        case subject
        case trigger
        case status
        case startedAt
        case updatedAt
        case waitingOn
        case completedAt
        case errorMessage
        case steps
    }
}

public struct ReviewsPolicyStatusRequest: Codable, Equatable, Sendable {
    public var subject: ReviewsPolicySubject
    public var workflowID: String

    public init(
        subject: ReviewsPolicySubject,
        workflowID: String = ReviewsPolicyDefaults.workflowID
    ) {
        self.subject = subject
        let trimmed = workflowID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.workflowID = trimmed.isEmpty ? ReviewsPolicyDefaults.workflowID : trimmed
    }

    public init(
        target: ReviewTarget,
        workflowID: String = ReviewsPolicyDefaults.workflowID
    ) {
        self.init(
            subject: ReviewsPolicySubject(target: target),
            workflowID: workflowID
        )
    }

    public var normalizedWorkflowID: String {
        let trimmed = workflowID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ReviewsPolicyDefaults.workflowID : trimmed
    }

    enum CodingKeys: String, CodingKey {
        case subject
        case workflowID = "workflowId"
    }
}

public struct ReviewsPolicyStatusResponse: Codable, Equatable, Sendable {
    public var activeRun: ReviewsPolicyRunResponse?
    public var recentRuns: [ReviewsPolicyRunResponse]

    public init(
        activeRun: ReviewsPolicyRunResponse? = nil,
        recentRuns: [ReviewsPolicyRunResponse] = []
    ) {
        self.activeRun = activeRun
        self.recentRuns = recentRuns
    }
}

public extension ReviewTarget {
    var reviewsPolicySubject: ReviewsPolicySubject {
        ReviewsPolicySubject(target: self)
    }
}
