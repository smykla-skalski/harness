import AppKit
import SwiftUI

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

func viewBodySpanAttributes(
  in collector: FakeTraceCollector,
  viewName: String
) -> [String: String]? {
  for span in collector.receivedSpans.flatMap(\.scopeSpans).flatMap(\.spans) {
    let attributes = Dictionary(
      uniqueKeysWithValues: span.attributes.map { attribute in
        (attribute.key, attribute.value.stringValue)
      }
    )
    guard span.name == "perf.view.body",
      attributes["harness.view.name"] == viewName
    else {
      continue
    }
    return attributes
  }
  return nil
}

@MainActor
func render<Content: View>(
  _ view: Content,
  width: CGFloat,
  height: CGFloat
) {
  let host = NSHostingView(rootView: view)
  host.frame = CGRect(x: 0, y: 0, width: width, height: height)
  host.layoutSubtreeIfNeeded()
  _ = host.fittingSize
}

func withViewBodyProfilingEnabled<T>(_ operation: () throws -> T) rethrows -> T {
  try withEnvironmentValue(
    "HARNESS_MONITOR_PROFILE_VIEW_BODIES",
    value: "1",
    operation: operation
  )
}

@MainActor
func renderLaunchDashboardProfiledViews() -> HarnessMonitorStore {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLanding)
  let metrics = HarnessMonitorPreviewStoreFactory.makeConnectionMetrics(
    latencyMs: 24,
    messagesPerSecond: 7.2
  )

  render(ContentView(store: store), width: 1_440, height: 1_024)
  render(
    SidebarView(
      store: store,
      controls: store.sessionIndex.controls,
      projection: store.sessionIndex.projection,
      searchResults: store.sessionIndex.searchResults,
      sidebarUI: store.sidebarUI,
      canPresentSearch: true
    ),
    width: 340,
    height: 900
  )
  render(ConnectionToolbarBadge(metrics: metrics), width: 140, height: 20)
  return store
}

private func withEnvironmentValue<T>(
  _ key: String,
  value: String?,
  operation: () throws -> T
) rethrows -> T {
  let previousValue = getenv(key).map { String(cString: $0) }
  if let value {
    setenv(key, value, 1)
  } else {
    unsetenv(key)
  }
  defer {
    if let previousValue {
      setenv(key, previousValue, 1)
    } else {
      unsetenv(key)
    }
  }
  return try operation()
}
