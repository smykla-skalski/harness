import HarnessMonitorKit
import SwiftUI

extension SessionWindowCreateForm {
  func validationMessage(
    for field: SessionWindowCreateFormValidationField
  ) -> String? {
    guard validationResult?.field == field else { return nil }
    return validationResult?.message
  }

  func clearValidationIfNeeded(title: String?, runtime: String?) {
    switch validationResult?.field {
    case .name where title != nil:
      validationResult = nil
    case .capability where runtime != nil:
      validationResult = nil
    case .form, .name, .capability, nil:
      break
    }
  }

  func clearValidationIfResolved() {
    guard validationResult != nil else { return }
    validationResult = SessionWindowCreateFormValidation.result(
      for: draft,
      capabilityOptions: activeAgentCapabilityOptions
    )
  }

  func focusValidationField(_ field: SessionWindowCreateFormValidationField) {
    if field == .name {
      focusedField = .name
    }
  }
}
