import SwiftUI

extension SessionWindowView {
  func updateDetailColumnWidth(
    _ width: CGFloat,
    visibleBinding: Binding<Bool>,
    preferredBinding: Binding<Bool>,
    announce: Bool = true
  ) {
    guard abs(detailColumnWidth - width) > 0.5 else { return }
    detailColumnWidth = width
    reconcileInspectorVisibility(
      visibleBinding: visibleBinding,
      preferredBinding: preferredBinding,
      announce: announce
    )
  }

  func reconcileInspectorVisibility(
    visibleBinding: Binding<Bool>,
    preferredBinding: Binding<Bool>,
    announce: Bool = true
  ) {
    setInspectorVisibility(
      SessionInspectorVisibilityPolicy.resolvedVisible(
        preferredVisible: preferredBinding.wrappedValue,
        canPresent: canPresentInspector
      ),
      binding: visibleBinding,
      announce: announce
    )
  }

  func setInspectorPreference(
    _ preferredVisible: Bool,
    visibleBinding: Binding<Bool>,
    preferredBinding: Binding<Bool>,
    announce: Bool = true
  ) {
    guard preferredBinding.wrappedValue != preferredVisible
      || visibleBinding.wrappedValue != preferredVisible
    else { return }
    preferredBinding.wrappedValue = preferredVisible
    reconcileInspectorVisibility(
      visibleBinding: visibleBinding,
      preferredBinding: preferredBinding,
      announce: announce
    )
  }

  func setInspectorVisibility(
    _ visible: Bool,
    binding: Binding<Bool>,
    announce: Bool = true
  ) {
    guard binding.wrappedValue != visible else { return }
    binding.wrappedValue = visible
    if announce {
      SessionInspectorAnnouncer.announce(visible: visible)
    }
  }
}
