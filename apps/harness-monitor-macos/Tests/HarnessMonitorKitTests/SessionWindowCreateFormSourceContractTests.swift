import Foundation
import Testing

@testable import HarnessMonitorKit

extension SessionWindowCreateFormMetricsTests {
  @Test("Create form keeps focus and cancel affordances in source")
  func createFormKeepsFocusAndCancelAffordancesInSource() throws {
    let source = try createFormSourceSnapshot()

    assertCreateFormFocusAndTextInputContracts(source)
    assertCreateFormRuntimeLayoutContracts(source)
    assertCreateFormSubmissionAndKeyboardContracts(source)
  }

  private struct CreateFormSourceSnapshot {
    let form: String
    let submission: String
    let runtimePane: String
    let runtimePaneSupport: String
    let helper: String
    let multiline: String
    let theme: String
  }

  private func createFormSourceSnapshot() throws -> CreateFormSourceSnapshot {
    try CreateFormSourceSnapshot(
      form: sourceFile(named: "SessionWindowCreateForm.swift"),
      submission: sourceFile(named: "SessionWindowCreateForm+Submission.swift"),
      runtimePane: sourceFile(named: "SessionWindowCreateAgentRuntimePane.swift"),
      runtimePaneSupport: sourceFile(named: "SessionWindowCreateAgentRuntimePane+Support.swift"),
      helper: sourceFile(named: "SessionWindowCreateForm+Helpers.swift"),
      multiline: previewableSourceFile(
        at: "Views/Shared/HarnessMonitorMultilineTextField.swift"),
      theme: previewableSourceFile(at: "Theme/HarnessMonitorTextSize.swift")
    )
  }

