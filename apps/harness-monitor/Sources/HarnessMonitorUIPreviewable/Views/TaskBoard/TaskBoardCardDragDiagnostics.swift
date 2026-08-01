import HarnessMonitorKit
import SwiftUI

private let taskBoardCardDragTracingIsEnabled: Bool = {
  HarnessMonitorUITestEnvironment.isEnabled
    || ProcessInfo.processInfo.environment["HARNESS_MONITOR_TASK_BOARD_DRAG_TRACE"] == "1"
}()

func traceTaskBoardCardDrag(_ message: @autoclosure () -> String) {
  guard taskBoardCardDragTracingIsEnabled else {
    return
  }
  let renderedMessage = message()
  HarnessMonitorLogger.swiftui.notice("task-board-drag \(renderedMessage, privacy: .public)")
}

struct TaskBoardDropSessionTrace: Equatable {
  struct Metrics {
    var elapsedMilliseconds: Int
    var itemsCount: Int
    var suggestedOperationsRawValue: Int
  }

  private(set) var sessionID = ""
  private(set) var phaseCounts: [String: Int] = [:]
  private(set) var firstLocation: CGPoint?
  private(set) var lastLocation: CGPoint?
  private(set) var minimumLocation: CGPoint?
  private(set) var maximumLocation: CGPoint?
  private(set) var destinationSize: CGSize = .zero
  private(set) var firstActiveElapsedMilliseconds: Int?
  private(set) var lastElapsedMilliseconds = 0
  private(set) var itemsCount = 0
  private(set) var suggestedOperationsRawValue = 0

  mutating func record(
    sessionID: String,
    phase: String,
    location: CGPoint,
    destinationSize: CGSize,
    metrics: Metrics
  ) {
    self.sessionID = sessionID
    phaseCounts[phase, default: 0] += 1
    firstLocation = firstLocation ?? location
    lastLocation = location
    minimumLocation =
      minimumLocation.map {
        CGPoint(x: min($0.x, location.x), y: min($0.y, location.y))
      } ?? location
    maximumLocation =
      maximumLocation.map {
        CGPoint(x: max($0.x, location.x), y: max($0.y, location.y))
      } ?? location
    self.destinationSize = destinationSize
    if phase == "active", firstActiveElapsedMilliseconds == nil {
      firstActiveElapsedMilliseconds = metrics.elapsedMilliseconds
    }
    lastElapsedMilliseconds = metrics.elapsedMilliseconds
    itemsCount = metrics.itemsCount
    suggestedOperationsRawValue = metrics.suggestedOperationsRawValue
  }

  var summary: String {
    let phases =
      phaseCounts
      .sorted { $0.key < $1.key }
      .map { "\($0.key):\($0.value)" }
      .joined(separator: ",")
    return
      "session=\(sessionID) phases=\(phases) "
      + "first=\(point(firstLocation)) last=\(point(lastLocation)) "
      + "bounds=\(point(minimumLocation))...\(point(maximumLocation)) "
      + "size=\(Int(destinationSize.width.rounded()))x\(Int(destinationSize.height.rounded())) "
      + "first-active-ms=\(firstActiveElapsedMilliseconds.map(String.init) ?? "none") "
      + "last-ms=\(lastElapsedMilliseconds) items=\(itemsCount) "
      + "operations=\(suggestedOperationsRawValue)"
  }

  private func point(_ point: CGPoint?) -> String {
    guard let point else { return "none" }
    return "\(Int(point.x.rounded())),\(Int(point.y.rounded()))"
  }
}

@MainActor
enum TaskBoardCardDragDiagnostics {
  private static var isRecording = false
  private static var startedAt = 0.0
  private static var activeUpdates = 0
  private static var geometryUpdates = 0
  private static var hoverPhases: [String: Int] = [:]
  private static var hoverResolutions: [String: Int] = [:]
  private static var hoverMutations: [String: Int] = [:]
  private static var dropSessions: [String: TaskBoardDropSessionTrace] = [:]

