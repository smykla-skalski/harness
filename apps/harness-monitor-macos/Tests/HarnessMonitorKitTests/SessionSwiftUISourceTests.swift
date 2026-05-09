import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Session SwiftUI source contracts")
struct SessionSwiftUISourceTests {
  @Test("Task and decision detail use native form sections while detail scroll surface stays shared")
  func taskAndDecisionDetailUseNativeFormSectionsWhileDetailScrollSurfaceStaysShared() throws {
    let taskSource = try sourceFile(at: "Views/Sessions/SessionTaskDetailPane.swift")
    let decisionSource = try sourceFile(at: "Views/Sessions/SessionDecisionDetailPane.swift")
    let codexSource = try sourceFile(at: "Views/Sessions/SessionCodexRunDetailSection.swift")
    let agentDetailSource = try sourceFile(at: "Views/Sessions/SessionAgentDetailSection.swift")
    let agentViewportSource = try sourceFile(at: "Views/Sessions/SessionAgentLaneViews.swift")
    let columnsSource = try sourceFile(at: "Views/Sessions/SessionWindowView+Columns.swift")

    #expect(taskSource.contains("SessionDetailScrollSurface(contentPadding: 0)"))
    #expect(taskSource.contains("Form {"))
    #expect(taskSource.contains(".harnessNativeFormContainer()"))
    #expect(taskSource.contains(".contentMargins(.horizontal, metrics.contentPadding, for: .scrollContent)"))
    #expect(taskSource.contains(".contentMargins(.vertical, metrics.contentPadding, for: .scrollContent)"))
    #expect(taskSource.contains(".scrollDisabled(true)"))
    #expect(taskSource.contains(".scrollContentBackground(.hidden)"))
    #expect(!taskSource.contains("SessionDetailPanel("))
    #expect(decisionSource.contains("SessionDetailScrollSurface(contentPadding: 0)"))
    #expect(decisionSource.contains("SessionFilteredDecisionNotice("))
    #expect(decisionSource.contains("Form {"))
    #expect(decisionSource.contains(".harnessNativeFormContainer()"))
    #expect(decisionSource.contains(".contentMargins(.horizontal, metrics.contentPadding, for: .scrollContent)"))
    #expect(decisionSource.contains(".contentMargins(.top, formTopContentPadding, for: .scrollContent)"))
    #expect(decisionSource.contains(".contentMargins(.bottom, metrics.contentPadding, for: .scrollContent)"))
    #expect(decisionSource.contains(".scrollDisabled(true)"))
    #expect(decisionSource.contains(".scrollContentBackground(.hidden)"))
    #expect(!decisionSource.contains("SessionDetailPanel("))
    #expect(codexSource.contains("SessionDetailScrollSurface("))
    #expect(!codexSource.contains("ScrollView {"))
    #expect(!agentDetailSource.contains("SessionDetailScrollSurface("))
    #expect(agentViewportSource.contains(".scrollBounceBehavior(.always, axes: .vertical)"))
    #expect(columnsSource.contains("SessionDetailEmptySurface {"))
  }

  @Test("Form sections use shared font scaling helpers")
  func formSectionsUseSharedFontScalingHelpers() throws {
    let themeSource = try sourceFile(at: "Theme/HarnessMonitorTextSize.swift")
    let sectionFiles = [
      "Views/Sessions/SessionTaskDetailPane.swift",
      "Views/Sessions/SessionDecisionDetailPane.swift",
      "Views/Sessions/SessionWindowCreateForm.swift",
      "Views/Settings/SettingsConnectionCard.swift",
      "Views/Settings/SettingsCodexSection.swift",
      "Views/Settings/SettingsConnectionSection.swift",
      "Views/Settings/SettingsDiagnosticsOverview.swift",
      "Views/Settings/SettingsDiagnosticsSection.swift",
      "Views/Settings/SettingsNotificationsSection.swift",
      "Views/Settings/SettingsPathsSection.swift",
      "Views/Settings/SettingsRecentEventsCard.swift",
      "Views/Settings/SettingsStatusSection.swift",
      "Views/Settings/Supervisor/SettingsSupervisorBackgroundPane.swift",
    ]
    let footerFiles = [
      "Views/Settings/SettingsCodexSection.swift",
      "Views/Settings/SettingsNotificationsSection.swift",
      "Views/Settings/Supervisor/SettingsSupervisorBackgroundPane.swift",
    ]
    let containerFiles = [
      "Views/Sessions/SessionTaskDetailPane.swift",
      "Views/Sessions/SessionDecisionDetailPane.swift",
      "Views/Sessions/SessionWindowCreateForm.swift",
    ]

    #expect(themeSource.contains("func harnessNativeFormSectionHeader()"))
    #expect(themeSource.contains("func harnessNativeFormSectionFooter()"))
    #expect(themeSource.contains(".scaledFont(.caption.weight(.semibold))"))
    #expect(themeSource.contains(".accessibilityAddTraits(.isHeader)"))
    #expect(themeSource.contains(".scaledFont(.caption)"))

    for relativePath in sectionFiles {
      let source = try sourceFile(at: relativePath)
      #expect(source.contains(".harnessNativeFormSectionHeader()"))
      #expect(!source.contains("Section(\""))
    }

    for relativePath in footerFiles {
      let source = try sourceFile(at: relativePath)
      #expect(source.contains(".harnessNativeFormSectionFooter()"))
    }

    for relativePath in containerFiles {
      let source = try sourceFile(at: relativePath)
      #expect(source.contains(".harnessNativeFormContainer()"))
    }

    let createFormSource = try sourceFile(at: "Views/Sessions/SessionWindowCreateForm.swift")
    #expect(!createFormSource.contains("Section(draft.kind.title)"))
    #expect(createFormSource.contains("embeddedAgentRuntimeSections"))
    #expect(createFormSource.contains("Picker(\"Provider\", selection: selectedProviderID)"))
    #expect(createFormSource.contains(".contentMargins(.horizontal, metrics.formPadding, for: .scrollContent)"))
    #expect(createFormSource.contains(".contentMargins(.vertical, metrics.formPadding, for: .scrollContent)"))
    #expect(createFormSource.contains(".scrollContentBackground(.hidden)"))
    #expect(!createFormSource.contains(".padding(metrics.formPadding)"))
    #expect(!createFormSource.contains("DisclosureGroup(\""))
    #expect(!createFormSource.contains("SessionWindowCreateFieldBlock("))
  }

