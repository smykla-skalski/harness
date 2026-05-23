import HarnessMonitorKit
import SwiftUI

struct DashboardReviewCheckList: View {
  let checks: [ReviewCheck]
  @Binding var showsProblemChecksOnly: Bool
  let onRerunCheck: (ReviewCheck) -> Void

  @State private var expandedPassingGroupIDs = Set<String>()
  @State private var showsPassingChecks = false

  var body: some View {
    if checks.isEmpty {
      Text("No checks reported")
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    } else {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        if allPassing {
          DashboardReviewPassingChecksSummary(
            checkCount: checks.count,
            groupCount: checkGroups.count,
            isExpanded: $showsPassingChecks
          )
          if showsPassingChecks {
            checkGroupsView
          }
        } else {
          checkSummary
          if hasProblemChecks {
            checkDiagnosticsControls
          }
          checkGroupsView
        }
      }
      .frame(maxWidth: DashboardReviewsVisualMetrics.checksMaxWidth, alignment: .leading)
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
      Toggle("Failed only", isOn: $showsProblemChecksOnly)
        .toggleStyle(.button)
        .controlSize(.small)
      Button {
        copyProblemCheckURLs()
      } label: {
        Label("Copy failing check URLs", systemImage: "doc.on.doc")
      }
      .disabled(problemCheckURLs.isEmpty)
      .controlSize(.small)
      .help(
        problemCheckURLs.isEmpty
          ? "No failing check URLs are available"
          : "Copy failing check URLs"
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

  private var visibleChecks: [ReviewCheck] {
    showsProblemChecksOnly && hasProblemChecks ? problemChecks : checks
  }

  private var checkGroups: [DashboardReviewCheckGroup] {
    dashboardReviewCheckGroups(for: visibleChecks)
  }

  private var problemCheckURLs: [URL] {
    problemChecks.compactMap(\.detailsWebURL)
  }

  private var checkGroupsView: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      ForEach(checkGroups) { group in
        DashboardReviewCheckGroupView(
          group: group,
          suppressPassingStatus: allPassing,
          showsHeader: checkGroups.count > 1,
          hasProblemChecks: hasProblemChecks,
          expandedPassingGroupIDs: $expandedPassingGroupIDs,
          onRerunCheck: onRerunCheck
        )
      }
    }
  }

  private func copyProblemCheckURLs() {
    let urls = problemCheckURLs.map(\.absoluteString)
    guard !urls.isEmpty else { return }
    HarnessMonitorClipboard.copy(urls.joined(separator: "\n"))
  }
}

private struct DashboardReviewPassingChecksSummary: View {
  let checkCount: Int
  let groupCount: Int
  @Binding var isExpanded: Bool

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
      DashboardReviewStatusPill(
        label: "All checks passed",
        tint: HarnessMonitorTheme.success,
        systemImage: "checkmark.circle.fill"
      )
      Text(summary)
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      Button(isExpanded ? "Hide passing checks" : "Show passing checks") {
        isExpanded.toggle()
      }
      .controlSize(.small)
      .help(isExpanded ? "Hide passing check details" : "Show passing check details")
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
  @Binding var expandedPassingGroupIDs: Set<String>
  let onRerunCheck: (ReviewCheck) -> Void

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
        }
      }
      .buttonStyle(.borderless)
      .padding(.bottom, HarnessMonitorTheme.spacingXS)
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
    ForEach(Array(group.checks.enumerated()), id: \.element.id) { index, check in
      DashboardReviewCheckRow(
        check: check,
        suppressPassingStatus: suppressPassingStatus,
        onRerunCheck: onRerunCheck
      )
      .overlay(alignment: .bottom) {
        if index < group.checks.count - 1 {
          Divider().opacity(0.45)
        }
      }
    }
  }

  private var canCollapse: Bool {
    hasProblemChecks && group.checks.allSatisfy(\.isPassing)
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
