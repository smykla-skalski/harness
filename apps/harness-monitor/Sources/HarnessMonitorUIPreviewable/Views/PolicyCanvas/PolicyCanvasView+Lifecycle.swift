import HarnessMonitorKit
import SwiftUI

extension PolicyCanvasView {
  @MainActor
  func requestCanvasKeyboardFocus() {
    guard sceneFocusEnabled else {
      return
    }
    canvasKeyboardFocusedState = true
  }

  func scheduleCanvasKeyboardFocusRestoreIfNeeded() {
    guard sceneFocusEnabled, !searchPaletteVisible, presentedEditSheet == nil, focusedField == nil
    else {
      return
    }
    Task { @MainActor in
      await Task.yield()
      guard sceneFocusEnabled, !searchPaletteVisible, presentedEditSheet == nil, focusedField == nil
      else {
        return
      }
      requestCanvasKeyboardFocus()
    }
  }

  var deletionConfirmationPresented: Binding<Bool> {
    Binding(
      get: { pendingDeletionRequest != nil },
      set: { isPresented in
        if !isPresented {
          pendingDeletionRequest = nil
        }
      }
    )
  }

  func loadPolicyPipeline() async {
    guard let store else {
      return
    }
    if dashboardUI?.taskBoardPolicyPipeline != nil {
      applyDashboardSnapshot()
      return
    }
    // Live app startup does not defer the dashboard window until bootstrap, so
    // the first Policies visit can arrive before the daemon client exists.
    await store.bootstrapIfNeeded()
    if dashboardUI?.taskBoardPolicyPipeline != nil {
      applyDashboardSnapshot()
      return
    }
    guard viewModel.markInitialRemoteLoadRequested() else {
      return
    }
    await store.refreshTaskBoardPolicyPipeline()
    applyDashboardSnapshot()
  }
}
