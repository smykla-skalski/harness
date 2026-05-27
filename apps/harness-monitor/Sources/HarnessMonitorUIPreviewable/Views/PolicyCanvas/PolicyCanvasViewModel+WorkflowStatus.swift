extension PolicyCanvasViewModel {
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
}
