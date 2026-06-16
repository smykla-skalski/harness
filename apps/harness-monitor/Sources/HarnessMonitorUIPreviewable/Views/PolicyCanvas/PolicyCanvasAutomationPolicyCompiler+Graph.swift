import HarnessMonitorPolicyCanvasAlgorithms

extension PolicyCanvasAutomationPolicyCompiler {
  static func reachableNodes(
    from sourceID: String,
    nodes: [PolicyCanvasNode],
    edges: [PolicyCanvasEdge]
  ) -> [PolicyCanvasNode] {
    let outgoing = Dictionary(grouping: edges, by: \.source.nodeID)
    var visited = Set<String>()
    var pending = [sourceID]
    var cursor = 0
    while cursor < pending.count {
      let current = pending[cursor]
      cursor += 1
      guard visited.insert(current).inserted else {
        continue
      }
      for edge in outgoing[current] ?? [] where !visited.contains(edge.target.nodeID) {
        pending.append(edge.target.nodeID)
      }
    }
    return nodes.filter { visited.contains($0.id) }
  }

  static func orderedReachableNodes(
    from sourceID: String,
    nodes: [PolicyCanvasNode],
    edges: [PolicyCanvasEdge]
  ) -> [PolicyCanvasNode] {
    let nodeByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    let nodeOrder = Dictionary(
      uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) }
    )
    let outgoing = Dictionary(grouping: edges, by: \.source.nodeID).mapValues { edges in
      edges.sorted {
        let leftOrder = nodeOrder[$0.target.nodeID] ?? Int.max
        let rightOrder = nodeOrder[$1.target.nodeID] ?? Int.max
        if leftOrder == rightOrder {
          return $0.id < $1.id
        }
        return leftOrder < rightOrder
      }
    }
    var visited = Set<String>()
    var pending = [sourceID]
    var cursor = 0
    while cursor < pending.count {
      let current = pending[cursor]
      cursor += 1
      guard visited.insert(current).inserted, nodeByID[current] != nil else {
        continue
      }
      for edge in outgoing[current] ?? [] where !visited.contains(edge.target.nodeID) {
        pending.append(edge.target.nodeID)
      }
    }
    var indegree = Dictionary(uniqueKeysWithValues: visited.map { ($0, 0) })
    for edge in edges
    where visited.contains(edge.source.nodeID)
      && visited.contains(edge.target.nodeID)
    {
      indegree[edge.target.nodeID, default: 0] += 1
    }
    var ready =
      visited
      .filter { indegree[$0, default: 0] == 0 }
      .sorted { (nodeOrder[$0] ?? Int.max) < (nodeOrder[$1] ?? Int.max) }
    var orderedIDs: [String] = []
    while let current = ready.first {
      ready.removeFirst()
      orderedIDs.append(current)
      for edge in outgoing[current] ?? [] where visited.contains(edge.target.nodeID) {
        indegree[edge.target.nodeID, default: 0] -= 1
        if indegree[edge.target.nodeID, default: 0] == 0 {
          ready.append(edge.target.nodeID)
          ready.sort { (nodeOrder[$0] ?? Int.max) < (nodeOrder[$1] ?? Int.max) }
        }
      }
    }
    if orderedIDs.count != visited.count {
      orderedIDs = nodes.map(\.id).filter { visited.contains($0) }
    }
    return orderedIDs.compactMap { nodeByID[$0] }
  }

  static func payloadProvided(
    by edge: PolicyCanvasEdge,
    nodesByID: [String: PolicyCanvasNode],
    edges: [PolicyCanvasEdge],
    resolvingHubIDs: Set<String> = []
  ) -> AutomationPolicyPayloadKind {
    guard let sourceNode = nodesByID[edge.source.nodeID] else {
      return .unknown
    }
    if isHub(sourceNode) {
      return hubInputPayload(
        for: sourceNode.id,
        edges: edges,
        nodesByID: nodesByID,
        resolvingHubIDs: resolvingHubIDs
      )
    }
    let explicitPayload = payloadKind(forPortID: edge.source.portID)
    if explicitPayload != .unknown {
      return explicitPayload
    }
    return outputPayload(
      for: sourceNode,
      edges: edges,
      nodesByID: nodesByID,
      resolvingHubIDs: resolvingHubIDs
    )
  }

  static func payloadRequired(
    by node: PolicyCanvasNode,
    portID: String
  ) -> AutomationPolicyPayloadKind {
    let explicitPayload = payloadKind(forPortID: portID)
    if explicitPayload != .unknown, portID != "in" {
      return explicitPayload
    }
    return declaredInputPayload(for: node)
  }

  static func inputPayload(
    for node: PolicyCanvasNode,
    edges: [PolicyCanvasEdge],
    nodesByID: [String: PolicyCanvasNode]
  ) -> AutomationPolicyPayloadKind {
    if isHub(node) {
      return hubInputPayload(for: node.id, edges: edges, nodesByID: nodesByID)
    }
    if let incomingPayload = incomingPayload(for: node.id, edges: edges, nodesByID: nodesByID),
      incomingPayload != .unknown
    {
      return incomingPayload
    }
    return declaredInputPayload(for: node)
  }

  static func declaredInputPayload(
    for node: PolicyCanvasNode
  ) -> AutomationPolicyPayloadKind {
    if node.kind == .ocrImage || node.policyKind?.isOCRImage == true
      || actions(from: node).contains(.ocrImage)
    {
      return .image
    }
    if node.kind == .resolveReviewPullRequests
      || node.policyKind?.isResolveReviewPullRequests == true
      || actions(from: node).contains(.extractGitHubPullRequests)
      || actions(from: node).contains(.resolveReviewPullRequests)
      || actions(from: node).contains(.copyExtractedGitHubPullRequestURLs)
    {
      return .text
    }
    if node.kind == .copyReviewPullRequestList
      || node.policyKind?.isCopyReviewPullRequestList == true
      || actions(from: node).contains(.copyReviewPullRequestList)
      || actions(from: node).contains(.previewReviewApprovals)
      || actions(from: node).contains(.promptReviewApprovals)
      || actions(from: node).contains(.approveReviewPullRequests)
      || actions(from: node).contains(.runReviewPolicy)
    {
      return .pullRequests
    }
    if actions(from: node).contains(.openDashboardDebugging)
      || actions(from: node).contains(.rememberRecentScan)
      || actions(from: node).contains(.showFeedback)
      || postprocessors(from: node).contains(.persistResult)
    {
      return .text
    }
    return .unknown
  }

  static func outputPayload(
    for node: PolicyCanvasNode,
    edges: [PolicyCanvasEdge],
    nodesByID: [String: PolicyCanvasNode],
    resolvingHubIDs: Set<String> = []
  ) -> AutomationPolicyPayloadKind {
    if isHub(node) {
      return hubInputPayload(
        for: node.id,
        edges: edges,
        nodesByID: nodesByID,
        resolvingHubIDs: resolvingHubIDs
      )
    }
    return declaredOutputPayload(for: node)
  }

  static func declaredOutputPayload(
    for node: PolicyCanvasNode
  ) -> AutomationPolicyPayloadKind {
    if node.kind == .reviewScreenshotPaste || node.policyKind?.isReviewScreenshotPaste == true {
      return .image
    }
    if node.kind == .ocrImage || node.policyKind?.isOCRImage == true {
      return .text
    }
    if node.kind == .resolveReviewPullRequests
      || node.policyKind?.isResolveReviewPullRequests == true
      || actions(from: node).contains(.extractGitHubPullRequests)
      || actions(from: node).contains(.resolveReviewPullRequests)
    {
      return .pullRequests
    }
    if let binding = node.automationBinding {
      if binding.selectedContentKinds.contains(.image) {
        return .image
      }
      if !binding.selectedContentKinds.isDisjoint(with: [.text, .url]) {
        return .text
      }
      if binding.resolvedEventSource == .manualOCRPaste {
        return .image
      }
      if binding.resolvedEventSource == .manualReviewTextPaste {
        return .text
      }
    }
    return .unknown
  }

  static func incomingPayload(
    for nodeID: String,
    edges: [PolicyCanvasEdge],
    nodesByID: [String: PolicyCanvasNode],
    resolvingHubIDs: Set<String> = []
  ) -> AutomationPolicyPayloadKind? {
    edges.lazy
      .filter { $0.target.nodeID == nodeID }
      .map {
        payloadProvided(
          by: $0,
          nodesByID: nodesByID,
          edges: edges,
          resolvingHubIDs: resolvingHubIDs
        )
      }
      .first { $0 != .unknown }
  }

  static func hubInputPayload(
    for hubNodeID: String,
    edges: [PolicyCanvasEdge],
    nodesByID: [String: PolicyCanvasNode],
    resolvingHubIDs: Set<String> = []
  ) -> AutomationPolicyPayloadKind {
    guard !resolvingHubIDs.contains(hubNodeID) else {
      return .unknown
    }
    return incomingPayload(
      for: hubNodeID,
      edges: edges,
      nodesByID: nodesByID,
      resolvingHubIDs: resolvingHubIDs.union([hubNodeID])
    ) ?? .unknown
  }

  static func edgeSourceIsHub(
    _ edge: PolicyCanvasEdge,
    nodesByID: [String: PolicyCanvasNode]
  ) -> Bool {
    guard let sourceNode = nodesByID[edge.source.nodeID] else {
      return false
    }
    return isHub(sourceNode)
  }

  static func isHub(_ node: PolicyCanvasNode) -> Bool {
    node.kind == .hub || node.policyKind?.isHub == true
  }

  static func fanOuts(
    from nodes: [PolicyCanvasNode],
    edges: [PolicyCanvasEdge],
    nodesByID: [String: PolicyCanvasNode]
  ) -> [AutomationPolicyFanOut] {
    nodes
      .filter(isHub)
      .compactMap { hub in
        let branches =
          edges
          .filter { $0.source.nodeID == hub.id }
          .sorted {
            if $0.source.portID == $1.source.portID {
              return $0.id < $1.id
            }
            return $0.source.portID < $1.source.portID
          }
          .compactMap { edge -> AutomationPolicyFanOutBranch? in
            guard let targetNode = nodesByID[edge.target.nodeID] else {
              return nil
            }
            return AutomationPolicyFanOutBranch(
              outputPortID: edge.source.portID,
              targetNodeID: edge.target.nodeID,
              actions: actions(from: targetNode)
            )
          }
        guard !branches.isEmpty else {
          return nil
        }
        return AutomationPolicyFanOut(
          hubNodeID: hub.id,
          payload: hubInputPayload(for: hub.id, edges: edges, nodesByID: nodesByID),
          branches: branches
        )
      }
  }

  static func payloadKind(forPortID portID: String) -> AutomationPolicyPayloadKind {
    let normalized =
      portID
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .lowercased()
    if normalized.contains("pull request") || normalized.contains("prs") {
      return .pullRequests
    }
    if normalized.contains("image") || normalized.contains("screenshot") {
      return .image
    }
    if normalized.contains("text") {
      return .text
    }
    if normalized.contains("event") {
      return .event
    }
    return .unknown
  }

  static func isCompatible(
    _ outputPayload: AutomationPolicyPayloadKind,
    with requiredPayload: AutomationPolicyPayloadKind
  ) -> Bool {
    outputPayload == requiredPayload || outputPayload == .unknown || requiredPayload == .unknown
  }

  static func actions(from node: PolicyCanvasNode) -> [AutomationPolicyAction] {
    if let binding = node.automationBinding, binding.isEnabled {
      let selectedActions = binding.selectedActions
      if !selectedActions.isEmpty {
        return selectedActions
      }
    }
    if node.kind == .ocrImage || node.policyKind?.isOCRImage == true {
      return [.ocrImage]
    }
    if node.kind == .resolveReviewPullRequests
      || node.policyKind?.isResolveReviewPullRequests == true
    {
      return [.extractGitHubPullRequests, .resolveReviewPullRequests]
    }
    if node.kind == .copyReviewPullRequestList
      || node.policyKind?.isCopyReviewPullRequestList == true
    {
      return [.copyReviewPullRequestList]
    }
    return []
  }

  static func postprocessors(
    from node: PolicyCanvasNode
  ) -> [AutomationPolicyPostprocessor] {
    guard let binding = node.automationBinding, binding.isEnabled else {
      return []
    }
    return binding.selectedPostprocessors
  }
}
