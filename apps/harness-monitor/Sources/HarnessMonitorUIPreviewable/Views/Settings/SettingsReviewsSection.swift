import HarnessMonitorKit
import SwiftUI

enum ReviewsPaneKey: String, CaseIterable, Hashable, Identifiable, Sendable {
  case general
  case display
  case files
  case timeline

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: "General"
    case .display: "Display"
    case .files: "Files"
    case .timeline: "Timeline"
    }
  }

  static let toolbarVisibleCases: [Self] = [.general, .display, .files, .timeline]
}

struct SettingsReviewsSection: View {
  let isActive: Bool
  @Binding var navigationRequest: SettingsNavigationRequest?
  @Binding var selectedPane: ReviewsPaneKey
  @AppStorage(DashboardReviewsPreferences.storageKey)
  private var storedPreferences = ""
  @State private var draft = DashboardReviewsPreferences()
  @State private var hasLoadedDraft = false
  @Environment(\.settingsScrollRestorationSection)
  private var settingsSection
  @State private var visitedPanes: Set<ReviewsPaneKey> = []

  init(
    isActive: Bool = true,
    navigationRequest: Binding<SettingsNavigationRequest?> = .constant(nil),
    selectedPane: Binding<ReviewsPaneKey>
  ) {
    self.isActive = isActive
    _navigationRequest = navigationRequest
    _selectedPane = selectedPane
  }

  var body: some View {
    if isActive {
      activeBody
    } else {
      Color.clear
    }
  }

  private var activeBody: some View {
    ReviewsRetainedPaneLayout(selectedPane: selectedPane) {
      ForEach(ReviewsPaneKey.toolbarVisibleCases) { pane in
        if visitedPanes.contains(pane) {
          let isSelected = isActive && pane == selectedPane
          ReviewsRetainedPaneHost(
            pane: pane,
            isSelected: isSelected,
            settingsSection: settingsSection
          ) {
            paneContent(pane)
          }
          .equatable()
          .layoutValue(key: ReviewsRetainedPaneKey.self, value: pane)
        }
      }
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsReviewsRoot)
    .task(id: isActive) {
      guard isActive else { return }
      loadDraftIfNeeded()
    }
    .onChange(of: selectedPane, initial: true) { _, newValue in
      visit(newValue)
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      actionsComposer
    }
  }

  private func visit(_ pane: ReviewsPaneKey) {
    guard !visitedPanes.contains(pane) else {
      return
    }
    visitedPanes.insert(pane)
  }

  @ViewBuilder
  private func paneContent(_ pane: ReviewsPaneKey) -> some View {
    let isPaneActive = isActive && pane == selectedPane
    switch pane {
    case .general:
      SettingsReviewsGeneralPane(
        draft: $draft,
        navigationRequest: $navigationRequest,
        isActive: isPaneActive
      )
    case .display:
      SettingsReviewsDisplayPane(
        draft: $draft,
        isActive: isPaneActive
      )
    case .files:
      SettingsReviewsFilesPane(
        draft: $draft,
        isActive: isPaneActive
      )
    case .timeline:
      SettingsReviewsTimelinePane(
        draft: $draft,
        isActive: isPaneActive
      )
    }
  }

