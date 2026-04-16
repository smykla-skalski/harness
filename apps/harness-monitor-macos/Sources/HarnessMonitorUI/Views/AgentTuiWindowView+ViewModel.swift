import AppKit
import HarnessMonitorKit
import Observation
import SwiftUI

extension AgentTuiWindowView {
  enum Field: Hashable {
    case name
    case prompt
    case argv
    case input
  }

  struct AgentNameMapping: Equatable {
    let agentID: String
    let name: String
  }

  struct AgentTuiDisplayState: Equatable {
    let sortedAgentTuis: [AgentTuiSnapshot]
    let sessionTitlesByID: [String: String]
    let agentTuiUnavailable: Bool

    var hasAgentTuis: Bool {
      !sortedAgentTuis.isEmpty
    }

    init() {
      sortedAgentTuis = []
      sessionTitlesByID = [:]
      agentTuiUnavailable = false
    }

    @MainActor
    init(store: HarnessMonitorStore) {
      let sortedAgentTuis = store.selectedAgentTuis.sorted { left, right in
        if left.status.sortPriority != right.status.sortPriority {
          return left.status.sortPriority < right.status.sortPriority
        }
        if left.runtime != right.runtime {
          return left.runtime < right.runtime
        }
        return left.tuiId < right.tuiId
      }

      let agentNames = Dictionary(
        uniqueKeysWithValues: (store.selectedSession?.agents ?? []).map { ($0.agentId, $0.name) }
      )
      var sessionTitlesByID: [String: String] = [:]
      sessionTitlesByID.reserveCapacity(sortedAgentTuis.count)
      for tui in sortedAgentTuis {
        sessionTitlesByID[tui.tuiId] =
          agentNames[tui.agentId] ?? AgentTuiWindowView.runtimeTitle(for: tui)
      }

      self.sortedAgentTuis = sortedAgentTuis
      self.sessionTitlesByID = sessionTitlesByID
      self.agentTuiUnavailable = store.agentTuiUnavailable
    }
  }

  enum AgentTuiInputMode: String, CaseIterable, Identifiable {
    case text
    case paste

    var id: String { rawValue }

    var title: String {
      switch self {
      case .text:
        "Type"
      case .paste:
        "Paste"
      }
    }
  }

  enum TerminalViewportSizing {
    static let rowRange = 8...240
    static let colRange = 20...400
    static let minimumViewportHeight: CGFloat = 220
    static let idealViewportHeight: CGFloat = 320
    static let minimumControlsHeight: CGFloat = 220
    static let minimumMeasuredContentWidth: CGFloat = 160
    static let minimumMeasuredContentHeight: CGFloat = 96
    static let debounce = Duration.milliseconds(120)
    static let automaticResizeMinimumRowDelta = 2
    static let automaticResizeMinimumColDelta = 3
    static let contentInsets = CGSize(
      width: HarnessMonitorTheme.spacingMD * 2,
      height: HarnessMonitorTheme.spacingMD * 2
    )

    @MainActor
    static func terminalSize(for viewportSize: CGSize, fontScale: CGFloat) -> AgentTuiSize? {
      let cellSize = measuredCellSize(for: fontScale)
      let usableWidth = max(
        viewportSize.width - contentInsets.width,
        minimumMeasuredContentWidth
      )
      let usableHeight = max(
        viewportSize.height - contentInsets.height,
        minimumMeasuredContentHeight
      )
      let rawRows = Int(floor(usableHeight / cellSize.height))
      let rawCols = Int(floor(usableWidth / cellSize.width))
      guard rawRows > 0, rawCols > 0 else {
        return nil
      }
      return AgentTuiSize(
        rows: min(max(rawRows, rowRange.lowerBound), rowRange.upperBound),
        cols: min(max(rawCols, colRange.lowerBound), colRange.upperBound)
      )
    }

    static func stabilizedAutomaticSize(
      measured: AgentTuiSize,
      baseline: AgentTuiSize
    ) -> AgentTuiSize {
      AgentTuiSize(
        rows: stabilizedDimension(
          measured: measured.rows,
          baseline: baseline.rows,
          minimumDelta: automaticResizeMinimumRowDelta
        ),
        cols: stabilizedDimension(
          measured: measured.cols,
          baseline: baseline.cols,
          minimumDelta: automaticResizeMinimumColDelta
        )
      )
    }

    @MainActor
    private static func measuredCellSize(for fontScale: CGFloat) -> CGSize {
      let pointSize = 13 * max(fontScale, 0.78)
      let font = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
      let width = max(
        ceil(("W" as NSString).size(withAttributes: [.font: font]).width),
        1
      )
      let height = max(ceil(font.ascender - font.descender + font.leading), 1)
      return CGSize(width: width, height: height)
    }

    private static func stabilizedDimension(
      measured: Int,
      baseline: Int,
      minimumDelta: Int
    ) -> Int {
      abs(measured - baseline) >= minimumDelta ? measured : baseline
    }
  }

  @MainActor
  @Observable
  final class ViewModel {
    var displayState = AgentTuiDisplayState()
    var runtime: AgentTuiRuntime = .copilot
    var name = ""
    var prompt = ""
    var projectDir = ""
    var argvOverride = ""
    var inputText = ""
    var inputMode: AgentTuiInputMode = .text
    var rows = 32
    var cols = 120
    var isSubmitting = false
    var selection: AgentTuiSheetSelection = .create
    var wrapLines = false
    var selectedPersona: String?
    var availablePersonas: [AgentPersona] = []
    var expandedPersonaInfo: String?
    var navigationBackStack: [AgentTuiSheetSelection] = []
    var navigationForwardStack: [AgentTuiSheetSelection] = []
    var suppressHistoryRecording = false
    var windowNavigation = WindowNavigationState()
    var pendingViewportResizeTarget: AgentTuiSize?
    var viewportResizeTask: Task<Void, Never>?

    init(
      displayState: AgentTuiDisplayState = AgentTuiDisplayState(),
      selection: AgentTuiSheetSelection = .create
    ) {
      self.displayState = displayState
      self.selection = selection
    }
  }
}
