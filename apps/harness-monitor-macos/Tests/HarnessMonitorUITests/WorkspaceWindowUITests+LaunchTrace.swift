import XCTest

struct WorkspaceLaunchTraceContext {
  let launchPane: XCUIElement
  let scrollTarget: XCUIElement
  let launchAction: XCUIElement
  let identifier: String
}

@MainActor
extension WorkspaceWindowUITestSupporting where Self: HarnessMonitorUITestCase {
  func recordWorkspaceLaunchTrace(
    in app: XCUIApplication,
    event: String,
    context: WorkspaceLaunchTraceContext,
    extraDetails: [String: String]
  ) {
    var details = extraDetails
    details["identifier"] = context.identifier
    details["launch_pane"] = workspaceLaunchElementSummary(context.launchPane)
    details["scroll_target"] = workspaceLaunchElementSummary(context.scrollTarget)
    details["launch_action"] = workspaceLaunchElementSummary(context.launchAction)
    details["launch_pane_scroll_views"] = workspaceLaunchScrollViewSummary(
      context.launchPane.descendants(matching: .scrollView)
    )

    let frameMarker = descendantFrameElement(
      in: context.launchPane,
      identifier: "\(context.identifier).frame"
    )
    details["frame_marker"] = workspaceLaunchElementSummary(frameMarker)
    if frameMarker.exists, !frameMarker.frame.isEmpty {
      let containingWindow = window(in: app, containing: frameMarker)
      details["containing_window"] = workspaceLaunchElementSummary(containingWindow)
      let viewportFrame = context.scrollTarget.frame.intersection(containingWindow.frame)
      details["viewport_frame"] = workspaceLaunchFrameSummary(viewportFrame)
      let visibleFrame = viewportFrame.intersection(frameMarker.frame)
      details["visible_frame"] = workspaceLaunchFrameSummary(visibleFrame)
    }

    recordDiagnosticsTrace(
      component: "workspace-launch",
      event: event,
      details: details
    )
  }

  private func workspaceLaunchElementSummary(_ element: XCUIElement) -> String {
    guard element.exists else {
      return "exists=false type=\(String(describing: element.elementType))"
    }

    let identifierSummary =
      element.identifier.isEmpty ? "" : " identifier=\(element.identifier)"
    return
      "exists=true type=\(String(describing: element.elementType))"
      + " hittable=\(element.isHittable)"
      + identifierSummary
      + " frame=\(workspaceLaunchFrameSummary(element.frame))"
  }

  private func workspaceLaunchScrollViewSummary(_ query: XCUIElementQuery) -> String {
    let sampleCount = min(query.count, 4)
    guard sampleCount > 0 else {
      return "none"
    }

    return (0..<sampleCount).map { index in
      let candidate = query.element(boundBy: index)
      return
        "[\(index)] \(workspaceLaunchElementSummary(candidate))"
    }
    .joined(separator: " | ")
  }

  private func workspaceLaunchFrameSummary(_ frame: CGRect) -> String {
    guard !frame.isNull else {
      return "null"
    }
    return String(
      format: "x=%.1f y=%.1f w=%.1f h=%.1f",
      frame.origin.x,
      frame.origin.y,
      frame.size.width,
      frame.size.height
    )
  }

  func workspaceLaunchRevealSignature(
    in app: XCUIApplication,
    launchPane: XCUIElement,
    scrollTarget: XCUIElement,
    identifier: String
  ) -> String {
    let frameMarker = descendantFrameElement(in: launchPane, identifier: "\(identifier).frame")
    let launchAction = descendantButton(in: launchPane, identifier: identifier)
    let frameMarkerSummary = workspaceLaunchFrameSummary(frameMarker.frame)
    let launchActionSummary = workspaceLaunchFrameSummary(launchAction.frame)

    guard frameMarker.exists, !frameMarker.frame.isEmpty else {
      return [frameMarkerSummary, launchActionSummary].joined(separator: " | ")
    }

    let containingWindow = window(in: app, containing: frameMarker)
    let viewportFrame = scrollTarget.frame.intersection(containingWindow.frame)
    let visibleFrame = viewportFrame.intersection(frameMarker.frame)
    return [
      frameMarkerSummary,
      launchActionSummary,
      workspaceLaunchFrameSummary(visibleFrame),
    ].joined(separator: " | ")
  }
}
