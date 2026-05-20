import HarnessMonitorKit
import SwiftUI

extension SettingsTaskBoardSection {
  func workflowBinding(_ workflow: TaskBoardOrchestratorWorkflow) -> Binding<Bool> {
    Binding(
      get: { draftBinding.wrappedValue.enabledWorkflows.contains(workflow) },
      set: { isEnabled in
        var draft = draftBinding.wrappedValue
        if isEnabled {
          draft.enabledWorkflows.insert(workflow)
        } else {
          draft.enabledWorkflows.remove(workflow)
        }
        draftBinding.wrappedValue = draft
      }
    )
  }

  func automationBinding(_ automation: TaskBoardGitHubAutomation) -> Binding<Bool> {
    Binding(
      get: { draftBinding.wrappedValue.enabledAutomations.contains(automation) },
      set: { isEnabled in
        var draft = draftBinding.wrappedValue
        if isEnabled {
          draft.enabledAutomations.insert(automation)
        } else {
          draft.enabledAutomations.remove(automation)
        }
        draftBinding.wrappedValue = draft
      }
    )
  }

  @MainActor
  func scrollToNavigationRequest(
    _ request: SettingsNavigationRequest?,
    proxy: ScrollViewProxy
  ) {
    guard let request, let anchor = request.taskBoardAnchor else {
      return
    }
    guard loadErrorBinding.wrappedValue == nil,
      hasLoadedSettingsBinding.wrappedValue,
      !isLoadingBinding.wrappedValue
    else {
      pendingNavigationRequestIDBinding.wrappedValue = request.id
      return
    }
    guard pendingNavigationRequestIDBinding.wrappedValue != request.id else {
      pendingNavigationRequestIDBinding.wrappedValue = nil
      navigationRequestBinding.wrappedValue = nil
      scrollTo(anchor, proxy: proxy)
      return
    }
    pendingNavigationRequestIDBinding.wrappedValue = nil
    navigationRequestBinding.wrappedValue = nil
    scrollTo(anchor, proxy: proxy)
  }

  @MainActor
  private func scrollTo(_ anchor: SettingsTaskBoardAnchor, proxy: ScrollViewProxy) {
    Task { @MainActor in
      await Task.yield()
      withAnimation(.snappy(duration: 0.18)) {
        proxy.scrollTo(anchor, anchor: .top)
      }
    }
  }
}
