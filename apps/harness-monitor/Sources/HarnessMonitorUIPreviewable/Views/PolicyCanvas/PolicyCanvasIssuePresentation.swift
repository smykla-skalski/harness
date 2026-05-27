struct PolicyCanvasIssuePresentation: Equatable {
  let title: String
  let detail: String
  let targetSummary: String?
  let codeLabel: String
}

extension PolicyCanvasViewModel {
  func issuePresentation(for resolved: PolicyCanvasResolvedIssue) -> PolicyCanvasIssuePresentation {
    PolicyCanvasIssuePresentation(
      title: actionableIssueTitle(for: resolved.issue.code),
      detail: resolved.issue.message,
      targetSummary: issueTargetSummary(for: resolved),
      codeLabel: readableIssueCode(resolved.issue.code)
    )
  }

  private func actionableIssueTitle(for code: String) -> String {
    switch code {
    case "cycle":
      return "Break the cycle"
    case "dangling_edge":
      return "Reconnect or remove this path"
    case "duplicate_id":
      return "Rename the duplicate item"
    case "duplicate_label":
      return "Rename duplicate steps"
    case "invalid_port":
      return "Reconnect the broken path"
    case "orphan_node":
      return "Connect or group this step"
    case "unsupported_schema_version":
      return "Update the policy schema"
    case "unsafe_high_risk_action":
      return "Add a safer approval step"
    case "error_into_allow":
      return "Review the allow path"
    default:
      return "Review \(readableIssueCode(code).lowercased())"
    }
  }

  private func issueTargetSummary(for resolved: PolicyCanvasResolvedIssue) -> String? {
    if let edgeID = resolved.issue.edgeId {
      return readableEdgeSummary(for: edgeID)
    }
    if let nodeID = resolved.issue.nodeId {
      return "Step: \(readableNodeTitle(for: nodeID))"
    }
    let titles = resolved.issue.nodeIds.map { readableNodeTitle(for: $0) }
    guard !titles.isEmpty else {
      return nil
    }
    return "Steps: \(readableList(titles))"
  }

  private func readableEdgeSummary(for edgeID: String) -> String? {
    guard let edge = edges.first(where: { $0.id == edgeID }) else {
      return nil
    }
    let source = readableNodeTitle(for: edge.source.nodeID)
    let target = readableNodeTitle(for: edge.target.nodeID)
    if edge.label.isEmpty {
      return "Path: \(source) to \(target)"
    }
    return "Path: \(edge.label) (\(source) to \(target))"
  }

  private func readableNodeTitle(for nodeID: String) -> String {
    if let node = node(nodeID) {
      return node.title
    }
    return nodeID
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: ":", with: " ")
  }

  private func readableIssueCode(_ code: String) -> String {
    code.replacingOccurrences(of: "_", with: " ").capitalized
  }

  private func readableList(_ values: [String]) -> String {
    switch values.count {
    case 0:
      return ""
    case 1:
      return values[0]
    case 2:
      return "\(values[0]) and \(values[1])"
    default:
      let leading = values.prefix(2).joined(separator: ", ")
      return "\(leading), and \(values.count - 2) more"
    }
  }
}
