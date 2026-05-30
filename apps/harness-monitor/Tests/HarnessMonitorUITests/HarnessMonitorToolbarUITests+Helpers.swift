import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

extension HarnessMonitorToolbarUITests {
  func distinctVisibleToolbarFrames(for query: XCUIElementQuery) -> Set<String> {
    var frames: [CGRect] = []
    let searchCount = min(query.count, 8)
    for index in 0..<searchCount {
      let element = query.element(boundBy: index)
      guard element.exists else {
        continue
      }
      let frame = roundedFrame(element.frame)
      // macOS toolbars expose inner icon buttons inside the outer
      // toolbar control. Keep only the outermost visible frame instead of
      // relying on a fixed size cutoff.
      guard
        !frame.isEmpty,
        frame.width >= minimumToolbarControlDimension,
        frame.height >= minimumToolbarControlDimension
      else {
        continue
      }

      if frames.contains(where: { equivalentFrame($0, frame) }) {
        continue
      }
      if frames.contains(where: { containsFrame($0, frame) }) {
        continue
      }
      frames.removeAll { containsFrame(frame, $0) }
      frames.append(frame)
    }

    return Set(frames.map(frameSignature))
  }

  func roundedFrame(_ frame: CGRect) -> CGRect {
    CGRect(
      x: frame.minX.rounded(),
      y: frame.minY.rounded(),
      width: frame.width.rounded(),
      height: frame.height.rounded()
    )
  }

  func frameSignature(_ frame: CGRect) -> String {
    "\(Int(frame.minX)):\(Int(frame.minY)):\(Int(frame.width)):\(Int(frame.height))"
  }

  func equivalentFrame(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 1) -> Bool {
    abs(lhs.minX - rhs.minX) <= tolerance
      && abs(lhs.minY - rhs.minY) <= tolerance
      && abs(lhs.width - rhs.width) <= tolerance
      && abs(lhs.height - rhs.height) <= tolerance
  }

  func containsFrame(_ outer: CGRect, _ inner: CGRect, tolerance: CGFloat = 1) -> Bool {
    outer.minX - tolerance <= inner.minX
      && outer.minY - tolerance <= inner.minY
      && outer.maxX + tolerance >= inner.maxX
      && outer.maxY + tolerance >= inner.maxY
  }

  func createMenuControlDiagnostics(in app: XCUIApplication) -> String {
    let roles: [XCUIElement.ElementType] = [
      .button,
      .menuButton,
      .popUpButton,
      .radioButton,
      .cell,
      .any,
    ]
    var lines: [String] = []

    for role in roles {
      let identifierMatches = mainWindow(in: app)
        .descendants(matching: role)
        .matching(
          NSPredicate(
            format: "identifier == %@ OR identifier == %@",
            Accessibility.sidebarCreateMenuButton,
            Accessibility.sidebarCreateMenuButtonFrame
          )
        )
        .allElementsBoundByIndex
      for (index, element) in identifierMatches.enumerated() {
        lines.append(
          "identifier role=\(role.rawValue) index=\(index) exists=\(element.exists) "
            + "hittable=\(element.isHittable) frame=\(element.frame) label=\(element.label)"
        )
      }

      let titleMatches = mainWindow(in: app)
        .descendants(matching: role)
        .matching(NSPredicate(format: "label == %@", "Create"))
        .allElementsBoundByIndex
      for (index, element) in titleMatches.enumerated() {
        lines.append(
          "title role=\(role.rawValue) index=\(index) exists=\(element.exists) "
            + "hittable=\(element.isHittable) frame=\(element.frame) identifier=\(element.identifier)"
        )
      }
    }

    if lines.isEmpty {
      return "no create menu accessibility candidates"
    }
    return lines.joined(separator: " | ")
  }

  func createToolbarMenuCandidate(in app: XCUIApplication) -> XCUIElement? {
    for menu in app.menus.allElementsBoundByIndex.prefix(6) {
      let hasNewAgent = presentedMenuItem(
        in: menu,
        identifier: Accessibility.sidebarCreateMenuNewAgentItem
      ).exists
      let hasNewTask = presentedMenuItem(
        in: menu,
        identifier: Accessibility.sidebarCreateMenuNewTaskItem
      ).exists
      let hasNewSession = presentedMenuItem(in: menu, title: "New Session").exists
      if hasNewAgent && hasNewTask && !hasNewSession {
        return menu
      }
    }
    return nil
  }

  func presentedMenuItem(in menu: XCUIElement, identifier: String) -> XCUIElement {
    let candidateQueries: [XCUIElementQuery] = [
      menu.descendants(matching: .menuItem).matching(identifier: identifier),
      menu.descendants(matching: .button).matching(identifier: identifier),
      menu.descendants(matching: .staticText).matching(identifier: identifier),
      menu.descendants(matching: .any).matching(identifier: identifier),
    ]

    for query in candidateQueries {
      let element = query.firstMatch
      if element.exists {
        return element
      }
    }

    return candidateQueries.last!.firstMatch
  }

  func presentedMenuItem(in menu: XCUIElement, title: String) -> XCUIElement {
    let predicate = NSPredicate(
      format: "label == %@ OR title == %@ OR identifier == %@",
      title,
      title,
      title
    )

    let candidateQueries: [XCUIElementQuery] = [
      menu.descendants(matching: .menuItem).matching(predicate),
      menu.descendants(matching: .button).matching(predicate),
      menu.descendants(matching: .staticText).matching(predicate),
      menu.descendants(matching: .any).matching(predicate),
    ]

    for query in candidateQueries {
      let element = query.firstMatch
      if element.exists {
        return element
      }
    }

    return candidateQueries.last!.firstMatch
  }
}
