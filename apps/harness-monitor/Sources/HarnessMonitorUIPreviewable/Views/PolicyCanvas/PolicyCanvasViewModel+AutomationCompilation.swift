import HarnessMonitorKit
import SwiftUI

extension PolicyCanvasViewModel {
  func refreshAutomationPolicyCompilation() {
    let nextCompilation = PolicyCanvasAutomationPolicyCompiler.compile(nodes: nodes, edges: edges)
    guard cachedAutomationPolicyCompilation != nextCompilation else { return }
    cachedAutomationPolicyCompilation = nextCompilation
  }

  func queueAutomationPolicyCompilation() {
    automationCompilationGeneration &+= 1
    let compilationGeneration = automationCompilationGeneration
    let nodesSnapshot = nodes
    let edgesSnapshot = edges
    HarnessMonitorAsyncWorkQueue.shared.submit(
      HarnessMonitorAsyncWorkQueue.WorkItem(title: "Compiling policy canvas automation") {
        let compilation = PolicyCanvasAutomationPolicyCompiler.compile(
          nodes: nodesSnapshot,
          edges: edgesSnapshot
        )
        await MainActor.run {
          guard self.automationCompilationGeneration == compilationGeneration else {
            return
          }
          guard self.cachedAutomationPolicyCompilation != compilation else {
            return
          }
          self.cachedAutomationPolicyCompilation = compilation
        }
      }
    )
  }
}
