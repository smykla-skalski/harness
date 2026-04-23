import HarnessMonitorKit
import SwiftUI

extension DecisionSeverity {
  /// Severity ordering used by the Decisions sidebar: higher value renders first.
  public var sortKey: Int {
    switch self {
    case .critical: 4
    case .needsUser: 3
    case .warn: 2
    case .info: 1
    }
  }

  /// Short chip label for the sidebar filter row.
  public var chipLabel: String {
    switch self {
    case .critical: "Critical"
    case .needsUser: "Needs user"
    case .warn: "Warn"
    case .info: "Info"
    }
  }

  var chipColor: Color {
    switch self {
    case .critical: HarnessMonitorTheme.danger
    case .needsUser: HarnessMonitorTheme.warmAccent
    case .warn: HarnessMonitorTheme.caution
    case .info: HarnessMonitorTheme.accent
    }
  }

  static var sidebarOrdering: [DecisionSeverity] {
    allCases.sorted { $0.sortKey > $1.sortKey }
  }
}

/// Pure grouping / sorting / filtering helpers for `DecisionsSidebar`. Split out so the
/// behaviour can be covered by unit tests without spinning up a view hierarchy.
public enum DecisionsSidebarViewModel {
  public struct SessionGroup: Equatable {
    public let sessionID: String?
    public let decisions: [Decision]

    public init(sessionID: String?, decisions: [Decision]) {
      self.sessionID = sessionID
      self.decisions = decisions
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.sessionID == rhs.sessionID && lhs.decisions.map(\.id) == rhs.decisions.map(\.id)
    }
  }

  /// Groups decisions by `sessionID`, filters by case-insensitive `query` substring over
  /// summary and by minimum severity, then sorts each group's rows by severity descending
  /// (stable by `createdAt` then `id`). Sessions sort by earliest `createdAt` ascending so the
  /// long-lived ones stay at the top; ties fall back to `sessionID` alphabetically. The
  /// session-less bucket (where `sessionID == nil`) sorts last.
  public static func grouped(
    decisions: [Decision],
    query: String,
    minSeverity: DecisionSeverity
  ) -> [SessionGroup] {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let filtered = decisions.filter { decision in
      guard let severity = DecisionSeverity(rawValue: decision.severityRaw) else { return false }
      guard severity.sortKey >= minSeverity.sortKey else { return false }
      if trimmedQuery.isEmpty { return true }
      return decision.summary.range(of: trimmedQuery, options: .caseInsensitive) != nil
    }

    let buckets = Dictionary(grouping: filtered) { $0.sessionID }
    return buckets.map { key, rows in
      SessionGroup(sessionID: key, decisions: sortedBySeverity(rows))
    }.sorted(by: sessionGroupOrdering)
  }

  private static func sortedBySeverity(_ decisions: [Decision]) -> [Decision] {
    decisions.sorted { lhs, rhs in
      let leftKey = DecisionSeverity(rawValue: lhs.severityRaw)?.sortKey ?? 0
      let rightKey = DecisionSeverity(rawValue: rhs.severityRaw)?.sortKey ?? 0
      if leftKey != rightKey { return leftKey > rightKey }
      if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
      return lhs.id < rhs.id
    }
  }

  private static func sessionGroupOrdering(_ lhs: SessionGroup, _ rhs: SessionGroup) -> Bool {
    switch (lhs.sessionID, rhs.sessionID) {
    case (nil, nil):
      return false
    case (nil, _):
      return false
    case (_, nil):
      return true
    case (let left?, let right?):
      let leftEarliest = lhs.decisions.map(\.createdAt).min() ?? Date.distantFuture
      let rightEarliest = rhs.decisions.map(\.createdAt).min() ?? Date.distantFuture
      if leftEarliest != rightEarliest {
        return leftEarliest < rightEarliest
      }
      return left < right
    }
  }
}

/// Decisions window sidebar. Search + severity chip filters at the top, ScrollView + LazyVStack
/// body (never List per memory `feedback_sidebar_no_list.md`), one section per session, severity
/// chip next to each row. Selection writes back through a `Binding<String?>` so the detail
/// column can render the chosen decision by id.
public struct DecisionsSidebar: View {
  @Binding private var selectedDecisionID: String?
  private let decisions: [Decision]

  @State private var query: String = ""
  @State private var minSeverity: DecisionSeverity = .info
  @Environment(\.fontScale)
  private var fontScale

  public init(
    decisions: [Decision] = [],
    selection: Binding<String?> = .constant(nil)
  ) {
    self.decisions = decisions
    _selectedDecisionID = selection
  }

