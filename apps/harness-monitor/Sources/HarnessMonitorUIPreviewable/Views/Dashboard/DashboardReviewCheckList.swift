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
      let presentation = DashboardReviewCheckListPresentation(
        checks: checks,
        visibleNonProblemCheckLimit: visibleNonProblemCheckLimit
      )
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        if presentation.hasProblemChecks {
          checkSummary(presentation)
          checkDiagnosticsControls(presentation)
          checkGroupsView(groups: presentation.problemCheckGroups, suppressPassingStatus: false)
          nonProblemChecksDisclosure(presentation)
        } else {
          nonProblemChecksSummary(presentation)
          checkDiagnosticsControls(presentation)
          if showsPassingChecks {
            checkGroupsView(
              groups: presentation.visibleNonProblemCheckGroups,
              suppressPassingStatus: presentation.allPassing
            )
            showMoreNonProblemChecksButton(presentation)
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

  @ViewBuilder
  private func checkSummary(
    _ presentation: DashboardReviewCheckListPresentation
  ) -> some View {
    if presentation.allPassing {
      DashboardReviewStatusPill(
        label: "All checks passed",
        tint: HarnessMonitorTheme.success,
        systemImage: "checkmark.circle.fill"
      )
    } else if presentation.hasProblemChecks {
      DashboardReviewStatusPill(
        label: "\(presentation.problemChecks.count) failing",
        tint: HarnessMonitorTheme.danger,
        systemImage: "xmark.octagon.fill"
      )
    }
  }

  private func checkDiagnosticsControls(
    _ presentation: DashboardReviewCheckListPresentation
  ) -> some View {
    HarnessMonitorWrapLayout(
      spacing: HarnessMonitorTheme.spacingSM,
      lineSpacing: HarnessMonitorTheme.spacingSM
    ) {
      if presentation.hasProblemChecks {
        Toggle("Failed only", isOn: $showsProblemChecksOnly)
          .toggleStyle(.button)
          .controlSize(.small)
      }
      let onlyFailing = presentation.hasProblemChecks
      let copyURLs = presentation.targetCheckURLs(onlyFailing: onlyFailing)
      Button {
        copyCheckURLs(onlyFailing: onlyFailing, presentation: presentation)
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

  private func nonProblemChecksSummary(
    _ presentation: DashboardReviewCheckListPresentation
  ) -> some View {
    DashboardReviewPassingChecksSummary(
      label: presentation.allPassing ? "All checks passed" : "No failing checks",
      systemImage: presentation.allPassing ? "checkmark.circle.fill" : "circle",
      checkCount: presentation.nonProblemChecks.count,
      groupCount: presentation.nonProblemCheckGroups.count,
      expandedTitle: presentation.allPassing ? "Hide passing checks" : "Hide checks",
      collapsedTitle: presentation.allPassing ? "Show passing checks" : "Show checks",
      isExpanded: $showsPassingChecks
    )
  }

  @ViewBuilder
  private func nonProblemChecksDisclosure(
    _ presentation: DashboardReviewCheckListPresentation
  ) -> some View {
    if !showsProblemChecksOnly && !presentation.nonProblemChecks.isEmpty {
      nonProblemChecksSummary(presentation)
      if showsPassingChecks {
        checkGroupsView(
          groups: presentation.visibleNonProblemCheckGroups,
          suppressPassingStatus: false
        )
        showMoreNonProblemChecksButton(presentation)
      }
    }
  }

  @ViewBuilder
  private func showMoreNonProblemChecksButton(
    _ presentation: DashboardReviewCheckListPresentation
  ) -> some View {
    if presentation.hiddenNonProblemCheckCount > 0 {
      let nextBatchSize = min(Self.checkBatchSize, presentation.hiddenNonProblemCheckCount)
      Button("Show \(nextBatchSize) more checks") {
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

  private func copyCheckURLs(
    onlyFailing: Bool,
    presentation: DashboardReviewCheckListPresentation
  ) {
    let urls = presentation.targetCheckURLs(onlyFailing: onlyFailing).map(\.absoluteString)
    guard !urls.isEmpty else { return }
    HarnessMonitorClipboard.copy(urls.joined(separator: "\n"))
  }

  private func resetCheckExpansion() {
    visibleNonProblemCheckLimit = Self.checkBatchSize
    showsPassingChecks = preferences.snapshot.checksShowPassingByDefault
    expandedPassingGroupIDs.removeAll()
  }
}

private struct DashboardReviewCheckListPresentation {
  let problemChecks: [ReviewCheck]
  let nonProblemChecks: [ReviewCheck]
  let problemCheckURLs: [URL]
  let allCheckURLs: [URL]
  let problemCheckGroups: [DashboardReviewCheckGroup]
  let nonProblemCheckGroups: [DashboardReviewCheckGroup]
  let visibleNonProblemCheckGroups: [DashboardReviewCheckGroup]
  let hiddenNonProblemCheckCount: Int
  let allPassing: Bool

  init(
    checks: [ReviewCheck],
    visibleNonProblemCheckLimit: Int
  ) {
    var problemChecks: [ReviewCheck] = []
    var nonProblemChecks: [ReviewCheck] = []
    var problemCheckURLs: [URL] = []
    var allCheckURLs: [URL] = []
    var allPassing = !checks.isEmpty

    problemChecks.reserveCapacity(checks.count)
    nonProblemChecks.reserveCapacity(checks.count)
    problemCheckURLs.reserveCapacity(checks.count)
    allCheckURLs.reserveCapacity(checks.count)

    for check in checks {
      let requiresAttention = check.requiresAttention
      if !check.isPassing {
        allPassing = false
      }
      if let detailsWebURL = check.detailsWebURL {
        allCheckURLs.append(detailsWebURL)
        if requiresAttention {
          problemCheckURLs.append(detailsWebURL)
        }
      }
      if requiresAttention {
        problemChecks.append(check)
      } else {
        nonProblemChecks.append(check)
      }
    }

    self.problemChecks = problemChecks
    self.nonProblemChecks = nonProblemChecks
    self.problemCheckURLs = problemCheckURLs
    self.allCheckURLs = allCheckURLs
    problemCheckGroups = dashboardReviewCheckGroups(for: problemChecks)
    nonProblemCheckGroups = dashboardReviewCheckGroups(for: nonProblemChecks)
    visibleNonProblemCheckGroups = dashboardReviewCheckGroups(
      for: nonProblemChecks.prefix(visibleNonProblemCheckLimit)
    )
    hiddenNonProblemCheckCount = max(nonProblemChecks.count - visibleNonProblemCheckLimit, 0)
    self.allPassing = allPassing
  }

  var hasProblemChecks: Bool {
    !problemChecks.isEmpty
  }

  func targetCheckURLs(onlyFailing: Bool) -> [URL] {
    onlyFailing ? problemCheckURLs : allCheckURLs
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
