import CoreGraphics
import HarnessMonitorKit

extension WorkspaceWindowView {
  func recordMeasuredViewportPoints(_ viewportSize: CGSize) {
    guard viewModel.lastMeasuredViewportPoints != viewportSize else {
      return
    }
    viewModel.lastMeasuredViewportPoints = viewportSize
  }

  func clearMeasuredViewportTerminalSize() {
    guard viewModel.lastMeasuredViewportTerminalSize != nil else {
      return
    }
    viewModel.lastMeasuredViewportTerminalSize = nil
  }

  func recordMeasuredViewportTerminalSize(_ terminalSize: AgentTuiSize) {
    guard viewModel.lastMeasuredViewportTerminalSize != terminalSize else {
      return
    }
    viewModel.lastMeasuredViewportTerminalSize = terminalSize
  }

  func recordAutomaticViewportSize(_ terminalSize: AgentTuiSize) {
    guard viewModel.lastMeasuredViewportSize != terminalSize else {
      return
    }
    viewModel.lastMeasuredViewportSize = terminalSize
  }

  func recordExpectedViewportSize(_ terminalSize: AgentTuiSize) {
    guard viewModel.expectedSize != terminalSize else {
      return
    }
    viewModel.expectedSize = terminalSize
  }
}
