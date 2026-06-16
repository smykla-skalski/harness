import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import HarnessMonitorPolicyModels

extension PolicyCanvasViewModel {
  func commitSelectedSwitchArmField(_ field: PolicyEvidenceField, at index: Int) {
    commitSelectedSwitchArmMutation(at: index) { arm in
      arm.field = field
    }
  }

  func commitSelectedSwitchArmPredicate(
    _ predicate: PolicyEvidencePredicate,
    at index: Int
  ) {
    commitSelectedSwitchArmMutation(at: index) { arm in
      arm.predicate = predicate
    }
  }

  func addSelectedSwitchArm() {
    guard let context = selectedSwitchNodeContext() else {
      return
    }
    var nextArms = context.policyKind.arms
    nextArms.append(
      PolicySwitchArm(
        port: switchCasePortTitle(nextArms.count + 1),
        field: .checksGreen,
        predicate: .isTrue
      )
    )
    commitSelectedSwitchCases(
      context: context,
      nextArms: nextArms,
      removalIndex: nil
    )
  }

  func removeSelectedSwitchArm(at index: Int) {
    guard let context = selectedSwitchNodeContext(),
      context.policyKind.arms.indices.contains(index),
      context.policyKind.arms.count > 1
    else {
      return
    }
    var nextArms = context.policyKind.arms
    nextArms.remove(at: index)
    commitSelectedSwitchCases(
      context: context,
      nextArms: nextArms,
      removalIndex: index
    )
  }

  func commitSelectedSwitchArmMutation(
    at index: Int,
    _ mutator: (inout PolicySwitchArm) -> Void
  ) {
    guard let context = selectedSwitchNodeContext(),
      context.policyKind.arms.indices.contains(index)
    else {
      return
    }
    var nextArms = context.policyKind.arms
    mutator(&nextArms[index])
    commitSelectedSwitchCases(
      context: context,
      nextArms: nextArms,
      removalIndex: nil
    )
  }

  func commitSelectedSwitchCases(
    context: SelectedSwitchNodeContext,
    nextArms: [PolicySwitchArm],
    removalIndex: Int?
  ) {
    let normalizedArms = normalizedSwitchArms(nextArms)
    let nextPolicyKind = PolicyGraphNodeKind.switch(PolicySwitchNode(arms: normalizedArms))

    let fromOutputPortTitles = context.node.outputPorts.map(\.title)
    let toOutputPortTitles = switchOutputPortTitles(for: normalizedArms)
    let fromEdges = edges.filter { $0.source.nodeID == context.id }
    let toEdges = migratedSwitchEdges(
      for: context.id,
      from: fromEdges,
      removalIndex: removalIndex
    )

    guard
      context.policyKind != nextPolicyKind
        || fromOutputPortTitles != toOutputPortTitles
        || fromEdges != toEdges
    else {
      return
    }

    mutate(
      .setNodeSwitchCases(
        id: context.id,
        from: context.policyKind,
        to: nextPolicyKind,
        fromOutputPortTitles: fromOutputPortTitles,
        toOutputPortTitles: toOutputPortTitles,
        fromEdges: fromEdges,
        toEdges: toEdges
      )
    )
  }

  func selectedSwitchNodeContext() -> SelectedSwitchNodeContext? {
    guard case .node(let id) = selection,
      let node = nodes.first(where: { $0.id == id })
    else {
      return nil
    }
    var policyKind = node.policyKind ?? taskBoardPolicyNodeKind(for: node.kind)
    guard policyKind.discriminator == PolicyCanvasNodeKind.switch.rawValue else {
      return nil
    }
    if policyKind.arms.isEmpty {
      policyKind = taskBoardPolicyNodeKind(for: .switch)
    }
    return SelectedSwitchNodeContext(id: id, node: node, policyKind: policyKind)
  }

  func normalizedSwitchArms(
    _ arms: [PolicySwitchArm]
  ) -> [PolicySwitchArm] {
    arms.enumerated().map { index, arm in
      PolicySwitchArm(
        port: switchCasePortTitle(index + 1),
        field: arm.field,
        predicate: arm.predicate
      )
    }
  }

  func switchOutputPortTitles(
    for arms: [PolicySwitchArm]
  ) -> [String] {
    arms.map(\.port) + ["default"]
  }

  func migratedSwitchEdges(
    for nodeID: String,
    from currentEdges: [PolicyCanvasEdge],
    removalIndex: Int?
  ) -> [PolicyCanvasEdge] {
    guard let removalIndex else {
      return currentEdges
    }
    let removedCaseNumber = removalIndex + 1
    return currentEdges.compactMap { edge in
      guard let caseNumber = switchCaseNumber(forPortID: edge.source.portID) else {
        return edge
      }
      if caseNumber == removedCaseNumber {
        return nil
      }
      guard caseNumber > removedCaseNumber else {
        return edge
      }
      var updated = edge
      updated.source = PolicyCanvasPortEndpoint(
        nodeID: nodeID,
        portID: switchCasePortID(caseNumber - 1),
        kind: .output,
        side: edge.source.side
      )
      updated.label = edgeLabel(source: updated.source, target: updated.target)
      return updated
    }
  }

  func switchCasePortTitle(_ caseNumber: Int) -> String {
    "case_\(caseNumber)"
  }

  func switchCasePortID(_ caseNumber: Int) -> String {
    "\(PolicyCanvasPortKind.output.rawValue)-\(switchCasePortTitle(caseNumber))"
  }

  func switchCaseNumber(forPortID portID: String) -> Int? {
    guard portID.hasPrefix("\(PolicyCanvasPortKind.output.rawValue)-case_") else {
      return nil
    }
    guard let component = portID.split(separator: "_").last else {
      return nil
    }
    return Int(component)
  }
}

struct SelectedSwitchNodeContext {
  let id: String
  let node: PolicyCanvasNode
  let policyKind: PolicyGraphNodeKind
}
