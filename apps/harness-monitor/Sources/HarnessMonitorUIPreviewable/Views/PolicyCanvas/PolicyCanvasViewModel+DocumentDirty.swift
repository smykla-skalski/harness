// Companion to PolicyCanvasViewModel.swift.
// Document-dirty helpers used by committed mutation sites.
import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import Observation
import SwiftUI

extension PolicyCanvasViewModel {
  /// Commit-time helper for mutations that may either diverge from or return to
  /// the saved backing document.
  func updateDocumentDirtyAfterCommittedMutation() {
    guard backingDocument != nil else {
      markDocumentDirty()
      return
    }
    markDocumentDirty()
    reconcileDocumentDirtyWithBackingDocument()
  }
}
