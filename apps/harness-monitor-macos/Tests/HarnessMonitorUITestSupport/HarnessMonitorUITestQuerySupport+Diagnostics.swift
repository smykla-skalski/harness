import XCTest

extension HarnessMonitorUITestCase {
  func sidebarFilterControlDiagnostics(in app: XCUIApplication) -> String {
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
            HarnessMonitorUITestAccessibility.sidebarFiltersCard,
            HarnessMonitorUITestAccessibility.sidebarStatusPicker
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
        .matching(
          NSPredicate(
            format: "label == %@ OR label == %@",
            "Filters",
            "Filter"
          )
        )
        .allElementsBoundByIndex
      for (index, element) in titleMatches.enumerated() {
        lines.append(
          "title role=\(role.rawValue) index=\(index) exists=\(element.exists) "
            + "hittable=\(element.isHittable) frame=\(element.frame) identifier=\(element.identifier)"
        )
      }

      let statusMatches = mainWindow(in: app)
        .descendants(matching: role)
        .matching(
          NSPredicate(
            format: "label == %@",
            "Status"
          )
        )
        .allElementsBoundByIndex
      for (index, element) in statusMatches.enumerated() {
        lines.append(
          "status role=\(role.rawValue) index=\(index) exists=\(element.exists) "
            + "hittable=\(element.isHittable) frame=\(element.frame) identifier=\(element.identifier)"
        )
      }
    }

    if lines.isEmpty {
      return "no sidebar filter accessibility candidates"
    }
    return lines.joined(separator: "\n")
  }
}
