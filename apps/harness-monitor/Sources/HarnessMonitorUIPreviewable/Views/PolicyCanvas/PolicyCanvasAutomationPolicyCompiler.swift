import Foundation
import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

public struct PolicyCanvasAutomationPolicyCompilation: Equatable, Sendable {
  static let empty = Self(
    policies: [],
    diagnostics: [],
    policyBySourceNodeID: [:],
    executionPlans: []
  )

  public var policies: [AutomationPolicy]
  var diagnostics: [PolicyCanvasAutomationPolicyDiagnostic]
  var policyBySourceNodeID: [String: AutomationPolicy]
  var executionPlans: [AutomationPolicyExecutionPlan]

  public var summaryText: String {
    guard !policies.isEmpty else {
      return "No enforceable automation policies"
    }
    let noun = policies.count == 1 ? "policy" : "policies"
    return "\(policies.count) enforceable automation \(noun)"
  }

  func policy(compiledFrom nodeID: String) -> AutomationPolicy? {
    policyBySourceNodeID[nodeID]
  }
}

struct PolicyCanvasAutomationPolicyDiagnostic: Equatable, Identifiable, Sendable {
  let id: String
  let message: String
}

private struct PolicyCanvasAutomationExecutionPlanCompilation {
  let plan: AutomationPolicyExecutionPlan
  let diagnostics: [PolicyCanvasAutomationPolicyDiagnostic]
}

private struct PolicyCanvasAutomationGraph {
  let nodes: [PolicyCanvasNode]
  let edges: [PolicyCanvasEdge]
}

public enum PolicyCanvasAutomationPolicyCompiler {
  static func compile(
    nodes: [PolicyCanvasNode],
    edges: [PolicyCanvasEdge]
  ) -> PolicyCanvasAutomationPolicyCompilation {
    let graph = PolicyCanvasAutomationGraph(nodes: nodes, edges: edges)
    let sourceNodes = nodes.compactMap { node -> PolicyCanvasAutomationSource? in
      if isAutomationSourceNode(node), let binding = node.automationBinding {
        return PolicyCanvasAutomationSource(
          node: node,
          eventSource: binding.resolvedEventSource,
          binding: binding
        )
      }
      guard let source = eventSource(for: node) else {
        return nil
      }
      return PolicyCanvasAutomationSource(node: node, eventSource: source, binding: nil)
    }

    var diagnostics: [PolicyCanvasAutomationPolicyDiagnostic] = []
    if sourceNodes.isEmpty {
      diagnostics.append(
        PolicyCanvasAutomationPolicyDiagnostic(
          id: "missing-source",
          message: [
            "Add a source node named Clipboard, Manual Paste, Review Text Paste,",
            "Review Screenshot Paste,",
            "Drag and Drop, File Picker, or Screenshot Folder.",
          ].joined(separator: " ")
        )
      )
    }

    let sortedSources = sourceNodes.sorted {
      if $0.node.position.y == $1.node.position.y {
        return $0.node.position.x < $1.node.position.x
      }
      return $0.node.position.y < $1.node.position.y
    }
    var usedPolicyIDs = Set<String>()
    var policyBySourceNodeID: [String: AutomationPolicy] = [:]
    policyBySourceNodeID.reserveCapacity(sortedSources.count)
    var executionPlans: [AutomationPolicyExecutionPlan] = []
    executionPlans.reserveCapacity(sortedSources.count)
    var policies: [AutomationPolicy] = []
    policies.reserveCapacity(sortedSources.count)
    for (offset, source) in sortedSources.enumerated() {
      let planCompilation = executionPlan(for: source, graph: graph)
      diagnostics.append(contentsOf: planCompilation.diagnostics)
      guard planCompilation.diagnostics.isEmpty else {
        continue
      }
      let executionPlan = planCompilation.plan
      let policyID = uniquePolicyID(for: source, usedIDs: &usedPolicyIDs)
      let compiledPolicy = policy(
        for: source,
        policyID: policyID,
        priority: offset + 1,
        graph: graph,
        executionPlan: executionPlan
      )
      policyBySourceNodeID[source.node.id] = compiledPolicy
      executionPlans.append(executionPlan)
      policies.append(compiledPolicy)
    }
    return PolicyCanvasAutomationPolicyCompilation(
      policies: policies,
      diagnostics: diagnostics,
      policyBySourceNodeID: policyBySourceNodeID,
      executionPlans: executionPlans
    )
  }

