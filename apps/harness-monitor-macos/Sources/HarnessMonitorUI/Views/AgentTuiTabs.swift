import HarnessMonitorKit
import SwiftUI

enum AgentTuiSheetSelection: Equatable {
  case create
  case session(String)

  var sessionID: String? {
    guard case .session(let sessionID) = self else {
      return nil
    }
    return sessionID
  }
}

struct AgentTuiTabLayout: Equatable {
  let visibleSessionIDs: [String]
  let overflowSessionIDs: [String]

  static func make(
    recentSessionIDs: [String],
    selectedSessionID: String?,
    availableWidth: CGFloat,
    controlsWidth: CGFloat = 148,
    createTabWidth: CGFloat = 44,
    sessionTabMinimumWidth: CGFloat = 152,
    overflowPickerWidth: CGFloat = 124,
    maximumVisibleSessionTabs: Int = 4,
    fallbackWidth: CGFloat = 760
  ) -> Self {
    let orderedSessionIDs = stableUniqueSessionIDs(recentSessionIDs)
    guard !orderedSessionIDs.isEmpty else {
      return Self(visibleSessionIDs: [], overflowSessionIDs: [])
    }

    let effectiveWidth = availableWidth > 0 ? availableWidth : fallbackWidth
    let contentWidth = max(effectiveWidth - controlsWidth - createTabWidth, sessionTabMinimumWidth)
    let visibleSlotsWithoutOverflow = max(
      1,
      Int(contentWidth / sessionTabMinimumWidth)
    )

    let cappedVisibleSlotsWithoutOverflow = min(
      visibleSlotsWithoutOverflow,
      max(1, maximumVisibleSessionTabs)
    )

    let visibleSlots: Int
    if orderedSessionIDs.count <= cappedVisibleSlotsWithoutOverflow {
      visibleSlots = min(orderedSessionIDs.count, cappedVisibleSlotsWithoutOverflow)
    } else {
      let overflowWidth = max(
        contentWidth - overflowPickerWidth,
        sessionTabMinimumWidth
      )
      visibleSlots = min(
        max(1, maximumVisibleSessionTabs),
        max(1, Int(overflowWidth / sessionTabMinimumWidth))
      )
    }

    var visibleSessionIDs = Array(orderedSessionIDs.prefix(visibleSlots))
    if let selectedSessionID,
      orderedSessionIDs.contains(selectedSessionID),
      !visibleSessionIDs.contains(selectedSessionID)
    {
      if visibleSessionIDs.isEmpty {
        visibleSessionIDs = [selectedSessionID]
      } else {
        visibleSessionIDs[visibleSessionIDs.count - 1] = selectedSessionID
      }
    }

    let overflowSessionIDs = orderedSessionIDs.filter { sessionID in
      !visibleSessionIDs.contains(sessionID)
    }

    return Self(
      visibleSessionIDs: visibleSessionIDs,
      overflowSessionIDs: overflowSessionIDs
    )
  }

  private static func stableUniqueSessionIDs(_ sessionIDs: [String]) -> [String] {
    var seenSessionIDs: Set<String> = []
    var orderedSessionIDs: [String] = []
    orderedSessionIDs.reserveCapacity(sessionIDs.count)

    for sessionID in sessionIDs where !sessionID.isEmpty {
      if seenSessionIDs.insert(sessionID).inserted {
        orderedSessionIDs.append(sessionID)
      }
    }

    return orderedSessionIDs
  }
}

struct AgentTuiTabStrip: View {
  let recentSessionIDs: [String]
  let selection: AgentTuiSheetSelection
  let titleForSessionID: (String) -> String
  let refresh: () -> Void
  let selectCreateTab: () -> Void
  let selectSessionTab: (String) -> Void

  @State private var availableWidth: CGFloat = 0

  private var tabLayout: AgentTuiTabLayout {
    AgentTuiTabLayout.make(
      recentSessionIDs: recentSessionIDs,
      selectedSessionID: selection.sessionID,
      availableWidth: availableWidth
    )
  }

