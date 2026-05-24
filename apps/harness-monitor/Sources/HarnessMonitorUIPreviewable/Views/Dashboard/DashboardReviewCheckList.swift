import HarnessMonitorKit
import SwiftUI

struct DashboardReviewCheckList: View {
  private static let checkBatchSize = 20

  let checks: [ReviewCheck]
  @Binding var showsProblemChecksOnly: Bool
  let onRerunCheck: (ReviewCheck) -> Void

  @Environment(\.reviewsPreferences)
  private var preferences

  @State private var expandedPassingGroupIDs = Set<String>()
  @State private var showsPassingChecks: Bool = false
  @State private var visibleNonProblemCheckLimit = Self.checkBatchSize

  var body: some View {
    if checks.isEmpty {
      Text("No checks reported")
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    } else {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        if hasProblemChecks {
          checkSummary
          checkDiagnosticsControls
          checkGroupsView(groups: problemCheckGroups, suppressPassingStatus: false)
          nonProblemChecksDisclosure
        } else {
          nonProblemChecksSummary
          checkDiagnosticsControls
          if showsPassingChecks {
            checkGroupsView(
              groups: visibleNonProblemCheckGroups,
              suppressPassingStatus: allPassing
            )
            showMoreNonProblemChecksButton
          }
        }
      }
      .frame(maxWidth: DashboardReviewsVisualMetrics.sectionMaxWidth, alignment: .leading)
      .onAppear {
        showsPassingChecks = preferences.snapshot.checksShowPassingByDefault
      }
      .onChange(of: showsPassingChecks) { _, newValue in
        preferences.update { $0.checksShowPassingByDefault = newValue }
      }
      .onChange(of: checks) { _, _ in
        resetCheckExpansion()
      }
    }
  }

  @ViewBuilder private var checkSummary: some View {
    if allPassing {
      DashboardReviewStatusPill(
        label: "All checks passed",
        tint: HarnessMonitorTheme.success,
        systemImage: "checkmark.circle.fill"
      )
    } else if hasProblemChecks {
      DashboardReviewStatusPill(
        label: "\(problemChecks.count) failing",
        tint: HarnessMonitorTheme.danger,
        systemImage: "xmark.octagon.fill"
      )
    }
  }

  private var checkDiagnosticsControls: some View {
    HarnessMonitorWrapLayout(
      spacing: HarnessMonitorTheme.spacingSM,
      lineSpacing: HarnessMonitorTheme.spacingSM
    ) {
      if hasProblemChecks {
        Toggle("Failed only", isOn: $showsProblemChecksOnly)
          .toggleStyle(.button)
          .controlSize(.small)
      }
      let onlyFailing = hasProblemChecks
      let copyURLs = targetCheckURLs(onlyFailing: onlyFailing)
      Button {
        copyCheckURLs(onlyFailing: onlyFailing)
      } label: {
        Label(
          onlyFailing ? "Copy failing check URLs" : "Copy check URLs",
          systemImage: "doc.on.doc"
        )
      }
      .disabled(copyURLs.isEmpty)
      .controlSize(.small)
      .help(
        copyURLs.isEmpty
          ? "No check URLs are available"
          : (onlyFailing ? "Copy failing check URLs" : "Copy URLs for every check")
      )
    }
  }

  private var allPassing: Bool {
    !checks.isEmpty && checks.allSatisfy(\.isPassing)
  }

  private var hasProblemChecks: Bool {
    !problemChecks.isEmpty
  }

  private var problemChecks: [ReviewCheck] {
    checks.filter(\.requiresAttention)
  }

  private var nonProblemChecks: [ReviewCheck] {
    checks.filter { !$0.requiresAttention }
  }

  private var visibleNonProblemChecks: [ReviewCheck] {
    Array(nonProblemChecks.prefix(visibleNonProblemCheckLimit))
  }

  private var problemCheckGroups: [DashboardReviewCheckGroup] {
    dashboardReviewCheckGroups(for: problemChecks)
  }

  private var nonProblemCheckGroups: [DashboardReviewCheckGroup] {
    dashboardReviewCheckGroups(for: nonProblemChecks)
  }

  private var visibleNonProblemCheckGroups: [DashboardReviewCheckGroup] {
    dashboardReviewCheckGroups(for: visibleNonProblemChecks)
  }

  private var hiddenNonProblemCheckCount: Int {
    max(nonProblemChecks.count - visibleNonProblemCheckLimit, 0)
  }

  private var nonProblemChecksSummary: some View {
    DashboardReviewPassingChecksSummary(
      label: allPassing ? "All checks passed" : "No failing checks",
      systemImage: allPassing ? "checkmark.circle.fill" : "circle",
      checkCount: nonProblemChecks.count,
      groupCount: nonProblemCheckGroups.count,
      expandedTitle: allPassing ? "Hide passing checks" : "Hide checks",
      collapsedTitle: allPassing ? "Show passing checks" : "Show checks",
      isExpanded: $showsPassingChecks
    )
  }

  @ViewBuilder private var nonProblemChecksDisclosure: some View {
    if !showsProblemChecksOnly && !nonProblemChecks.isEmpty {
      nonProblemChecksSummary
      if showsPassingChecks {
        checkGroupsView(
          groups: visibleNonProblemCheckGroups,
          suppressPassingStatus: false
        )
        showMoreNonProblemChecksButton
      }
    }
  }

  @ViewBuilder private var showMoreNonProblemChecksButton: some View {
    if hiddenNonProblemCheckCount > 0 {
      Button("Show \(min(Self.checkBatchSize, hiddenNonProblemCheckCount)) more checks") {
        visibleNonProblemCheckLimit += Self.checkBatchSize
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
      .help("Render the next batch of checks")
    }
  }

  private func checkGroupsView(
    groups: [DashboardReviewCheckGroup],
    suppressPassingStatus: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      ForEach(groups) { group in
        DashboardReviewCheckGroupView(
          group: group,
          suppressPassingStatus: suppressPassingStatus,
          showsHeader: groups.count > 1,
          hasProblemChecks: false,
          hasMultipleGroups: groups.count > 1,
          expandedPassingGroupIDs: $expandedPassingGroupIDs,
          onRerunCheck: onRerunCheck
        )
      }
    }
  }

  private func targetCheckURLs(onlyFailing: Bool) -> [URL] {
    let pool = onlyFailing ? problemChecks : checks
    return pool.compactMap(\.detailsWebURL)
  }

  private func copyCheckURLs(onlyFailing: Bool) {
    let urls = targetCheckURLs(onlyFailing: onlyFailing).map(\.absoluteString)
    guard !urls.isEmpty else { return }
    HarnessMonitorClipboard.copy(urls.joined(separator: "\n"))
  }

  private func resetCheckExpansion() {
    visibleNonProblemCheckLimit = Self.checkBatchSize
    showsPassingChecks = preferences.snapshot.checksShowPassingByDefault
    expandedPassingGroupIDs.removeAll()
  }
}