  private static func isAutomationSourceNode(_ node: PolicyCanvasNode) -> Bool {
    node.kind == .source || node.inputPorts.isEmpty
  }

  static func compile(
    document: TaskBoardPolicyPipelineDocument
  ) -> PolicyCanvasAutomationPolicyCompilation {
    let nodes = document.nodes.map {
      policyCanvasNode($0, layout: document.layout)
    }
    let edges = document.edges.compactMap { edge in
      policyCanvasEdge(edge, nodes: nodes, assignPreferredPortSides: false)
    }
    return compile(nodes: nodes, edges: edges)
  }

  static func slug(_ rawValue: String) -> String {
    let lowered = rawValue.lowercased()
    var characters: [Character] = []
    var lastWasSeparator = false
    for character in lowered {
      if character.isLetter || character.isNumber {
        characters.append(character)
        lastWasSeparator = false
      } else if !lastWasSeparator {
        characters.append("-")
        lastWasSeparator = true
      }
    }
    return String(characters).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  }

  private static func policy(
    for source: PolicyCanvasAutomationSource,
    policyID: String,
    priority: Int,
    graph: PolicyCanvasAutomationGraph,
    executionPlan: AutomationPolicyExecutionPlan
  ) -> AutomationPolicy {
    let reachableNodes = reachableNodes(
      from: source.node.id,
      nodes: graph.nodes,
      edges: graph.edges
    )
    let text = graphText(reachableNodes: reachableNodes, edges: graph.edges)
    let contribution = automationContribution(
      from: reachableNodes,
      sourceNodeID: source.node.id
    )
    let contentKinds = contentKinds(from: text)
    let actions = actions(for: source.eventSource, contentKinds: contentKinds, text: text)
    let policyName =
      source.node.title.isEmpty
      ? "\(source.eventSource.title) Canvas Policy"
      : source.node.title
    if let binding = source.binding {
      let compiledPolicy = binding.automationPolicy(
        id: policyID,
        name: policyName,
        defaultPriority: priority
      )
      .applying(contribution)
      return compiledPolicy.applyingExecutionPlan(executionPlan)
    }
    let compiledPolicy = AutomationPolicy(
      id: policyID,
      name: policyName,
      eventSource: source.eventSource,
      isEnabled: true,
      priority: priority,
      match: AutomationPolicyMatch(
        contentKinds: contentKinds,
        sourceAppFilter: sourceAppFilter(from: text)
      ),
      preprocessors: preprocessors(
        for: source.eventSource,
        contentKinds: contentKinds,
        text: text
      ),
      actions: actions,
      postprocessors: postprocessors(actions: actions, text: text),
      ocrConfiguration: source.eventSource == .reviewScreenshotPaste
        ? AutomationPolicyOCRConfiguration()
        : nil,
      reviewPullRequestExtraction: source.eventSource == .reviewScreenshotPaste
        ? ReviewPullRequestExtractionConfiguration()
        : nil
    )
    .applying(contribution)
    return compiledPolicy.applyingExecutionPlan(executionPlan)
  }