  private func assertCreateFormFocusAndTextInputContracts(
    _ source: CreateFormSourceSnapshot
  ) {
    #expect(source.form.contains("@FocusState"))
    #expect(source.form.contains("Button(\"Cancel\", role: .cancel)"))
    #expect(source.submission.contains("SessionWindowCreateFormValidation.result"))
    #expect(source.form.contains("validationMessage(for: .name)"))
    #expect(source.form.contains("Validation error:"))
    #expect(source.submission.contains("focusValidationField(validationResult.field)"))
    #expect(source.form.contains("LabeledContent(\"Name\")"))
    #expect(source.form.contains("LabeledContent(\"Prompt\")"))
    #expect(source.form.contains("Spacer(minLength: 0)"))
    #expect(source.form.contains("Text(draft.kind.title)"))
    #expect(source.form.contains("TextField(\"\", text: title)"))
    #expect(source.form.contains(".harnessActionButtonStyle(variant: .bordered, tint: .secondary)"))
    #expect(source.form.contains(".controlSize(HarnessMonitorControlMetrics.compactControlSize)"))
    #expect(source.form.contains("placeholder: \"\""))
    #expect(source.form.contains("case commandOverride"))
    #expect(source.form.contains("equals: .commandOverride"))
    #expect(!source.form.contains("TextEditor(text: prompt)"))
    #expect(!source.form.contains("TextEditor(text: argvOverrideText)"))
    #expect(!source.form.contains("SessionWindowCreateSplitInputRow("))
    #expect(source.helper.contains("LabeledContent(\"Custom model\")"))
    #expect(source.helper.contains("LabeledContent(\"Model (optional)\")"))
    #expect(source.helper.contains("LabeledContent(\"Effort (optional)\")"))
    #expect(source.theme.contains(".multilineTextAlignment(.leading)"))
    #expect(!source.theme.contains("HarnessMonitorNativeTextFieldChromeMetrics"))
    #expect(!source.theme.contains("HarnessMonitorNativeTextFieldConfiguration"))
    #expect(!source.theme.contains(".introspect("))
    #expect(source.theme.contains("HarnessMonitorTextSize.nativeInputFont(at: textSizeIndex)"))
    #expect(
      source.theme.contains("HarnessMonitorTextSize.nativeInputControlSize(at: textSizeIndex)")
    )
    #expect(source.theme.contains(".textFieldStyle(.roundedBorder)"))
    #expect(source.theme.contains(".frame(maxWidth: .infinity)"))
    #expect(!source.multiline.contains("NSViewRepresentable"))
    #expect(source.multiline.contains("TextField(placeholder, text: $text, axis: .vertical)"))
    #expect(source.multiline.contains(".multilineTextAlignment(.leading)"))
    #expect(source.multiline.contains(".textFieldStyle(.roundedBorder)"))
    #expect(source.multiline.contains(".lineLimit(lineLimit)"))
    #expect(source.multiline.contains("HarnessMonitorTextSize.nativeInputFont(at: textSizeIndex)"))
    #expect(
      source.multiline.contains(
        "HarnessMonitorTextSize.nativeInputControlSize(at: textSizeIndex)"
      )
    )
    #expect(!source.multiline.contains("makeFirstResponder(nil)"))
  }

  private func assertCreateFormRuntimeLayoutContracts(_ source: CreateFormSourceSnapshot) {
    #expect(source.form.contains("embeddedAgentRuntimeSections"))
    #expect(source.form.contains("embedsRuntimeConfiguration"))
    #expect(source.form.contains("SessionWindowCreateTransportChoicesGroup("))
    #expect(source.form.contains("SessionWindowCreateRuntimeModelPickerRow("))
    #expect(source.form.contains("SessionWindowCreateRuntimeCustomModelRow("))
    #expect(source.form.contains("SessionWindowCreateRuntimeEffortRow("))
    #expect(!source.form.contains("SessionWindowCreateRuntimeModelControls("))
    #expect(source.form.contains(".equatable()"))
    #expect(!source.form.contains("ViewThatFits(in: .horizontal)"))
    #expect(!source.form.contains("SessionWindowCreateFormAgentLaunchToggle("))
    #expect(!source.form.contains("SessionWindowCreateFormCapabilityPicker("))
    #expect(!source.form.contains("SessionWindowCreateAgentRuntimeContent("))
    #expect(!source.form.contains("DisclosureGroup(\""))
    #expect(!source.form.contains("SessionWindowCreateFieldBlock("))
    #expect(
      source.form.contains(".contentMargins(.horizontal, metrics.formPadding, for: .scrollContent)")
    )
    #expect(
      source.form.contains(".contentMargins(.vertical, metrics.formPadding, for: .scrollContent)")
    )
    #expect(!source.form.contains(".padding(metrics.formPadding)"))
    #expect(source.form.contains("Picker(\"Provider\", selection: selectedProviderID)"))
    #expect(!source.form.contains("Picker(\"Create\", selection: useCodex)"))
    #expect(source.form.contains("Text(\"Runtime\")"))
    #expect(source.form.contains("Text(\"Session\")"))
    #expect(source.form.contains("Text(\"Advanced overrides\")"))
    #expect(!source.form.contains("Optional project directory override"))
    #expect(source.runtimePaneSupport.contains("SessionWindowCreateProviderListRow"))
    #expect(source.runtimePane.contains("SessionWindowCreateProviderButtonList("))
    #expect(source.runtimePane.contains("HarnessMonitorColumnScrollView("))
    #expect(
      source.runtimePane.contains("SessionWindowCreateSidebarSectionHeader(title: \"Provider\")"))
    #expect(source.runtimePane.contains("\"New agent\""))
    #expect(!source.runtimePane.contains("sessionWindowCreateModePicker"))
    #expect(!source.runtimePane.contains("List(selection: selectedProviderID)"))
    #expect(!source.runtimePane.contains("LazyVGrid("))
    #expect(source.runtimePane.contains("loadAgentCatalogStateIfNeeded("))
    #expect(!source.runtimePane.contains("capabilitySummary"))
    #expect(!source.runtimePane.contains("providerDescription"))
    #expect(!source.runtimePane.contains("minHeight: 36"))
    #expect(!source.runtimePane.contains("Divider()"))
    #expect(
      !source.runtimePane.contains(
        ".padding(.horizontal, embeddedInForm ? 0 : HarnessMonitorTheme.spacingXS)"))
    #expect(source.runtimePaneSupport.contains(".truncationMode(.tail)"))
    #expect(!source.runtimePane.contains(".padding(.horizontal, HarnessMonitorTheme.spacingMD)"))
    #expect(source.runtimePaneSupport.contains(".padding(.vertical, HarnessMonitorTheme.spacingXS)"))
    #expect(!source.runtimePane.contains(".buttonStyle(.plain)"))
  }

  private func assertCreateFormSubmissionAndKeyboardContracts(
    _ source: CreateFormSourceSnapshot
  ) {
    #expect(source.form.contains("Picker(\"Severity\", selection: taskSeverity)"))
    #expect(source.submission.contains("sessionID: draft.sessionID"))
    #expect(source.submission.contains("startAcpAgent("))
    #expect(!source.submission.contains("createCodexRun(named:"))
    #expect(!source.submission.contains("draft.useCodex"))
    #expect(!source.form.contains("requestCreateTaskSheet()"))
    #expect(!source.form.contains(".keyboardShortcut(\"n\", modifiers: [.command])"))
    #expect(source.form.contains(".keyboardShortcut(.defaultAction)"))
  }
}
