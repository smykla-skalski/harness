// Parallel route execution infrastructure extracted from
// PolicyCanvasFirstFeasibleRouteSelection to satisfy the file-length limit.
import CoreGraphics
import Foundation

extension PolicyCanvasFirstFeasibleRouteSelection {
  struct IndexedRoute {
    let index: Int
    let id: String
    let route: PolicyCanvasEdgeRoute
  }

  final class IndexedRouteCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [IndexedRoute] = []

    init(capacity: Int) {
      entries.reserveCapacity(capacity)
    }

    func append(_ entry: IndexedRoute) {
      lock.lock()
      entries.append(entry)
      lock.unlock()
    }

    func sortedEntries() -> [IndexedRoute] {
      lock.lock()
      let snapshot = entries
      lock.unlock()
      return snapshot.sorted(by: { $0.index < $1.index })
    }
  }

  func parallelRoutes(
    edges: [PolicyCanvasEdge],
    context: RouteSelectionContext
  ) -> [String: PolicyCanvasEdgeRoute] {
    let collector = IndexedRouteCollector(capacity: edges.count)
    DispatchQueue.concurrentPerform(iterations: edges.count) { index in
      let edge = edges[index]
      guard let route = selectedRoute(for: edge, context: context) else {
        return
      }
      collector.append(IndexedRoute(index: index, id: edge.id, route: route))
    }
    var routes: [String: PolicyCanvasEdgeRoute] = [:]
    let indexedRoutes = collector.sortedEntries()
    routes.reserveCapacity(indexedRoutes.count)
    for entry in indexedRoutes {
      routes[entry.id] = entry.route
    }
    return routes
  }
}