  private var groups: [DecisionsSidebarViewModel.SessionGroup] {
    DecisionsSidebarViewModel.grouped(
      decisions: decisions,
      query: query,
      minSeverity: minSeverity
    )
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      content
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionsSidebar)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      TextField("Search decisions", text: $query)
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier(HarnessMonitorAccessibility.decisionsSidebarSearch)
      severityChipRow
    }
    .padding(HarnessMonitorTheme.spacingMD)
  }

  private var severityChipRow: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      ForEach(DecisionSeverity.sidebarOrdering, id: \.self) { severity in
        severityChip(severity)
      }
    }
  }

  private func severityChip(_ severity: DecisionSeverity) -> some View {
    let isActive = minSeverity == severity
    return Button {
      minSeverity = severity
    } label: {
      Text(severity.chipLabel)
        .scaledFont(.caption)
        .padding(.horizontal, HarnessMonitorTheme.pillPaddingH)
        .padding(.vertical, HarnessMonitorTheme.pillPaddingV)
        .background(
          Capsule().fill(isActive ? severity.chipColor : Color.clear)
        )
        .overlay(
          Capsule().stroke(severity.chipColor.opacity(isActive ? 0 : 0.6), lineWidth: 1)
        )
        .foregroundStyle(isActive ? HarnessMonitorTheme.onContrast : severity.chipColor)
        .contentShape(Capsule())
    }
    .harnessFilterChipButtonStyle(isSelected: isActive)
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.decisionsSidebarSeverityChip(severity.rawValue)
    )
    .accessibilityValue(isActive ? "selected" : "not selected")
  }

  @ViewBuilder private var content: some View {
    let visibleGroups = groups
    if visibleGroups.isEmpty {
      emptyState
    } else {
      ScrollView {
        LazyVStack(
          alignment: .leading,
          spacing: HarnessMonitorTheme.spacingMD,
          pinnedViews: [.sectionHeaders]
        ) {
          ForEach(visibleGroups, id: \.sessionID) { group in
            sessionSection(group)
          }
        }
        .padding(.vertical, HarnessMonitorTheme.spacingSM)
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "bell.slash")
        .font(.title2)
        .foregroundStyle(.secondary)
      Text("No decisions match")
        .scaledFont(.body)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  private func sessionSection(
    _ group: DecisionsSidebarViewModel.SessionGroup
  ) -> some View {
    Section {
      ForEach(group.decisions, id: \.id) { decision in
        DecisionRow(
          decision: decision,
          isSelected: selectedDecisionID == decision.id,
          fontScale: fontScale
        ) {
          selectedDecisionID = decision.id
        }
      }
    } header: {
      sessionHeader(group)
    }
  }

  private func sessionHeader(
    _ group: DecisionsSidebarViewModel.SessionGroup
  ) -> some View {
    HStack {
      Text(group.sessionID ?? "No session")
        .scaledFont(.caption)
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      Spacer()
      Text("\(group.decisions.count)")
        .scaledFont(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingXS)
    .background(.background)
  }
}

private struct DecisionRow: View {
  let decision: Decision
  let isSelected: Bool
  let fontScale: CGFloat
  let select: () -> Void

  private var severity: DecisionSeverity {
    DecisionSeverity(rawValue: decision.severityRaw) ?? .info
  }

  var body: some View {
    Button(action: select) {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
        Circle()
          .fill(severity.chipColor)
          .frame(width: 8, height: 8)
          .padding(.top, 6)
        VStack(alignment: .leading, spacing: 2) {
          Text(decision.summary)
            .scaledFont(.body)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
          Text(severity.chipLabel)
            .scaledFont(.caption)
            .foregroundStyle(severity.chipColor)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, HarnessMonitorTheme.spacingMD)
      .padding(.vertical, HarnessMonitorTheme.spacingSM * fontScale)
      .background(
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
          .fill(isSelected ? HarnessMonitorTheme.accent.opacity(0.16) : Color.clear)
      )
      .contentShape(
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
      )
    }
    .harnessDismissButtonStyle()
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionRow(decision.id))
    .accessibilityValue(isSelected ? "selected" : "not selected")
  }
}

extension HarnessMonitorAccessibility {
  public static let decisionsSidebarSearch = "harness.decisions.sidebar.search"

  public static func decisionsSidebarSeverityChip(_ raw: String) -> String {
    "harness.decisions.sidebar.chip.\(slug(raw))"
  }
}
