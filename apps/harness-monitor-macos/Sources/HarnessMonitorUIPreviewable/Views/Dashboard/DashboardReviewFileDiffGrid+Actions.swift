import AppKit

@MainActor
extension DashboardReviewFileDiffGridContentView {
  func row(at point: NSPoint) -> DashboardReviewFileDiffRow? {
    let index = Int(floor(point.y / rowHeight))
    guard rows.indices.contains(index) else { return nil }
    return rows[index]
  }

  func addMenuItem(_ title: String, action: Selector, to menu: NSMenu) {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    menu.addItem(item)
  }

  @objc
  func copyContextSourceLine() {
    guard let row = contextRow, !row.copyText.isEmpty else { return }
    copyToPasteboard(row.copyText)
  }

  @objc
  func copyContextLineAnchor() {
    guard let row = contextRow else { return }
    copyToPasteboard(lineAnchorText(for: row))
  }

  @objc
  func copyContextPermalink() {
    guard let row = contextRow, let permalink = githubPermalink(for: row) else { return }
    copyToPasteboard(permalink)
  }

  @objc
  func copyContextThreadURL(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? String else { return }
    copyToPasteboard(url)
  }

  @objc
  func copyFilePath() {
    copyToPasteboard(documentPath)
  }

  func copySelectedSourceLine() {
    guard
      let id = selectedRowID,
      let row = rows.first(where: { $0.id == id }),
      !row.copyText.isEmpty
    else {
      return
    }
    copyToPasteboard(row.copyText)
  }

  private var contextRow: DashboardReviewFileDiffRow? {
    guard let contextMenuRowID else { return nil }
    return rows.first { $0.id == contextMenuRowID }
  }

  private func lineAnchorText(for row: DashboardReviewFileDiffRow) -> String {
    if let newLine = row.newLine {
      return "\(documentPath):\(newLine)"
    }
    if let oldLine = row.oldLine {
      return "\(documentPath):old:\(oldLine)"
    }
    return documentPath
  }

  func githubPermalink(for row: DashboardReviewFileDiffRow) -> String? {
    guard
      let repositoryFullName,
      !repositoryFullName.isEmpty,
      !headRefOid.isEmpty,
      let line = row.newLine
    else {
      return nil
    }
    let encodedPath = documentPath.dashboardReviewGitHubPathEncoded
    return "https://github.com/\(repositoryFullName)/blob/\(headRefOid)/\(encodedPath)#L\(line)"
  }

  private func copyToPasteboard(_ value: String) {
    guard !value.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }
}
