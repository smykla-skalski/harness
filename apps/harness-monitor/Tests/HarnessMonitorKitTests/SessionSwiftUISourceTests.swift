import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Session SwiftUI source contracts")
struct SessionSwiftUISourceTests {
  @Test(
    "Task detail avoids nested forms while session decisions reuse the rich shared detail"
  )
  func taskAndDecisionDetailSurfacesStayAlignedWithTheirSharedContainers() throws {
    let taskSource = try sourceFile(at: "Views/Sessions/SessionTaskDetailPane.swift")
    let decisionSource = try sourceFile(at: "Views/Sessions/SessionDecisionDetailPane.swift")
    let codexSource = try sourceFile(at: "Views/Sessions/SessionCodexRunDetailSection.swift")
    let agentDetailSource = try sourceFile(at: "Views/Sessions/SessionAgentDetailSection.swift")
    let agentViewportSource = try sourceFile(at: "Views/Sessions/SessionAgentLaneViews.swift")
    let columnsSource = try sourceFile(at: "Views/Sessions/SessionWindowView+Columns.swift")
    let detailFocusSource = try sourceFile(at: "Views/Sessions/SessionWindowView+DetailFocus.swift")

    #expect(
      taskSource.contains("SessionDetailScrollSurface(contentPadding: metrics.contentPadding)")
    )
    #expect(taskSource.contains("VStack(alignment: .leading, spacing: metrics.sectionSpacing)"))
    #expect(taskSource.contains("SessionDetailPanel(title: \"Task\")"))
    #expect(taskSource.contains("SessionDetailFactsGrid("))
    #expect(taskSource.contains(".harnessNativeFormControl()"))
    #expect(!taskSource.contains("Form {"))
    #expect(!taskSource.contains(".harnessNativeFormContainer()"))
    #expect(!taskSource.contains(".contentMargins("))
    #expect(!taskSource.contains(".scrollContentBackground(.hidden)"))
    #expect(decisionSource.contains("SessionFilteredDecisionNotice("))
    #expect(decisionSource.contains("DecisionDetailView("))
    #expect(decisionSource.contains("handler: actionHandler"))
    #expect(decisionSource.contains("auditEvents: auditEvents"))
    #expect(
      decisionSource.contains(
        "auditEventPayloadPresentations: auditEventPayloadPresentations"
      )
    )
    #expect(!decisionSource.contains("HarnessMonitorJSONCodeBlock("))
    #expect(!decisionSource.contains("Form {"))
    #expect(codexSource.contains("SessionDetailScrollSurface("))
    #expect(!codexSource.contains("ScrollView {"))
    #expect(!agentDetailSource.contains("SessionDetailScrollSurface("))
    #expect(agentViewportSource.contains(".scrollBounceBehavior(.always, axes: .vertical)"))
    #expect(columnsSource.contains("SessionDetailEmptySurface {"))
    #expect(
      detailFocusSource.contains(
        "auditEventPayloadPresentations: stateCache.decisionRuntime.auditEventPayloadPresentations"
      )
    )
  }

  @Test("Form sections use shared font scaling helpers")
  func formSectionsUseSharedFontScalingHelpers() throws {
    let themeSource = try sourceFile(at: "Theme/HarnessMonitorTextSize.swift")
    let sectionFiles = [
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
      "Views/Sessions/SessionWindowCreateForm.swift"
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
    #expect(
      createFormSource.contains(
        ".contentMargins(.horizontal, metrics.formPadding, for: .scrollContent)"
      )
    )
    #expect(
      createFormSource.contains(
        ".contentMargins(.vertical, metrics.formPadding, for: .scrollContent)"
      )
    )
    #expect(createFormSource.contains(".scrollContentBackground(.hidden)"))
    #expect(!createFormSource.contains(".padding(metrics.formPadding)"))
    #expect(!createFormSource.contains("DisclosureGroup(\""))
    #expect(!createFormSource.contains("SessionWindowCreateFieldBlock("))
  }

  @Test("Settings string pickers and capability lists keep duplicate values off self identity")
  func settingsStringCollectionsAvoidSelfIdentity() throws {
    let codexSource = try sourceFile(at: "Views/Settings/SettingsCodexSection.swift")
    let parameterRowSource = try sourceFile(
      at: "Views/Settings/Supervisor/SettingsSupervisorRulesPane+ParameterRow.swift"
    )

    #expect(codexSource.contains("ForEach(Array(capabilityNames.enumerated()), id: \\.offset)"))
    #expect(!codexSource.contains("ForEach(capabilityNames, id: \\.self)"))
    #expect(
      parameterRowSource.contains("ForEach(Array(allowedValues.enumerated()), id: \\.offset)")
    )
    #expect(!parameterRowSource.contains("ForEach(allowedValues, id: \\.self)"))
  }

  @Test("Session runtime strings and composer rows avoid self identity")
  func sessionRuntimeStringsAndComposerRowsAvoidSelfIdentity() throws {
    let runtimeRowsSource = try sourceFile(
      at: "Views/Sessions/SessionWindowCreateForm+RuntimeRows.swift")
    let composerSource = try sourceFile(at: "Views/Sessions/SessionAgentComposer.swift")

    #expect(runtimeRowsSource.contains("ForEach(Array(values.enumerated()), id: \\.offset)"))
    #expect(!runtimeRowsSource.contains("ForEach(values, id: \\.self)"))
    #expect(
      composerSource.contains(
        "ForEach(Array(SessionAgentComposerKeyLayout.rows.enumerated()), id: \\.offset)")
    )
    #expect(!composerSource.contains("ForEach(SessionAgentComposerKeyLayout.rows, id: \\.self)"))
  }

  @Test("Session view state wrappers stay private")
  func sessionViewStateWrappersStayPrivate() throws {
    let sessionWindowSource = try sourceFile(at: "Views/Sessions/SessionWindowView.swift")
    let standardLayoutSource = try sourceFile(
      at: "Views/Sessions/SessionWindowStandardLayout.swift")
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
    #expect(sessionWindowSource.contains("private var sidebarWidthStorage = 200.0"))
    #expect(sessionWindowSource.contains("@State private var liveInspectorWidthStorage: Double?"))
    #expect(
      sessionWindowSource.contains("@State private var liveContentColumnWidthStorage: Double?")
    )
    #expect(
      sessionWindowSource.contains(
        "private var contentColumnWidthStorage = SessionContentDetailSplitLayout.defaultContentWidth"
      )
    )
    #expect(!sessionWindowSource.contains("private var columnVisibilityRawStorage"))
    #expect(standardLayoutSource.contains("private var columnVisibilityRawStorage = \"automatic\""))
    #expect(
      !sessionWindowSource.contains(
        "@SceneStorage(\"session.focusMode\")\n  var focusMode = false"
      )
    )
    #expect(
      !sessionWindowSource.contains(
        "@SceneStorage(\"session.inspector.visible\")\n  var inspectorVisible = false"
      )
    )
    #expect(
      !sessionWindowSource.contains(
        "@SceneStorage(\"session.inspector.preferred\")\n  var inspectorPreferred = false"
      )
    )

    #expect(createFormSource.contains("@State private var stateStorage"))
    #expect(createFormSource.contains("@FocusState private var focusedFieldStorage"))
    #expect(!createFormSource.contains("@State var validationResult"))
    #expect(!createFormSource.contains("@State var agentCapabilityOptions"))
    #expect(!createFormSource.contains("@FocusState var focusedField"))
  }

  @Test("Session content columns use native scroll edge without mirrored toolbar hosts")
  func sessionContentColumnsUseNativeScrollEdgeWithoutMirroredToolbarHosts() throws {
    let columnsSource = try sourceFile(at: "Views/Sessions/SessionWindowView+Columns.swift")
    let extensionEffectSource = try sourceFile(
      at: "Views/Sessions/SessionWindowBackgroundExtensionEffect.swift"
    )
    let surfaceSource = try sourceFile(at: "Views/Sessions/SessionDetailSurface.swift")
    let columnScrollSource = try sourceFile(at: "Views/Shared/HarnessMonitorColumnScrollView.swift")

    #expect(!columnsSource.contains("SessionBackgroundExtensionSurface()"))
    #expect(!columnsSource.contains(".sessionWindowBackgroundExtensionEffect()"))
    #expect(
      extensionEffectSource.contains("@AppStorage(HarnessMonitorBackdropDefaults.modeKey)")
    )
    #expect(extensionEffectSource.contains("@Environment(\\.accessibilityReduceTransparency)"))
    #expect(extensionEffectSource.contains("if reduceTransparency || backdropMode == .none"))
    #expect(extensionEffectSource.contains("func harnessMonitorBackgroundExtensionEffect()"))
    #expect(
      !extensionEffectSource.contains("func harnessMonitorToolbarBackgroundExtensionEffect()"))
    #expect(!extensionEffectSource.contains("func sessionWindowBackgroundExtensionEffect()"))
    #expect(extensionEffectSource.contains("content.backgroundExtensionEffect()"))
    #expect(!surfaceSource.contains(".backgroundExtensionEffect()"))
    #expect(surfaceSource.contains("topScrollEdgeEffect: .soft"))
    #expect(!columnScrollSource.contains("content.scrollContentBackground(.visible)"))
    #expect(columnScrollSource.contains("content.scrollEdgeEffectStyle(.soft, for: .top)"))
    #expect(columnScrollSource.contains("content.scrollEdgeEffectStyle(.hard, for: .top)"))
  }

  @Test("Dashboard detail surface avoids mirrored toolbar extension hosts")
  func dashboardDetailSurfaceAvoidsMirroredToolbarExtensionHosts() throws {
    let dashboardSource = try sourceFile(at: "Views/Dashboard/DashboardWindowSupport.swift")

    #expect(!dashboardSource.contains(".harnessMonitorToolbarBackgroundExtensionEffect()"))
    #expect(!dashboardSource.contains(".toolbarBackground(.visible, for: .windowToolbar)"))
    #expect(!dashboardSource.contains(".backgroundExtensionEffect()"))
    #expect(dashboardSource.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"))
    #expect(!dashboardSource.contains(".ignoresSafeArea(.container, edges: .top)"))
  }

  @Test("Toolbar backdrop uses scroll edge without artificial underlays")
  func toolbarBackdropUsesScrollEdgeWithoutArtificialUnderlays() throws {
    let dashboardSource = try sourceFile(at: "Views/Dashboard/DashboardWindowSupport.swift")
    let sessionWindowSource = try sourceFile(at: "Views/Sessions/SessionWindowView.swift")
    let extensionEffectSource = try sourceFile(
      at: "Views/Sessions/SessionWindowBackgroundExtensionEffect.swift"
    )
    let bannerChromeSource = try sourceFile(at: "Views/Shared/WindowBannerChrome.swift")
    let toolbarGlassSource = try sourceFile(at: "Support/ToolbarGlassStateMonitor.swift")

    #expect(!dashboardSource.contains("WindowToolbarBackdropUnderlay"))
    #expect(!dashboardSource.contains("windowToolbarBackdropUnderlay"))
    #expect(!sessionWindowSource.contains("WindowToolbarBackdropUnderlay"))
    #expect(!sessionWindowSource.contains("windowToolbarBackdropUnderlay"))
    #expect(!extensionEffectSource.contains("respectsBackdropMode: false"))
    #expect(!extensionEffectSource.contains("harnessMonitorToolbarBackgroundExtensionEffect"))
    #expect(extensionEffectSource.contains("content.backgroundExtensionEffect()"))
    #expect(!extensionEffectSource.contains("Ellipse()"))
    #expect(!extensionEffectSource.contains("LinearGradient("))
    #expect(!extensionEffectSource.contains(".blur("))
    #expect(!extensionEffectSource.contains("NSVisualEffectView"))
    #expect(!toolbarGlassSource.contains("NSVisualEffectView"))
    #expect(!toolbarGlassSource.contains("NSTitlebarAccessoryViewController"))
    #expect(!toolbarGlassSource.contains("nativeToolbarScrollEdgeBackdrop"))
    #expect(bannerChromeSource.contains("WindowBannerChromeBackground"))
    #expect(bannerChromeSource.contains("material=softWindowBackground"))
    #expect(!bannerChromeSource.contains(".background(Color(nsColor: .windowBackgroundColor))"))
  }

  @Test("Settings detail surface reuses the shared backdrop extension host")
  func settingsDetailSurfaceReusesSharedBackdropExtensionHost() throws {
    let settingsSource = try sourceFile(at: "Views/Settings/SettingsView.swift")

    #expect(settingsSource.contains(".harnessMonitorBackgroundExtensionEffect()"))
    #expect(!settingsSource.contains(".backgroundExtensionEffect()"))
  }

  @Test("Settings retained panes only lay out the selected section")
  func settingsRetainedPanesOnlyLayOutSelectedSection() throws {
    let settingsSource = try sourceFile(at: "Views/Settings/SettingsView.swift")

    #expect(
      settingsSource.contains(
        "SettingsRetainedSectionLayout(selectedSection: selectedSection)"
      )
    )
    #expect(settingsSource.contains("selectedSubview(in: subviews)?.sizeThatFits(proposal)"))
    #expect(settingsSource.contains("selectedSubview(in: subviews)?.place("))
    #expect(!settingsSource.contains("ZStack {\n      ForEach(SettingsSection.allCases"))
  }

  @Test("Settings marker defaults are only observed when UI-test markers are enabled")
  func settingsMarkerDefaultsAreUITestOnly() throws {
    let settingsSource = try sourceFile(at: "Views/Settings/SettingsView.swift")
    let markersSource = try sourceFile(at: "Views/Settings/SettingsOverlayMarkers.swift")
    let contentRange = try #require(
      markersSource.range(of: "private struct SettingsOverlayMarkerContent")
    )
    let publicMarkerSource = String(markersSource[..<contentRange.lowerBound])

    #expect(
      settingsSource.contains(
        "if HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled {"
      )
    )
    #expect(settingsSource.contains("SettingsOverlayMarkers("))
    #expect(!publicMarkerSource.contains("@AppStorage"))
    #expect(markersSource.contains("private struct SettingsOverlayMarkerContent"))
  }

  @Test("Session split view and search bindings ignore redundant writes")
  func sessionSplitViewAndSearchBindingsIgnoreRedundantWrites() throws {
    let sessionWindowSource = try sourceFile(at: "Views/Sessions/SessionWindowView.swift")
    let widthPersistenceSource = try sourceFile(
      at: "Views/Sessions/SessionWindowView+WidthPersistence.swift"
    )
    let presentationSource = try sourceFile(
      at: "Views/Sessions/SessionWindowView+Presentation.swift")
    let standardLayoutSource = try sourceFile(
      at: "Views/Sessions/SessionWindowStandardLayout.swift")
    let searchHostSource = try sourceFile(at: "Views/Search/AppSearchHost.swift")

    #expect(!presentationSource.contains("let encodedVisibility ="))
    #expect(standardLayoutSource.contains("let encodedVisibility ="))
    #expect(standardLayoutSource.contains("guard columnVisibilityRaw != encodedVisibility else"))
    #expect(sessionWindowSource.contains("if focusModeStorage != $0"))
    #expect(sessionWindowSource.contains("if inspectorVisibleStorage != $0"))
    #expect(sessionWindowSource.contains("if inspectorPreferredStorage != $0"))
    #expect(widthPersistenceSource.contains("guard abs(inspectorWidth - newValue) > 0.5 else"))
    #expect(
      widthPersistenceSource.contains("guard abs(contentColumnWidth - newValue) > 0.5 else")
    )
    #expect(searchHostSource.contains("if query != command.query"))
    #expect(
      searchHostSource.contains("if isSearchFocused != command.isPresented")
    )
    #expect(searchHostSource.contains("guard suggestionSnapshot != snapshot else { return }"))
    #expect(searchHostSource.contains("AppSearchFieldSurface("))
    #expect(searchHostSource.contains(".task(id: shouldKeepSearchIndexActive)"))
    #expect(
      searchHostSource.contains(
        "setPresented(shouldKeepSearchIndexActive)"
      )
    )
    #expect(!searchHostSource.contains("private var mcpRegistryHostEnabled"))
  }

  @Test("Settings geometry callbacks ignore redundant writes")
  func settingsGeometryCallbacksIgnoreRedundantWrites() throws {
    let notificationsSource = try sourceFile(
      at: "Views/Settings/SettingsNotificationsSection.swift"
    )

    #expect(notificationsSource.contains("private func updateContentFieldWidth(_ width: CGFloat)"))
    #expect(notificationsSource.contains("guard width > 0, abs(contentFieldWidth - width) > 0.5"))
    #expect(notificationsSource.contains("updateContentFieldWidth(width)"))
    #expect(!notificationsSource.contains("} action: { width in\n            contentFieldWidth = width"))
  }

  @Test("Settings appearance background changes ignore redundant writes")
  func settingsAppearanceBackgroundChangesIgnoreRedundantWrites() throws {
    let appearanceSource = try sourceFile(at: "Views/Settings/SettingsAppearanceSection.swift")
    let gallerySource = try sourceFile(at: "Views/Settings/SettingsBackgroundGallery.swift")

    #expect(appearanceSource.contains("selectedBackgroundTab != .native"))
    #expect(gallerySource.contains("guard nextOptions != systemBackgroundOptions else { return }"))
    #expect(gallerySource.contains("if selection != background.storageValue"))
    #expect(gallerySource.contains("guard nextStorageValues != recentStorageValues else { return }"))
  }

  @Test("Settings retained live-store roots only observe while active")
  func settingsRetainedLiveStoreRootsOnlyObserveWhileActive() throws {
    let source = try sourceFile(at: "Views/Settings/SettingsView.swift")
    let mcpSource = try sourceFile(at: "Views/Settings/SettingsMCPSection.swift")
    let codexSource = try sourceFile(at: "Views/Settings/SettingsCodexSection.swift")
    let databaseSource = try sourceFile(at: "Views/Settings/SettingsDatabaseSection.swift")
    let foldersSource = try sourceFile(at: "Views/Settings/AuthorizedFoldersSection.swift")
    let generalSource = try sourceFile(at: "Views/Settings/SettingsGeneralSection.swift")
    let loggingSource = try sourceFile(at: "Views/Settings/SettingsLoggingSection.swift")
    let actionButtonsSource = try sourceFile(at: "Views/Settings/SettingsActionButtons.swift")
    let focusModeSource = try sourceFile(at: "Views/Settings/SettingsFocusModeSection.swift")
    let bannersSource = try sourceFile(at: "Views/Settings/SettingsBannersSection.swift")
    let appearanceSource = try sourceFile(at: "Views/Settings/SettingsAppearanceSection.swift")
    let markdownSource = try sourceFile(at: "Views/Settings/SettingsMarkdownSection.swift")
    let notificationsSource = try sourceFile(
      at: "Views/Settings/SettingsNotificationsSection.swift"
    )
    let voiceSource = try sourceFile(at: "Views/Settings/SettingsVoiceSection.swift")
    let mobileSource = try sourceFile(at: "Views/Settings/SettingsMobileSection.swift")
    let taskBoardSource = try sourceFile(at: "Views/Settings/SettingsTaskBoardSection.swift")
    let repositoriesSource = try sourceFile(at: "Views/Settings/SettingsRepositoriesSection.swift")
    let reviewsSource = try sourceFile(at: "Views/Settings/SettingsReviewsSection.swift")
    let secretsSource = try sourceFile(at: "Views/Settings/SettingsSecretsSection.swift")
    let policiesSource = try sourceFile(at: "Views/Settings/SettingsPoliciesSection.swift")
    let supervisorSource = try sourceFile(
      at: "Views/Settings/Supervisor/SettingsSupervisorSection.swift"
    )
    let supervisorRulesSource = try sourceFile(
      at: "Views/Settings/Supervisor/SettingsSupervisorRulesPane.swift"
    )
    let supervisorNotificationsSource = try sourceFile(
      at: "Views/Settings/Supervisor/SettingsSupervisorNotificationsPane.swift"
    )
    let supervisorBackgroundSource = try sourceFile(
      at: "Views/Settings/Supervisor/SettingsSupervisorBackgroundPane.swift"
    )
    let supervisorAuditSource = try sourceFile(
      at: "Views/Settings/Supervisor/SettingsSupervisorAuditPane.swift"
    )

    #expect(source.contains("SettingsGeneralSectionRoot(store: store, isActive: section == selectedSection)"))
    #expect(
      source.contains(
        "SettingsNotificationsSection(\n        notifications: notifications,\n        isActive: section == selectedSection\n      )"
      )
    )
    #expect(source.contains("let activeSnapshot = isActive ? SettingsGeneralSnapshot(store: store) : nil"))
    #expect(source.contains("SettingsConnectionSectionRoot("))
    #expect(source.contains("isActive: section == selectedSection"))
    #expect(source.contains("SettingsFocusModeSection(isActive: section == selectedSection)"))
    #expect(source.contains("SettingsBannersSection(isActive: section == selectedSection)"))
    #expect(source.contains("SettingsAppearanceSection("))
    #expect(source.contains("SettingsMarkdownSection(isActive: section == selectedSection)"))
    #expect(source.contains("SettingsVoiceSection(isActive: section == selectedSection)"))
    #expect(source.contains("SettingsMobileSection("))
    #expect(source.contains("SettingsTaskBoardSection("))
    #expect(source.contains("SettingsRepositoriesSection("))
    #expect(source.contains("SettingsReviewsSection("))
    #expect(source.contains("SettingsSecretsSection("))
    #expect(source.contains("SettingsPoliciesSection(isActive: section == selectedSection)"))
    #expect(source.contains("@State private var cachedSnapshot: SettingsConnectionSnapshot?"))
    #expect(source.contains("let activeSnapshot = isActive ? SettingsConnectionSnapshot(store: store) : nil"))
    #expect(source.contains("let activeInput = isActive ? SettingsDiagnosticsSnapshotInput(store: store) : nil"))
    #expect(source.contains("if isActive {\n        if let snapshot = activeSnapshot ?? cachedSnapshot"))
    #expect(source.contains("let displayedInput = isActive ? activeInput ?? preparedInput : nil"))
    #expect(source.contains("} else {\n        Color.clear\n      }"))
    #expect(source.contains(".task(id: activeInput)"))
    #expect(source.contains("SettingsHostBridgeSection(store: store, isActive: section == selectedSection)"))
    #expect(source.contains("SettingsMCPSection(store: store, isActive: section == selectedSection)"))
    #expect(source.contains("AuthorizedFoldersSection(store: store, isActive: section == selectedSection)"))
    #expect(source.contains("SettingsDatabaseSection(store: store, isActive: section == selectedSection)"))
    #expect(mcpSource.contains("let activeSnapshot = isActive ? SettingsMCPSnapshot(store: store) : nil"))
    #expect(mcpSource.contains(".task(id: activeSnapshot)"))
    #expect(codexSource.contains("let activeSnapshot = isActive ? SettingsHostBridgeSnapshot(store: store) : nil"))
    #expect(codexSource.contains(".task(id: activeSnapshot)"))
    #expect(databaseSource.contains("let activeHealthSnapshot = isActive ? SettingsDatabaseHealthSnapshot(store: store) : nil"))
    #expect(databaseSource.contains(".task(id: activeHealthSnapshot)"))
    #expect(foldersSource.contains("let activeBookmarkStore = isActive ? store.bookmarkStore : nil"))
    #expect(foldersSource.contains(".task(id: isActive)"))
    #expect(generalSource.contains("public struct SettingsGeneralLiveState"))
    #expect(generalSource.contains("SettingsLoggingSection("))
    #expect(generalSource.contains("daemonLogLevel: liveState.daemonLogLevel"))
    #expect(generalSource.contains("daemonOwnership: liveState.daemonOwnership"))
    #expect(!loggingSource.contains("public let store: HarnessMonitorStore"))
    #expect(!actionButtonsSource.contains("let store: HarnessMonitorStore"))
    for retainedSource in [
      focusModeSource,
      bannersSource,
      appearanceSource,
      markdownSource,
      notificationsSource,
      voiceSource,
      mobileSource,
      policiesSource,
      mcpSource,
      codexSource,
      databaseSource,
      foldersSource,
    ] {
      #expect(retainedSource.contains("isActive"))
      #expect(retainedSource.contains("if isActive {\n      activeBody"))
      #expect(retainedSource.contains("Color.clear"))
    }
    #expect(appearanceSource.contains(".task(id: isActive)"))
    #expect(markdownSource.contains(".task(id: isActive)"))
    #expect(voiceSource.contains(".task(id: isActive)"))
    #expect(voiceSource.contains("guard isActive else { return }"))
    #expect(
      notificationsSource.contains(
        "let activeSnapshot = isActive ? SettingsNotificationsSnapshot(notifications: notifications) : nil"
      )
    )
    #expect(notificationsSource.contains(".task(id: isActive)"))
    #expect(notificationsSource.contains(".task(id: activeSnapshot)"))
    #expect(notificationsSource.contains("private struct SettingsNotificationsSnapshot"))
    #expect(notificationsSource.contains("NotificationsStatusSection(snapshot: snapshot)"))
    #expect(!notificationsSource.contains("NotificationsStatusSection(notifications: notifications)"))
    #expect(taskBoardSource.contains("let isActive: Bool"))
    #expect(taskBoardSource.contains("if isActive {\n      activeBody"))
    #expect(taskBoardSource.contains(".task(id: isActive)"))
    #expect(repositoriesSource.contains("let isActive: Bool"))
    #expect(repositoriesSource.contains("if isActive {\n      activeBody"))
    #expect(repositoriesSource.contains(".task(id: isActive)"))
    #expect(reviewsSource.contains("let isActive: Bool"))
    #expect(reviewsSource.contains("if isActive {\n      activeBody"))
    #expect(reviewsSource.contains(".task(id: isActive)"))
    #expect(secretsSource.contains("let isActive: Bool"))
    #expect(secretsSource.contains("if isActive {\n      activeBody"))
    #expect(secretsSource.contains(".task(id: isActive)"))
    #expect(source.contains("SettingsSupervisorSection("))
    #expect(source.contains("isActive: section == selectedSection,\n        selectedPane: $selectedSupervisorPane"))
    #expect(supervisorSource.contains("let isPaneActive = isActive && pane == selectedPane"))
    #expect(supervisorSource.contains("SettingsSupervisorRulesPane(store: store, isActive: isPaneActive)"))
    #expect(supervisorSource.contains("SettingsSupervisorAuditPane(store: store, isActive: isPaneActive)"))
    #expect(supervisorRulesSource.contains("guard isActive else { return }\n      await reloadRows()"))
    #expect(supervisorNotificationsSource.contains("guard isActive else { return }\n      await notifications.refreshStatus()"))
    #expect(supervisorBackgroundSource.contains("if isActive {"))
    #expect(supervisorAuditSource.contains("if isActive {"))
  }

  @Test("Decision rows keep deadline churn scoped to the deadline chip")
  func decisionRowsKeepTimelineTicksOutOfTheRowBody() throws {
    let rowSource = try sourceFile(at: "Views/Decisions/DecisionRow.swift")

    #expect(!rowSource.contains("TimelineView("))
    #expect(rowSource.contains("let showsDeadline = acpPayload?.expiresAtDate != nil"))
    #expect(rowSource.contains("referenceDate: nil"))
    #expect(!rowSource.contains("deadlineStatus("))
  }

  @Test("Decision live tick keeps duplicate quarantined rules off self identity")
  func decisionLiveTickKeepsDuplicateRuleIDsOffSelfIdentity() throws {
    let source = try sourceFile(at: "Views/Decisions/DecisionsLiveTickView.swift")

    #expect(source.contains("private var indexedRuleIDs"))
    #expect(source.contains("ForEach(indexedRuleIDs, id: \\.offset)"))
    #expect(!source.contains("ForEach(ruleIDs, id: \\.self)"))
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
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
