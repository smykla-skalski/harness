import SwiftUI

extension SessionWindowView {
  var inspectorWidth: Double {
    get { liveInspectorWidthDraft ?? storedInspectorWidth }
    nonmutating set { liveInspectorWidthDraft = newValue }
  }

  var inspectorWidthBinding: Binding<Double> {
    Binding(
      get: { inspectorWidth },
      set: { newValue in
        guard abs(inspectorWidth - newValue) > 0.5 else { return }
        liveInspectorWidthDraft = newValue
      }
    )
  }

  var contentColumnWidth: Double {
    get { liveContentColumnWidthDraft ?? storedContentColumnWidth }
    nonmutating set { liveContentColumnWidthDraft = newValue }
  }

  var contentColumnWidthBinding: Binding<Double> {
    Binding(
      get: { contentColumnWidth },
      set: { newValue in
        guard abs(contentColumnWidth - newValue) > 0.5 else { return }
        liveContentColumnWidthDraft = newValue
      }
    )
  }

  func commitInspectorWidth(_ width: Double) {
    let resolvedWidth = max(220, min(width, 420))
    if abs(inspectorWidth - resolvedWidth) > 0.5 {
      liveInspectorWidthDraft = resolvedWidth
    }
    if abs(storedInspectorWidth - resolvedWidth) > 0.5 {
      storedInspectorWidth = resolvedWidth
    }
  }

  func commitContentColumnWidth(_ width: Double) {
    if abs(contentColumnWidth - width) > 0.5 {
      liveContentColumnWidthDraft = width
    }
    if abs(storedContentColumnWidth - width) > 0.5 {
      storedContentColumnWidth = width
    }
  }
}
