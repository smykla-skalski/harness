import HarnessMonitorKit

extension PolicyCanvasAutomationPolicyCompiler {
  public static func compileEnforcedCanvases(
    workspace: TaskBoardPolicyCanvasWorkspace?,
    activeDocument: @autoclosure () -> TaskBoardPolicyPipelineDocument?
  ) -> PolicyCanvasAutomationPolicyCompilation {
    guard let workspace else {
      guard let activeDocument = activeDocument(), activeDocument.mode == .enforced else {
        return .empty
      }
      return compile(document: activeDocument)
    }

    var merged = PolicyCanvasAutomationPolicyCompilation.empty
    var usedPolicyIDs = Set<String>()
    for canvas in workspace.canvases where canvas.mode == .enforced {
      mergeEnforcedCanvas(
        canvas,
        into: &merged,
        usedPolicyIDs: &usedPolicyIDs
      )
    }
    merged.policies.sort {
      if $0.priority == $1.priority {
        return $0.id < $1.id
      }
      return $0.priority < $1.priority
    }
    return merged
  }

  private static func mergeEnforcedCanvas(
    _ canvas: TaskBoardPolicyCanvasSummary,
    into merged: inout PolicyCanvasAutomationPolicyCompilation,
    usedPolicyIDs: inout Set<String>
  ) {
    guard let document = canvas.document else {
      merged.diagnostics.append(
        PolicyCanvasAutomationPolicyDiagnostic(
          id: "missing-document-\(canvas.canvasId)",
          message: "Enforced canvas \(canvas.title) did not include a policy document"
        )
      )
      return
    }

    let compilation = compile(document: document)
    merged.diagnostics.append(
      contentsOf: compilation.diagnostics.filter { $0.id != "missing-source" }
    )
    var adjustedPolicyByOriginalID: [String: AutomationPolicy] = [:]
    for var policy in compilation.policies {
      let originalID = policy.id
      policy.id = uniqueMergedPolicyID(
        originalID,
        canvasID: canvas.canvasId,
        usedIDs: &usedPolicyIDs
      )
      adjustedPolicyByOriginalID[originalID] = policy
      merged.policies.append(policy)
    }

    for (sourceNodeID, policy) in compilation.policyBySourceNodeID {
      let adjustedPolicy = adjustedPolicyByOriginalID[policy.id] ?? policy
      if merged.policyBySourceNodeID[sourceNodeID] == nil {
        merged.policyBySourceNodeID[sourceNodeID] = adjustedPolicy
      } else {
        merged.policyBySourceNodeID["\(canvas.canvasId):\(sourceNodeID)"] = adjustedPolicy
      }
    }
  }

  private static func uniqueMergedPolicyID(
    _ policyID: String,
    canvasID: String,
    usedIDs: inout Set<String>
  ) -> String {
    guard usedIDs.contains(policyID) else {
      usedIDs.insert(policyID)
      return policyID
    }
    let sluggedCanvasID = slug(canvasID)
    let suffix = sluggedCanvasID.isEmpty ? "canvas" : sluggedCanvasID
    var candidate = "\(policyID).\(suffix)"
    var counter = 2
    while usedIDs.contains(candidate) {
      candidate = "\(policyID).\(suffix)-\(counter)"
      counter += 1
    }
    usedIDs.insert(candidate)
    return candidate
  }
}
