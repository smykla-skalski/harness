import HarnessMonitorKit
import SwiftUI

struct SessionWindowStandardLayout<Sidebar: View, Detail: View>: View {
  let stateCache: SessionWindowStateCache
  let contentDetailBaseWidth: Double
  let perfContentDividerWidth: Binding<Double?>
  let sessionID: String
  let snapshot: HarnessMonitorSessionWindowSnapshot?
  let decisionIDs: [String]
  let sidebarWidth: Double
  let recordsPlainTaps: Bool
  private let sidebar: Sidebar
  private let detail: Detail
  @SceneStorage("session.columnVisibility")
  private var columnVisibilityRawStorage = "automatic"
  @State private var perfColumnVisibilityStorage: NavigationSplitViewVisibility?

  init(
    stateCache: SessionWindowStateCache,
    contentDetailBaseWidth: Double,
    perfContentDividerWidth: Binding<Double?>,
    sessionID: String,
    snapshot: HarnessMonitorSessionWindowSnapshot?,
    decisionIDs: [String],
    sidebarWidth: Double,
    recordsPlainTaps: Bool,
    @ViewBuilder sidebar: () -> Sidebar,
    @ViewBuilder detail: () -> Detail
  ) {
    self.stateCache = stateCache
    self.contentDetailBaseWidth = contentDetailBaseWidth
    self.perfContentDividerWidth = perfContentDividerWidth
    self.sessionID = sessionID
    self.snapshot = snapshot
    self.decisionIDs = decisionIDs
    self.sidebarWidth = sidebarWidth
    self.recordsPlainTaps = recordsPlainTaps
    self.sidebar = sidebar()
    self.detail = detail()
  }

  var body: some View {
    NavigationSplitView(columnVisibility: columnVisibilityBinding) {
      sidebar
        .navigationSplitViewColumnWidth(min: 190, ideal: sidebarWidth, max: 360)
    } detail: {
      detail
    }
    .navigationSplitViewStyle(.prominentDetail)
    .modifier(
      SessionWindowPlainTapRecorder(
        stateCache: stateCache,
        isEnabled: recordsPlainTaps
      )
    )
    .modifier(
      SessionWindowPerfScenarioScript(
        stateCache: stateCache,
        columnVisibility: columnVisibilityBinding,
        contentDetailBaseWidth: contentDetailBaseWidth,
        contentDetailDividerWidth: perfContentDividerWidth,
        sessionID: sessionID,
        snapshot: snapshot,
        decisionIDs: decisionIDs
      )
    )
  }

  private var columnVisibilityRaw: String {
    get { columnVisibilityRawStorage }
    nonmutating set { columnVisibilityRawStorage = newValue }
  }

  private var columnVisibilityBinding: Binding<NavigationSplitViewVisibility> {
    Binding(
      get: {
        if let perfColumnVisibilityStorage {
          return perfColumnVisibilityStorage
        }
        let decodedVisibility = SessionColumnVisibilityCodec.decode(columnVisibilityRaw)
        return decodedVisibility == .all ? .doubleColumn : decodedVisibility
      },
      set: { newValue in
        let storedVisibility: NavigationSplitViewVisibility =
          newValue == .all ? .doubleColumn : newValue
        if HarnessMonitorUITestEnvironment.isPerfScenarioActive {
          guard perfColumnVisibilityStorage != storedVisibility else { return }
          perfColumnVisibilityStorage = storedVisibility
          return
        }
        let encodedVisibility = SessionColumnVisibilityCodec.encode(storedVisibility)
        guard columnVisibilityRaw != encodedVisibility else { return }
        columnVisibilityRaw = encodedVisibility
      }
    )
  }
}