  private static func executionPlan(
    for source: PolicyCanvasAutomationSource,
    graph: PolicyCanvasAutomationGraph
  ) -> PolicyCanvasAutomationExecutionPlanCompilation {
    let orderedNodes = orderedReachableNodes(
      from: source.node.id,
      nodes: graph.nodes,
      edges: graph.edges
    )
    let nodeByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
    let reachableIDs = Set(orderedNodes.map(\.id))
    let reachableEdges = graph.edges.filter {
      reachableIDs.contains($0.source.nodeID) && reachableIDs.contains($0.target.nodeID)
    }
    var diagnostics: [PolicyCanvasAutomationPolicyDiagnostic] = []
    for edge in reachableEdges {
      guard let targetNode = nodeByID[edge.target.nodeID] else {
        continue
      }
      let outputPayload = payloadProvided(
        by: edge,
        nodesByID: nodeByID,
        edges: reachableEdges
      )
      let requiredPayload = payloadRequired(by: targetNode, portID: edge.target.portID)
      guard isCompatible(outputPayload, with: requiredPayload) else {
        let diagnosticPrefix: String
        if edgeSourceIsHub(edge, nodesByID: nodeByID) {
          diagnosticPrefix = "incompatible-hub-payload-edge"
        } else {
          diagnosticPrefix = "incompatible-payload-edge"
        }
        diagnostics.append(
          PolicyCanvasAutomationPolicyDiagnostic(
            id: "\(diagnosticPrefix):\(edge.id)",
            message:
              "Edge \(edge.id) sends \(outputPayload.title) to \(targetNode.title),"
              + " which requires \(requiredPayload.title)."
          )
        )
        continue
      }
    }

    var steps = orderedNodes.map { node in
      AutomationPolicyExecutionStep(
        nodeID: node.id,
        inputPayload: node.id == source.node.id
          ? .event
          : inputPayload(for: node, edges: reachableEdges, nodesByID: nodeByID),
        outputPayload: outputPayload(
          for: node,
          edges: reachableEdges,
          nodesByID: nodeByID
        ),
        actions: node.id == source.node.id ? [] : actions(from: node)
      )
    }
    if steps.allSatisfy(\.actions.isEmpty),
      let sourceIndex = steps.firstIndex(where: { $0.nodeID == source.node.id })
    {
      let text = graphText(reachableNodes: orderedNodes, edges: graph.edges)
      let sourceActions = actions(from: source.node)
      if sourceActions.isEmpty {
        steps[sourceIndex].actions = actions(
          for: source.eventSource,
          contentKinds: contentKinds(from: text),
          text: text
        )
      } else {
        steps[sourceIndex].actions = sourceActions
      }
    }
    return PolicyCanvasAutomationExecutionPlanCompilation(
      plan: AutomationPolicyExecutionPlan(
        sourceNodeID: source.node.id,
        eventSource: source.eventSource,
        steps: steps,
        fanOuts: fanOuts(
          from: orderedNodes,
          edges: reachableEdges,
          nodesByID: nodeByID
        )
      ),
      diagnostics: diagnostics
    )
  }

  private static func uniquePolicyID(
    for source: PolicyCanvasAutomationSource,
    usedIDs: inout Set<String>
  ) -> String {
    let baseID =
      AutomationPolicyDocument.canvasPolicyIDPrefix
      + source.eventSource.rawValue
      + "."
      + slug(source.node.id)
    guard !usedIDs.contains(baseID) else {
      var candidate = baseID + "-" + stableHexSuffix(source.node.id)
      var counter = 2
      while usedIDs.contains(candidate) {
        candidate = baseID + "-" + stableHexSuffix(source.node.id + ":\(counter)")
        counter += 1
      }
      usedIDs.insert(candidate)
      return candidate
    }
    usedIDs.insert(baseID)
    return baseID
  }

  private static func stableHexSuffix(_ rawValue: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in rawValue.utf8 {
      hash ^= UInt64(byte)
      hash &*= 0x0100_0000_01b3
    }
    return String(hash, radix: 16)
  }
}

extension PolicyCanvasViewModel {
  var automationPolicyCompilation: PolicyCanvasAutomationPolicyCompilation {
    cachedAutomationPolicyCompilation
  }
}
