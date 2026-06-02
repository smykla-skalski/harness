import SwiftUI
import HarnessMonitorPolicyCanvasAlgorithms

extension View {
  func harnessFocusedSceneValue<Value: Equatable>(
    _ keyPath: WritableKeyPath<FocusedValues, Value?>,
    _ value: Value?
  ) -> some View {
    modifier(HarnessDeferredFocusedSceneValue(keyPath: keyPath, value: value))
  }
}

private struct HarnessDeferredFocusedSceneValue<Value: Equatable>: ViewModifier {
  let keyPath: WritableKeyPath<FocusedValues, Value?>
  let value: Value?
  @State private var publishedValue: Value?
  @State private var didPublishInitialValue = false

  func body(content: Content) -> some View {
    content
      .focusedSceneValue(keyPath, publishedValue)
      .task(id: value) {
        await publish(value)
      }
  }

  @MainActor
  private func publish(_ value: Value?) async {
    if !didPublishInitialValue {
      didPublishInitialValue = true
      try? await Task.sleep(for: .milliseconds(120))
    } else {
      await Task.yield()
    }
    guard !Task.isCancelled, publishedValue != value else {
      return
    }
    publishedValue = value
  }
}
