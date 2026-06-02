import HarnessMonitorPolicyCanvasAlgorithms

enum PolicyCanvasWorkflowStage: String, Hashable {
  case draft
  case validation
  case promotion
}

extension PolicyCanvasViewModel {
  static let workflowStatusSuccessFlashDuration: Duration = .seconds(3)

  var validationErrorCount: Int {
    allValidationIssues.filter { $0.severity == .error }.count
  }

  var validationWarningCount: Int {
    allValidationIssues.filter { $0.severity == .warning }.count
  }

  var draftStatusText: String {
    if isSavingDraft {
      return "Saving draft"
    }
    if backingDocument == nil {
      return "Not saved yet"
    }
    if documentDirty {
      return "Unsaved changes"
    }
    return "Saved draft"
  }

  var validationStatusText: String {
    if isSimulating {
      return "Running simulation"
    }
    guard backingDocument != nil else {
      return "Save before validation"
    }
    guard let latestSimulation else {
      return "Run simulation"
    }
    if documentDirty || latestSimulation.revision != backingDocument?.revision {
      return "Run again after changes"
    }
    if validationErrorCount > 0 {
      return "Fix \(validationErrorCount) issue\(validationErrorCount == 1 ? "" : "s")"
    }
    if validationWarningCount > 0 {
      return "Review \(validationWarningCount) warning\(validationWarningCount == 1 ? "" : "s")"
    }
    return "No issues found"
  }

  var validationSummaryText: String {
    if validationErrorCount == 0, validationWarningCount == 0 {
      return latestSimulation == nil ? "No data" : "No issues found"
    }

    var parts: [String] = []
    if validationErrorCount > 0 {
      parts.append("\(validationErrorCount) error\(validationErrorCount == 1 ? "" : "s")")
    }
    if validationWarningCount > 0 {
      parts.append("\(validationWarningCount) warning\(validationWarningCount == 1 ? "" : "s")")
    }
    return parts.joined(separator: ", ")
  }

  var promotionStatusText: String {
    if isPromoting {
      return "Promoting"
    }
    return promoteDisabledReason ?? "Ready to promote"
  }

  func workflowStatusCards(
    remoteActionsEnabled: Bool,
    remoteActionDisabledReason: String
  ) -> [PolicyCanvasWorkflowStatusCardModel] {
    [
      draftWorkflowStatusCard,
      validationWorkflowStatusCard,
      promotionWorkflowStatusCard(
        remoteActionsEnabled: remoteActionsEnabled,
        remoteActionDisabledReason: remoteActionDisabledReason
      ),
    ]
    .compactMap { $0 }
  }

