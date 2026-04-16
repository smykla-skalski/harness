import Foundation

extension HarnessMonitorStore {
  // MARK: - Navigation history

  public var canNavigateBack: Bool { !navigationBackStack.isEmpty }
  public var canNavigateForward: Bool { !navigationForwardStack.isEmpty }

  public func navigateBack() async {
    guard !navigationBackStack.isEmpty else { return }
    let destination = navigationBackStack.removeLast()
    navigationForwardStack.append(selectedSessionID)
    isNavigatingHistory = true
    defer { isNavigatingHistory = false }
    await loadSessionWithoutHistory(destination)
  }

  public func navigateForward() async {
    guard !navigationForwardStack.isEmpty else { return }
    let destination = navigationForwardStack.removeLast()
    navigationBackStack.append(selectedSessionID)
    isNavigatingHistory = true
    defer { isNavigatingHistory = false }
    await loadSessionWithoutHistory(destination)
  }

  func recordNavigation(to sessionID: String?) {
    guard !isNavigatingHistory else { return }
    guard selectedSessionID != sessionID else { return }
    navigationBackStack.append(selectedSessionID)
    if !navigationForwardStack.isEmpty {
      navigationForwardStack.removeAll()
    }
  }

  private func loadSessionWithoutHistory(_ sessionID: String?) async {
    selectionTask?.cancel()
    primeSessionSelection(sessionID)

    guard let sessionID else {
      selectionTask = nil
      stopSessionStream()
      return
    }

    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.performSessionSelection(sessionID: sessionID)
      if !Task.isCancelled, self.selectedSessionID == sessionID {
        self.selectionTask = nil
      }
    }
    selectionTask = task
    await task.value
  }
}
