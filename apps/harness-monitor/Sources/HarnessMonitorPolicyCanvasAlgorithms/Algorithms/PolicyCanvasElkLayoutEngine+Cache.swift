// ELK layout cache, runner, and layout-option helpers extracted from
// PolicyCanvasElkLayoutEngine to satisfy the file-length limit.
import CoreGraphics
import ElkSwift
import Foundation

final class PolicyCanvasElkLayoutCache {
  private let lock = NSLock()
  private var order: [String] = []
  private var values: [String: PolicyCanvasLayoutResult] = [:]
  private let capacity = 8

  func value(for identity: String) -> PolicyCanvasLayoutResult? {
    lock.lock()
    defer { lock.unlock() }
    return values[identity]
  }

  func store(_ result: PolicyCanvasLayoutResult, for identity: String) {
    lock.lock()
    defer { lock.unlock() }
    if values[identity] == nil {
      order.append(identity)
    }
    values[identity] = result
    while order.count > capacity {
      values.removeValue(forKey: order.removeFirst())
    }
  }
}

extension PolicyCanvasLayoutResult {
  func cachingElkLayoutResult(identity: String) -> Self {
    policyCanvasElkLayoutCache.store(self, for: identity)
    return self
  }
}

final class PolicyCanvasElkRunner {
  private let elk = ELK()
  private let lock = NSLock()

  func layout(graph: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    return try elk.layout(graph: graph, timeout: timeout)
  }
}

func policyCanvasElkLayoutOptions() -> [String: Any] {
  let edgeSpacing = String(Int(PolicyCanvasLayout.defaultEdgeLineSpacing.rounded()))
  return [
    "elk.algorithm": "layered",
    "elk.direction": "RIGHT",
    "elk.edgeRouting": "ORTHOGONAL",
    "elk.randomSeed": "1",
    "elk.layered.thoroughness": "2",
    "elk.layered.highDegreeNodes.treatment": "true",
    "elk.layered.highDegreeNodes.threshold": "8",
    "elk.spacing.nodeNode": "80",
    "elk.layered.spacing.nodeNodeBetweenLayers": "120",
    "elk.spacing.edgeNode": "40",
    "elk.spacing.edgeEdge": edgeSpacing,
  ]
}