  private var actionsComposer: some View {
    VStack(spacing: 0) {
      Divider()
      HStack {
        Spacer(minLength: 0)
        HarnessMonitorGlassControlGroup(spacing: HarnessMonitorTheme.itemSpacing) {
          HarnessMonitorWrapLayout(
            spacing: HarnessMonitorTheme.itemSpacing,
            lineSpacing: HarnessMonitorTheme.itemSpacing,
            rowAlignment: .trailing
          ) {
            HarnessMonitorActionButton(
              title: "Reload",
              tint: .secondary,
              variant: .bordered,
              accessibilityIdentifier: HarnessMonitorAccessibility.settingsReviewsReloadButton
            ) {
              reloadDraft()
            }
            HarnessMonitorActionButton(
              title: "Save",
              tint: nil,
              variant: .prominent,
              accessibilityIdentifier: HarnessMonitorAccessibility.settingsReviewsSaveButton
            ) {
              saveDraft()
            }
          }
        }
      }
      .padding(.horizontal, HarnessMonitorTheme.spacingXL)
      .padding(.vertical, HarnessMonitorTheme.spacingSM)
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
    .background(.background)
  }

  private func loadDraftIfNeeded() {
    guard !hasLoadedDraft else { return }
    reloadDraft()
  }

  private func reloadDraft() {
    draft = DashboardReviewsPreferences.decode(from: storedPreferences).normalized()
    hasLoadedDraft = true
  }

  private func saveDraft() {
    let normalized = draft.normalized()
    draft = normalized
    storedPreferences = normalized.encodedString
  }
}

private struct ReviewsRetainedPaneHost<Content: View>: View, Equatable {
  let pane: ReviewsPaneKey
  let isSelected: Bool
  let settingsSection: SettingsSection?
  let content: Content

  init(
    pane: ReviewsPaneKey,
    isSelected: Bool,
    settingsSection: SettingsSection?,
    @ViewBuilder content: () -> Content
  ) {
    self.pane = pane
    self.isSelected = isSelected
    self.settingsSection = settingsSection
    self.content = content()
  }

  var body: some View {
    content
      .environment(\.settingsScrollRestorationSection, isSelected ? settingsSection : nil)
      .harnessMCPElementTrackingEnabled(isSelected)
      .opacity(isSelected ? 1 : 0)
      .allowsHitTesting(isSelected)
      .accessibilityHidden(!isSelected)
  }

  nonisolated static func == (
    lhs: ReviewsRetainedPaneHost<Content>,
    rhs: ReviewsRetainedPaneHost<Content>
  ) -> Bool {
    lhs.pane == rhs.pane
      && lhs.isSelected == rhs.isSelected
      && lhs.settingsSection == rhs.settingsSection
  }
}

private struct ReviewsRetainedPaneLayout: Layout {
  let selectedPane: ReviewsPaneKey

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    selectedSubview(in: subviews)?.sizeThatFits(proposal) ?? .zero
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    selectedSubview(in: subviews)?.place(
      at: bounds.origin,
      proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
    )
  }

  func explicitAlignment(
    of _: HorizontalAlignment,
    in _: CGRect,
    proposal _: ProposedViewSize,
    subviews _: Subviews,
    cache _: inout ()
  ) -> CGFloat? {
    nil
  }

  func explicitAlignment(
    of _: VerticalAlignment,
    in _: CGRect,
    proposal _: ProposedViewSize,
    subviews _: Subviews,
    cache _: inout ()
  ) -> CGFloat? {
    nil
  }

  private func selectedSubview(in subviews: Subviews) -> LayoutSubview? {
    subviews.first { subview in
      subview[ReviewsRetainedPaneKey.self] == selectedPane
    } ?? subviews.first
  }
}

private struct ReviewsRetainedPaneKey: LayoutValueKey {
  static let defaultValue: ReviewsPaneKey? = nil
}

private enum ReviewsPaneToolbarMetrics {
  static let width: CGFloat = 340
}

struct ReviewsSettingsToolbarPicker: View {
  @Binding var selection: ReviewsPaneKey

  var body: some View {
    Picker("Pane", selection: $selection) {
      ForEach(ReviewsPaneKey.toolbarVisibleCases) { pane in
        Text(pane.title)
          .tag(pane)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.segmentedOption(
              HarnessMonitorAccessibility.settingsReviewsPane("pane-picker"),
              option: pane.title
            )
          )
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .controlSize(.large)
    .frame(width: ReviewsPaneToolbarMetrics.width)
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.settingsReviewsPane("pane-picker")
    )
  }
}
