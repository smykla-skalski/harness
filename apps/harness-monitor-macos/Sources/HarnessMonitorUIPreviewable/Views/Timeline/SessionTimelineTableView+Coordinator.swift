import AppKit
import Combine
import HarnessMonitorKit
import OSLog
import SwiftUI

extension SessionTimelineTableView {
  struct UpdateRequest {
    let scrollView: NSScrollView
    let columnWidth: CGFloat
    let fontScale: CGFloat
  }

  // Coordinator pushes viewport state into `viewport` via methods only; it
  // never reads viewport properties from inside `updateNSView` or any path
  // SwiftUI's observation tracker can see. Reading would re-introduce the
  // body re-eval loop the model exists to break.
  @MainActor
  final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    weak var viewport: SessionTimelineViewportModel?
    var viewportChanged: SessionTimelineViewportHandler
    var scrollBoundaryChanged: SessionTimelineScrollBoundaryHandler

    var heightCacheIdentity: SessionTimelineContentIdentity?
    var rowHeightCache: [String: CachedRowHeight] = [:]
    var lastColumnWidth: CGFloat = 0
    var rows: [SessionTimelineRow] = []
    var eventOffsetsByRow: [Int?] = []
    var rowIndexByID: [String: Int] = [:]
    var rowSnapshot = SessionTimelineTableSnapshot.empty
    var actionHandler: any DecisionActionHandler = NullDecisionActionHandler()
    var onSignalTap: ((String) -> Void)?
    weak var tableView: NSTableView?
    weak var scrollView: NSScrollView?
    var lastScrollCommand: SessionTimelineScrollCommand?
    var pendingScrollCommand: SessionTimelineScrollCommand?
    var lastViewportStats: SessionTimelineTableViewportStats?
    var lastBoundaryState = SessionTimelineScrollBoundaryState(
      visibleMinY: .greatestFiniteMagnitude,
      visibleMaxY: 0,
      contentHeight: .greatestFiniteMagnitude
    )
    var pendingPublish = false
    var pendingPublishForcesObservedStats = false
    private var cancellables = Set<AnyCancellable>()
    var measurementTask: Task<Void, Never>?
    var measurementGeneration: Int = 0
    var fontScale: CGFloat = 1.0

    init(
      viewport: SessionTimelineViewportModel,
      viewportChanged: @escaping SessionTimelineViewportHandler = { _ in },
      scrollBoundaryChanged: @escaping SessionTimelineScrollBoundaryHandler
    ) {
      self.viewport = viewport
      self.viewportChanged = viewportChanged
      self.scrollBoundaryChanged = scrollBoundaryChanged
    }

    func cancelMeasurement(reason: StaticString = "external") {
      guard let task = measurementTask else { return }
      Self.signposter.emitEvent(
        "session_timeline.measurement.cancelled",
        "generation=\(self.measurementGeneration, privacy: .public) reason=\(reason, privacy: .public)"
      )
      task.cancel()
      measurementTask = nil
    }

    func configure(tableView: NSTableView, scrollView: NSScrollView) {
      self.tableView = tableView
      self.scrollView = scrollView
      // Defensive: if a representable re-make calls configure twice, cancel
      // the prior subscription so we never double-observe boundsDidChange.
      cancellables.removeAll()
      // AppKit posts boundsDidChangeNotification synchronously when the contentView
      // shifts, including from scroll(to:) calls inside updateNSView. Calling
      // model writes directly would mutate SwiftUI observable state during the
      // view-update phase and produce an AttributeGraph cycle; defer the publish
      // to the next runloop turn and coalesce successive notifications via
      // pendingPublish.
      NotificationCenter.default
        .publisher(for: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
          Task { @MainActor in self?.boundsDidChange() }
        }
        .store(in: &cancellables)
    }

  }
}