  private var overflowSelection: Binding<String> {
    Binding(
      get: {
        guard let selectedSessionID = selection.sessionID,
          tabLayout.overflowSessionIDs.contains(selectedSessionID)
        else {
          return ""
        }
        return selectedSessionID
      },
      set: { selectedSessionID in
        guard !selectedSessionID.isEmpty else {
          return
        }
        selectSessionTab(selectedSessionID)
      }
    )
  }

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.itemSpacing) {
      HStack(alignment: .center, spacing: 0) {
        createTabButton
        ForEach(tabLayout.visibleSessionIDs, id: \.self) { sessionID in
          sessionTabButton(sessionID: sessionID)
        }
      }

      Spacer(minLength: HarnessMonitorTheme.itemSpacing)

      HStack(alignment: .center, spacing: HarnessMonitorTheme.itemSpacing) {
        if !tabLayout.overflowSessionIDs.isEmpty {
          Picker("More sessions", selection: overflowSelection) {
            Text("More").tag("")
            ForEach(tabLayout.overflowSessionIDs, id: \.self) { sessionID in
              Text(titleForSessionID(sessionID)).tag(sessionID)
            }
          }
          .pickerStyle(.menu)
          .labelsHidden()
          .frame(minWidth: 108)
          .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiOverflowPicker)
          .accessibilityTestProbe(
            HarnessMonitorAccessibility.agentTuiOverflowPicker,
            label: "More sessions"
          )
          .accessibilityFrameMarker(
            "\(HarnessMonitorAccessibility.agentTuiOverflowPicker).frame"
          )
        }

        Button("Refresh") {
          refresh()
        }
        .harnessActionButtonStyle(variant: .bordered, tint: nil)
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiRefreshButton)
      }
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingLG)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .background(.quaternary.opacity(0.35))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiTabStrip)
    .onGeometryChange(for: CGFloat.self) { geometryProxy in
      geometryProxy.size.width
    } action: { width in
      availableWidth = width
    }
    .overlay {
      AccessibilityTextMarker(
        identifier: HarnessMonitorAccessibility.agentTuiTabStripState,
        text:
          "width=\(Int(availableWidth.rounded()))"
          + ", visible=\(tabLayout.visibleSessionIDs.joined(separator: "|"))"
          + ", overflow=\(tabLayout.overflowSessionIDs.joined(separator: "|"))"
      )
    }
  }

  private var createTabButton: some View {
    AgentTuiTabButton(
      title: "Create agent",
      iconSystemName: "plus",
      showsTitle: false,
      isSelected: selection == .create,
      accessibilityIdentifier: HarnessMonitorAccessibility.agentTuiCreateTab,
      action: selectCreateTab
    )
  }

  private func sessionTabButton(sessionID: String) -> some View {
    AgentTuiTabButton(
      title: titleForSessionID(sessionID),
      iconSystemName: nil,
      showsTitle: true,
      isSelected: selection.sessionID == sessionID,
      accessibilityIdentifier: HarnessMonitorAccessibility.agentTuiTab(sessionID),
      action: {
        selectSessionTab(sessionID)
      }
    )
  }
}

private struct AgentTuiTabButton: View {
  let title: String
  let iconSystemName: String?
  let showsTitle: Bool
  let isSelected: Bool
  let accessibilityIdentifier: String
  let action: () -> Void

  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  var body: some View {
    Button {
      withAnimation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.15)) {
        action()
      }
    } label: {
      HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingXS) {
        if let iconSystemName {
          Image(systemName: iconSystemName)
            .imageScale(.small)
        }
        if showsTitle {
          Text(title)
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }
      .scaledFont(.body)
      .fontWeight(isSelected ? .semibold : .regular)
      .foregroundStyle(isSelected ? .primary : .secondary)
      .padding(.horizontal, HarnessMonitorTheme.spacingMD)
      .padding(.vertical, HarnessMonitorTheme.spacingSM)
      .background {
        if isSelected {
          UnevenRoundedRectangle(
            topLeadingRadius: 6,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: 6,
            style: .continuous
          )
          .fill(Color(nsColor: .quaternarySystemFill))
        }
      }
      .contentShape(Rectangle())
      .frame(minWidth: showsTitle ? 132 : 0)
    }
    .harnessDismissButtonStyle()
    .accessibilityIdentifier(accessibilityIdentifier)
    .accessibilityLabel(title)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }
}