  func flashWorkflowStatusStage(
    _ stage: PolicyCanvasWorkflowStage,
    clearAfter delay: Duration? = nil
  ) {
    let delay = delay ?? Self.workflowStatusSuccessFlashDuration
    workflowStatusClearTasks[stage]?.cancel()
    flashedWorkflowStatusStages.insert(stage)
    workflowStatusClearTasks[stage] = Task { @MainActor [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self else { return }
      self.flashedWorkflowStatusStages.remove(stage)
      self.workflowStatusClearTasks[stage] = nil
    }
  }

  func flashHealthyWorkflowStatusStagesAfterSimulation(remoteActionsEnabled: Bool) {
    if validationWorkflowStatusIsHealthy {
      flashWorkflowStatusStage(.validation)
    }
    if promotionWorkflowStatusIsReady(remoteActionsEnabled: remoteActionsEnabled) {
      flashWorkflowStatusStage(.promotion)
    }
  }

  private var draftWorkflowStatusCard: PolicyCanvasWorkflowStatusCardModel? {
    if isSavingDraft {
      return workflowStatusCard(
        stage: .draft,
        title: "Draft",
        detail: draftStatusText,
        systemImage: "pencil.circle.fill",
        tone: .active,
        isPersistent: true
      )
    }
    if backingDocument == nil || documentDirty {
      return workflowStatusCard(
        stage: .draft,
        title: "Draft",
        detail: draftStatusText,
        systemImage: "pencil.circle.fill",
        tone: .warning,
        isPersistent: true
      )
    }
    return workflowStatusCard(
      stage: .draft,
      title: "Draft",
      detail: draftStatusText,
      systemImage: "checkmark.circle.fill",
      tone: .ready,
      isPersistent: false
    )
  }

  private var validationWorkflowStatusCard: PolicyCanvasWorkflowStatusCardModel? {
    if isSimulating {
      return workflowStatusCard(
        stage: .validation,
        title: "Validation",
        detail: validationStatusText,
        systemImage: "play.circle.fill",
        tone: .active,
        isPersistent: true
      )
    }
    guard backingDocument != nil else {
      return nil
    }
    guard let latestSimulation else {
      return workflowStatusCard(
        stage: .validation,
        title: "Validation",
        detail: validationStatusText,
        systemImage: "play.circle.fill",
        tone: .warning,
        isPersistent: true
      )
    }
    if documentDirty || latestSimulation.revision != backingDocument?.revision {
      return workflowStatusCard(
        stage: .validation,
        title: "Validation",
        detail: validationStatusText,
        systemImage: "play.circle.fill",
        tone: .warning,
        isPersistent: true
      )
    }
    if validationErrorCount > 0 {
      return workflowStatusCard(
        stage: .validation,
        title: "Validation",
        detail: validationStatusText,
        systemImage: "exclamationmark.triangle.fill",
        tone: .blocked,
        isPersistent: true
      )
    }
    if validationWarningCount > 0 {
      return workflowStatusCard(
        stage: .validation,
        title: "Validation",
        detail: validationStatusText,
        systemImage: "exclamationmark.circle.fill",
        tone: .warning,
        isPersistent: true
      )
    }
    return workflowStatusCard(
      stage: .validation,
      title: "Validation",
      detail: validationStatusText,
      systemImage: "checkmark.shield.fill",
      tone: .ready,
      isPersistent: false
    )
  }

  private func promotionWorkflowStatusCard(
    remoteActionsEnabled: Bool,
    remoteActionDisabledReason: String
  ) -> PolicyCanvasWorkflowStatusCardModel? {
    if isPromoting {
      return workflowStatusCard(
        stage: .promotion,
        title: "Promotion",
        detail: promotionStatusText,
        systemImage: "arrow.up.right.circle.fill",
        tone: .active,
        isPersistent: true
      )
    }
    guard promotionWorkflowStatusIsRelevant else {
      return nil
    }
    if !remoteActionsEnabled {
      return workflowStatusCard(
        stage: .promotion,
        title: "Promotion",
        detail: remoteActionDisabledReason,
        systemImage: "lock.circle.fill",
        tone: .warning,
        isPersistent: true
      )
    }
    return workflowStatusCard(
      stage: .promotion,
      title: "Promotion",
      detail: promotionStatusText,
      systemImage: "checkmark.seal.fill",
      tone: .ready,
      isPersistent: false
    )
  }

  private var validationWorkflowStatusIsHealthy: Bool {
    guard let backingDocument, let latestSimulation else {
      return false
    }
    guard !isSimulating, !documentDirty, latestSimulation.revision == backingDocument.revision
    else {
      return false
    }
    return validationErrorCount == 0 && validationWarningCount == 0
  }

  private var promotionWorkflowStatusIsRelevant: Bool {
    guard let backingDocument, let latestSimulation else {
      return false
    }
    guard !documentDirty, latestSimulation.revision == backingDocument.revision else {
      return false
    }
    return latestSimulation.succeeded
  }

  private func promotionWorkflowStatusIsReady(remoteActionsEnabled: Bool) -> Bool {
    remoteActionsEnabled && !isPromoting && promotionWorkflowStatusIsRelevant
  }

  private func workflowStatusCard(
    stage: PolicyCanvasWorkflowStage,
    title: String,
    detail: String,
    systemImage: String,
    tone: PolicyCanvasWorkflowTone,
    isPersistent: Bool = false
  ) -> PolicyCanvasWorkflowStatusCardModel? {
    guard isPersistent || flashedWorkflowStatusStages.contains(stage) else {
      return nil
    }
    return PolicyCanvasWorkflowStatusCardModel(
      id: stage.rawValue,
      title: title,
      detail: detail,
      systemImage: systemImage,
      tone: tone
    )
  }
}
