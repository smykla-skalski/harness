import HarnessMonitorKit
import HarnessMonitorPolicyModels
import SwiftUI

extension PolicyCanvasEditForm {
  func automationReviewOCRControls(
    ocr: AutomationPolicyOCRConfiguration,
    binding: PolicyGraphAutomationBinding
  ) -> some View {
    Group {
      automationPickerField(
        label: "OCR",
        title: "Recognition level",
        values: AutomationPolicyOCRConfiguration.RecognitionLevel.allCases,
        selection: ocr.recognitionLevel,
        set: { commitAutomationBinding(binding.settingOCRRecognitionLevel($0)) }
      )
      Toggle(
        "Detect language",
        isOn: Binding(
          get: { ocr.automaticallyDetectsLanguage },
          set: { commitAutomationBinding(binding.settingOCRAutomaticallyDetectsLanguage($0)) }
        )
      )
      .scaledFont(.caption)
      Toggle(
        "Language correction",
        isOn: Binding(
          get: { ocr.usesLanguageCorrection },
          set: { commitAutomationBinding(binding.settingOCRUsesLanguageCorrection($0)) }
        )
      )
      .scaledFont(.caption)
    }
  }

  func automationReviewExtractionFields(
    extraction: ReviewPullRequestExtractionConfiguration,
    binding: PolicyGraphAutomationBinding
  ) -> some View {
    Group {
      automationPickerField(
        label: "Scope",
        title: "Result scope",
        values: ReviewPullRequestExtractionConfiguration.ResultScope.allCases,
        selection: extraction.resultScope,
        set: { commitAutomationBinding(binding.settingReviewResultScope($0)) }
      )
      automationPickerField(
        label: "Failing",
        title: "Failing signal",
        values: ReviewPullRequestExtractionConfiguration.FailureSignalMode.allCases,
        selection: extraction.failureSignalMode,
        set: { commitAutomationBinding(binding.settingReviewFailureSignalMode($0)) }
      )
      automationPickerField(
        label: "Repos",
        title: "Repository resolution",
        values: ReviewPullRequestExtractionConfiguration.RepositoryMode.allCases,
        selection: extraction.repositoryMode,
        set: { commitAutomationBinding(binding.settingReviewRepositoryMode($0)) }
      )
      PolicyCanvasInspectorCommitTextField(
        label: "Policy repos",
        placeholder: "owner/repo, owner/repo",
        value: extraction.policyRepositories.joined(separator: ", "),
        focusField: .automationReviewRepositories,
        focusedField: $focusedField,
        accessibilityIdentifier:
          HarnessMonitorAccessibility.policyCanvasInspectorField("automation-review-repos"),
        commit: { commitAutomationBinding(binding.settingReviewPolicyRepositories($0)) }
      )
      .disabled(extraction.repositoryMode != .policyRepositories)
      automationPickerField(
        label: "Output",
        title: "Output format",
        values: ReviewPullRequestExtractionConfiguration.OutputFormat.allCases,
        selection: extraction.outputFormat,
        set: { commitAutomationBinding(binding.settingReviewOutputFormat($0)) }
      )
    }
  }
}