  static func begin() {
    guard taskBoardCardDragTracingIsEnabled else {
      return
    }
    startedAt = ProcessInfo.processInfo.systemUptime
    activeUpdates = 0
    geometryUpdates = 0
    hoverPhases = [:]
    hoverResolutions = [:]
    hoverMutations = [:]
    dropSessions = [:]
    isRecording = true
  }

  static func recordActiveUpdate() {
    guard isRecording else { return }
    activeUpdates += 1
  }

  static func recordGeometryUpdate() {
    guard isRecording else { return }
    geometryUpdates += 1
  }

  static func recordHoverPhase(lane: String) {
    guard isRecording else { return }
    hoverPhases[lane, default: 0] += 1
  }

  static func recordHoverResolution(lane: String) {
    guard isRecording else { return }
    hoverResolutions[lane, default: 0] += 1
  }

  static func recordHoverMutation(lane: String) {
    guard isRecording else { return }
    hoverMutations[lane, default: 0] += 1
  }

  static func recordDropSession(_ session: DropSession, lane: String) {
    guard isRecording else { return }
    let phase = taskBoardDropSessionPhaseName(session.phase)
    var trace = dropSessions[lane] ?? TaskBoardDropSessionTrace()
    let isFirstActive = phase == "active" && trace.phaseCounts[phase] == nil
    trace.record(
      sessionID: String(session.id.hashValue, radix: 16),
      phase: phase,
      location: session.location,
      destinationSize: session.size,
      metrics: TaskBoardDropSessionTrace.Metrics(
        elapsedMilliseconds: Int(
          ((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000).rounded()
        ),
        itemsCount: session.itemsCount,
        suggestedOperationsRawValue: session.suggestedOperations.rawValue
      )
    )
    dropSessions[lane] = trace
    if phase != "active" || isFirstActive {
      traceTaskBoardCardDrag(
        "drop-session lane=\(lane) phase=\(phase) "
          + "location=\(Int(session.location.x.rounded())),"
          + "\(Int(session.location.y.rounded())) "
          + "size=\(Int(session.size.width.rounded()))x"
          + "\(Int(session.size.height.rounded()))"
      )
    }
  }

  static func finish() {
    guard isRecording else { return }
    traceTaskBoardCardDrag(
      "session-summary active=\(activeUpdates) geometry=\(geometryUpdates) "
        + "hover-phases=\(formatted(hoverPhases)) "
        + "hover-resolutions=\(formatted(hoverResolutions)) "
        + "hover-mutations=\(formatted(hoverMutations)) "
        + "drop-sessions=\(formattedDropSessions())"
    )
    isRecording = false
  }

  private static func formatted(_ counts: [String: Int]) -> String {
    counts
      .sorted { $0.key < $1.key }
      .map { "\($0.key):\($0.value)" }
      .joined(separator: ",")
  }

  private static func formattedDropSessions() -> String {
    guard !dropSessions.isEmpty else { return "none" }
    return
      dropSessions
      .sorted { $0.key < $1.key }
      .map { "\($0.key){\($0.value.summary)}" }
      .joined(separator: "|")
  }
}

/// Pure routing decision for a drag-session phase update, extracted so it stays testable without
/// a live `TaskBoardOverviewView`. The initial phase supplies the dragged IDs, so reading them
/// again during every active pointer update only adds work to the continuous interaction path.
enum TaskBoardCardDragSessionDecision: Equatable {
  case processInitial
  case clear
  case ignore
}

func taskBoardCardDragSessionDecision(
  for phase: DragSession.Phase,
  isActionInFlight: Bool
) -> TaskBoardCardDragSessionDecision {
  switch phase {
  case .initial:
    isActionInFlight ? .ignore : .processInitial
  case .active:
    .ignore
  case .ended(let operation):
    operation == .move || operation == .copy ? .ignore : .clear
  case .dataTransferCompleted:
    .clear
  @unknown default:
    .clear
  }
}

func taskBoardCardDragSessionShouldCommitGap(for phase: DragSession.Phase) -> Bool {
  guard case .ended(let operation) = phase else { return false }
  return operation == .move || operation == .copy
}
