import AppKit
import HarnessMonitorKit

@MainActor
extension DashboardReviewFileDiffGridContentView {
  func row(at point: NSPoint) -> DashboardReviewFileDiffRow? {
    guard let index = layout.rowIndexHittingTextLine(atY: point.y),
      rows.indices.contains(index)
    else { return nil }
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

  @objc
  func copyContextHarnessLink(_ sender: NSMenuItem) {
    guard let link = sender.representedObject as? String else { return }
    copyToPasteboard(link)
  }

  /// Build a `harness://` deep link to this file (and lines). Uses the active
  /// multi-row selection when the context row is inside it, otherwise the single
  /// context row. `nil` when the pull request or path is unknown (e.g. the
  /// overview card diff, which is not line-addressable).
  func harnessDeepLink(forContextRow row: DashboardReviewFileDiffRow) -> String? {
    guard !pullRequestID.isEmpty, !documentPath.isEmpty else { return nil }
    let target = ReviewDeepLinkFileTarget(
      path: documentPath,
      lines: harnessLinkSelection(forContextRow: row)
    )
    let route = HarnessMonitorDeepLinkRoute.pullRequest(id: pullRequestID, file: target)
    return HarnessMonitorDeepLinkRouter.url(for: route)?.absoluteString
  }

  /// Context-menu title for the harness link, naming the lines it points to so
  /// the reviewer sees whether it copies the active multi-line selection or just
  /// the row under the cursor.
  func harnessLinkMenuTitle(forContextRow row: DashboardReviewFileDiffRow) -> String {
    guard let selection = harnessLinkSelection(forContextRow: row) else {
      return "Copy Harness Link"
    }
    return selection.isSingleLine
      ? "Copy Harness Link to Line \(selection.start)"
      : "Copy Harness Link to Lines \(selection.start)-\(selection.end)"
  }

  /// Lines the harness link targets: the active selection when the context row
  /// sits inside it, otherwise just that row.
  private func harnessLinkSelection(
    forContextRow row: DashboardReviewFileDiffRow
  ) -> ReviewLineSelection? {
    isRowInSelection(row) ? currentLineSelection() : singleLineSelection(for: row)
  }

  private func singleLineSelection(
    for row: DashboardReviewFileDiffRow
  ) -> ReviewLineSelection? {
    if let newLine = row.newLine { return ReviewLineSelection(line: newLine, side: .right) }
    if let oldLine = row.oldLine { return ReviewLineSelection(line: oldLine, side: .left) }
    return nil
  }

  private func copyToPasteboard(_ value: String) {
    guard !value.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }
}