private struct DashboardReviewPassingChecksSummary: View {
  let label: String
  let systemImage: String
  let checkCount: Int
  let groupCount: Int
  let expandedTitle: String
  let collapsedTitle: String
  @Binding var isExpanded: Bool

  init(
    label: String = "All checks passed",
    systemImage: String = "checkmark.circle.fill",
    checkCount: Int,
    groupCount: Int,
    expandedTitle: String = "Hide passing checks",
    collapsedTitle: String = "Show passing checks",
    isExpanded: Binding<Bool>
  ) {
    self.label = label
    self.systemImage = systemImage
    self.checkCount = checkCount
    self.groupCount = groupCount
    self.expandedTitle = expandedTitle
    self.collapsedTitle = collapsedTitle
    _isExpanded = isExpanded
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
      DashboardReviewStatusPill(
        label: label,
        tint: HarnessMonitorTheme.success,
        systemImage: systemImage
      )
      Text(summary)
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      Button(isExpanded ? expandedTitle : collapsedTitle) {
        isExpanded.toggle()
      }
      .controlSize(.small)
      .help(isExpanded ? "Hide check details" : "Show check details")
    }
  }

  private var summary: String {
    "\(checkCount) \(checkCount == 1 ? "check" : "checks") across \(groupCount) "
      + "\(groupCount == 1 ? "group" : "groups")."
  }
}

private struct DashboardReviewCheckGroupView: View {
  let group: DashboardReviewCheckGroup
  let suppressPassingStatus: Bool
  let showsHeader: Bool
  let hasProblemChecks: Bool
  let hasMultipleGroups: Bool
  @Binding var expandedPassingGroupIDs: Set<String>
  let onRerunCheck: (ReviewCheck) -> Void

  @State private var isHeaderHovered = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if showsHeader {
        groupHeader
      }
      if !isCollapsed {
        checkRows
      }
    }
  }

  @ViewBuilder private var groupHeader: some View {
    if canCollapse {
      Button {
        toggleExpanded()
      } label: {
        HStack(spacing: HarnessMonitorTheme.spacingSM) {
          Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
            .font(.caption.weight(.semibold))
            .frame(width: 12, alignment: .center)
          groupTitle
          DashboardReviewStatusPill(
            label: "Passed",
            tint: HarnessMonitorTheme.success,
            isQuiet: true
          )
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(HarnessMonitorTheme.ink.opacity(isHeaderHovered ? 0.06 : 0))
        )
      }
      .buttonStyle(.borderless)
      .padding(.bottom, HarnessMonitorTheme.spacingXS)
      .animation(.easeOut(duration: 0.12), value: isHeaderHovered)
      .onHover { isHeaderHovered = $0 }
      .accessibilityLabel("\(group.title), \(group.checkCountLabel), passed")
    } else {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        groupTitle
      }
      .padding(.bottom, HarnessMonitorTheme.spacingXS)
    }
  }

  private var groupTitle: some View {
    Group {
      Text(group.title)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.ink)
      Text(group.checkCountLabel)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
  }

  private var checkRows: some View {
    ForEach(group.checks, id: \.id) { check in
      DashboardReviewCheckRow(
        check: check,
        suppressPassingStatus: suppressPassingStatus,
        onRerunCheck: onRerunCheck
      )
      .overlay(alignment: .bottom) {
        if check.id != group.checks.last?.id {
          Divider().opacity(0.45)
        }
      }
    }
  }

  private var canCollapse: Bool {
    group.checks.allSatisfy(\.isPassing) && hasMultipleGroups
  }

  private var isCollapsed: Bool {
    canCollapse && !expandedPassingGroupIDs.contains(group.id)
  }

  private func toggleExpanded() {
    if expandedPassingGroupIDs.contains(group.id) {
      expandedPassingGroupIDs.remove(group.id)
    } else {
      expandedPassingGroupIDs.insert(group.id)
    }
  }
}
