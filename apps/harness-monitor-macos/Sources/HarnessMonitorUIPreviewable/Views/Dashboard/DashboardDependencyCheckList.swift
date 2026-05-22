import HarnessMonitorKit
import SwiftUI

struct DashboardDependencyCheckList: View {
  let checks: [DependencyUpdateCheck]
  let onRerunCheck: (DependencyUpdateCheck) -> Void

  @State private var showsProblemChecksOnly = false
  @State private var expandedPassingGroupIDs = Set<String>()

  var body: some View {
    if checks.isEmpty {
      Text("No checks reported")
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    } else {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        checkSummary
        if hasProblemChecks {
          checkDiagnosticsControls
        }
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          ForEach(checkGroups) { group in
            DashboardDependencyCheckGroupView(
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
      .frame(maxWidth: DashboardDependenciesVisualMetrics.checksMaxWidth, alignment: .leading)
    }
  }

  @ViewBuilder private var checkSummary: some View {
    if allPassing {
      DashboardDependencyStatusPill(
        label: "All checks passed",
        tint: HarnessMonitorTheme.success,
        systemImage: "checkmark.circle.fill"
      )
    } else if hasProblemChecks {
      DashboardDependencyStatusPill(
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
      .help(problemCheckURLs.isEmpty ? "No failing check URLs are available" : "Copy failing check URLs")
    }
  }

  private var allPassing: Bool {
    !checks.isEmpty && checks.allSatisfy(\.isPassing)
  }

  private var hasProblemChecks: Bool {
    !problemChecks.isEmpty
  }

  private var problemChecks: [DependencyUpdateCheck] {
    checks.filter(\.requiresAttention)
  }

  private var visibleChecks: [DependencyUpdateCheck] {
    showsProblemChecksOnly && hasProblemChecks ? problemChecks : checks
  }

  private var checkGroups: [DashboardDependencyCheckGroup] {
    dashboardDependencyCheckGroups(for: visibleChecks)
  }

  private var problemCheckURLs: [URL] {
    problemChecks.compactMap(\.detailsWebURL)
  }

  private func copyProblemCheckURLs() {
    let urls = problemCheckURLs.map(\.absoluteString)
    guard !urls.isEmpty else { return }
    HarnessMonitorClipboard.copy(urls.joined(separator: "\n"))
  }
}

private struct DashboardDependencyCheckGroupView: View {
  let group: DashboardDependencyCheckGroup
  let suppressPassingStatus: Bool
  let showsHeader: Bool
  let hasProblemChecks: Bool
  @Binding var expandedPassingGroupIDs: Set<String>
  let onRerunCheck: (DependencyUpdateCheck) -> Void

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
          DashboardDependencyStatusPill(
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
      DashboardDependencyCheckRow(
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