  @Test("Session view state wrappers stay private")
  func sessionViewStateWrappersStayPrivate() throws {
    let sessionWindowSource = try sourceFile(at: "Views/Sessions/SessionWindowView.swift")
    let createFormSource = try sourceFile(at: "Views/Sessions/SessionWindowCreateForm.swift")

    #expect(sessionWindowSource.contains("@State private var decisionCacheStorage"))
    #expect(!sessionWindowSource.contains("@State var allSessionDecisionsCache"))
    #expect(!sessionWindowSource.contains("@State var matchingDecisionsCache"))
    #expect(!sessionWindowSource.contains("@State var detailRenderedSelection"))
    #expect(!sessionWindowSource.contains("@State var contentRenderedRoute"))
    #expect(sessionWindowSource.contains("private var focusModeStorage = false"))
    #expect(sessionWindowSource.contains("private var inspectorVisibleStorage = false"))
    #expect(sessionWindowSource.contains("private var inspectorPreferredStorage = false"))
    #expect(sessionWindowSource.contains("private var inspectorWidthStorage = 280.0"))
    #expect(sessionWindowSource.contains("private var sidebarWidthStorage = 220.0"))
    #expect(
      sessionWindowSource.contains(
        "private var contentColumnWidthStorage = SessionContentDetailSplitLayout.defaultContentWidth"
      )
    )
    #expect(sessionWindowSource.contains("private var columnVisibilityRawStorage = \"automatic\""))
    #expect(!sessionWindowSource.contains("@SceneStorage(\"session.focusMode\")\n  var focusMode = false"))
    #expect(!sessionWindowSource.contains("@SceneStorage(\"session.inspector.visible\")\n  var inspectorVisible = false"))
    #expect(!sessionWindowSource.contains("@SceneStorage(\"session.inspector.preferred\")\n  var inspectorPreferred = false"))

    #expect(createFormSource.contains("@State private var stateStorage"))
    #expect(createFormSource.contains("@FocusState private var focusedFieldStorage"))
    #expect(!createFormSource.contains("@State var validationResult"))
    #expect(!createFormSource.contains("@State var agentCapabilityOptions"))
    #expect(!createFormSource.contains("@FocusState var focusedField"))
  }

  @Test("Session content columns extend behind toolbar glass")
  func sessionContentColumnsExtendBehindToolbarGlass() throws {
    let columnsSource = try sourceFile(at: "Views/Sessions/SessionWindowView+Columns.swift")

    #expect(columnsSource.contains(".backgroundExtensionEffect()"))
  }

  @Test("Toast keeps its AppKit pointer shield while spinner stays pure SwiftUI")
  func toastKeepsPointerShieldWhileSpinnerAvoidsInterop() throws {
    let toastSource = try sourceFile(at: "Views/Attention/AcpPermissionAttentionToastView.swift")
    let spinnerSource = try sourceFile(at: "Views/Shared/HarnessMonitorSpinner.swift")

    #expect(toastSource.contains("@Entry public var acpToastOpenDecisions"))
    #expect(toastSource.contains("@Entry public var acpToastDismiss"))
    #expect(!toastSource.contains("EnvironmentKey"))
    #expect(toastSource.contains("NSViewRepresentable"))
    #expect(toastSource.contains("override func mouseDown"))
    #expect(toastSource.contains("override func rightMouseDown"))
    #expect(toastSource.contains("override func otherMouseDown"))
    #expect(!spinnerSource.contains("NSViewRepresentable"))
  }

  private func sourceFile(at relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
