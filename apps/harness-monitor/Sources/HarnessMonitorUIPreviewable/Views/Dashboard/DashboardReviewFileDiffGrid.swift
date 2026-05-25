import AppKit
import HarnessMonitorKit
import SwiftUI

struct DashboardReviewFileDiffGrid: NSViewRepresentable {
  let document: DashboardReviewFileDiffDocument
  let viewMode: FilesViewMode
  let fontScale: CGFloat
  let softWrapEnabled: Bool
  let threads: [DashboardReviewFileThreadAnchor]
  let repositoryFullName: String?
  let onPreferredViewportHeightChange: (@MainActor (CGFloat) -> Void)?

  // Inline conversation inputs ride the environment (see
  // `DashboardReviewInlineConversationContext`) so `Unified`/`Split`/`Preview`
  // need no extra parameters; `nil` keeps the canvas a flat diff grid.
  @Environment(\.reviewInlineConversationContext)
  private var conversation

  init(
    document: DashboardReviewFileDiffDocument,
    viewMode: FilesViewMode,
    fontScale: CGFloat,
    softWrapEnabled: Bool = true,
    threads: [DashboardReviewFileThreadAnchor] = [],
    repositoryFullName: String? = nil,
    onPreferredViewportHeightChange: (@MainActor (CGFloat) -> Void)? = nil
  ) {
    self.document = document
    self.viewMode = viewMode
    self.fontScale = fontScale
    self.softWrapEnabled = softWrapEnabled
    self.threads = threads
    self.repositoryFullName = repositoryFullName
    self.onPreferredViewportHeightChange = onPreferredViewportHeightChange
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = DashboardReviewFileDiffScrollView()
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    scrollView.hasHorizontalScroller = !softWrapEnabled
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.documentView = DashboardReviewFileDiffGridContentView()
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    let contentView =
      scrollView.documentView as? DashboardReviewFileDiffGridContentView
      ?? DashboardReviewFileDiffGridContentView()
    if scrollView.documentView !== contentView {
      scrollView.documentView = contentView
    }
    scrollView.hasHorizontalScroller = !softWrapEnabled
    contentView.configure(
      document: document,
      viewMode: viewMode,
      fontScale: fontScale,
      softWrapEnabled: softWrapEnabled,
      threads: threads,
      repositoryFullName: repositoryFullName,
      conversationThreads: conversation?.threads ?? [],
      conversationVisibility: conversation?.visibility ?? .all,
      viewerLogin: conversation?.viewerLogin,
      loadAvatar: conversation?.loadAvatar,
      onResolveToggle: conversation?.onResolveToggle,
      onReply: conversation?.onReply,
      onPreferredViewportHeightChange: { height in
        scrollView.invalidateIntrinsicContentSize()
        onPreferredViewportHeightChange?(height)
      }
    )
    contentView.resizeForViewportWidth(scrollView.contentSize.width)
  }

  static func viewportHeight(rowCount: Int, fontScale: CGFloat) -> CGFloat {
    let rowHeight = DashboardReviewDiffTypography.rowHeight(fontScale: fontScale)
    let contentHeight = CGFloat(max(rowCount, 1)) * rowHeight + 2
    return min(max(contentHeight, 84), 720)
  }

  final class Coordinator {}
}

@MainActor
final class DashboardReviewFileDiffGridContentView: NSView {
  private struct WrapKey: Hashable {
    let rowID: Int
    let characterLimit: Int
    let softWrapEnabled: Bool
  }

  struct SemanticCodeLineKey: Hashable {
    let rowID: Int
    let lineIndex: Int
    let leadingIndentColumns: Int
    let startOffset: Int
    let endOffset: Int
    let pointSize: CGFloat
  }

  var rows: [DashboardReviewFileDiffRow] = []
  var wrappedRowLayouts: [DashboardReviewFileDiffWrappedRowLayout] = []
  private var wrappedRowCache: [WrapKey: DashboardReviewFileDiffWrappedRowLayout] = [:]
  var semanticCodeLineCache: [SemanticCodeLineKey: DashboardReviewFileDiffTextLineLayout] = [:]
  var viewMode: FilesViewMode = .unified
  var codeLanguage: HarnessCodeLanguage = .generic
  var longestCodeCharacterCount = 0
  var softWrapEnabled = false
  var threadsByRowID: [Int: [DashboardReviewFileThreadAnchor]] = [:]
  var rowIndexByID: [Int: Int] = [:]
  var selectedRowID: Int?
  var documentPath = ""
  var headRefOid = ""
  var repositoryFullName: String?
  var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  var typographyMetrics = DashboardReviewDiffTypography.layoutMetrics(
    for: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  )
  var rowHeight: CGFloat = 19
  var characterWidth: CGFloat = 7.2
  var contextMenuRowID: Int?

  // Inline conversation hosting (populated once the panes plumb real threads).
  var layout = DashboardReviewFileDiffThreadLayout(rowCount: 0, rowHeight: 19)
  var threadsByID: [String: DashboardReviewFileThread] = [:]
  var conversationVisibility: ConversationVisibility = .all
  var cardFontScale: CGFloat = 1
  var cardViewerLogin: String?
  var cardLoadAvatar: TimelineAvatarImageLoader?
  var cardResolveToggle: ((String, Bool) async -> Void)?
  var cardReply: ((String, String) async -> Bool)?
  var cardHostsByRowID: [Int: NSHostingView<DashboardReviewInlineThreadCardStack>] = [:]
  var cardHeightByRowID: [Int: CGFloat] = [:]
  var measuredCardHeightCache: [String: CGFloat] = [:]
  var onPreferredViewportHeightChange: (@MainActor (CGFloat) -> Void)?

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  func configure(
    document: DashboardReviewFileDiffDocument,
    viewMode: FilesViewMode,
    fontScale: CGFloat,
    softWrapEnabled: Bool,
    threads: [DashboardReviewFileThreadAnchor],
    repositoryFullName: String?,
    conversationThreads: [DashboardReviewFileThread],
    conversationVisibility: ConversationVisibility,
    viewerLogin: String?,
    loadAvatar: TimelineAvatarImageLoader?,
    onResolveToggle: ((String, Bool) async -> Void)?,
    onReply: ((String, String) async -> Bool)?,
    onPreferredViewportHeightChange: (@MainActor (CGFloat) -> Void)?
  ) {
    let nextFont = DashboardReviewDiffTypography.appKitFont(for: fontScale)
    let nextLanguage = HarnessCodeLanguage(reviewLanguage: document.language)
    let layoutInputsChanged =
      rows != document.rows
      || self.viewMode != viewMode
      || codeLanguage != nextLanguage
      || abs(font.pointSize - nextFont.pointSize) > 0.001
      || self.softWrapEnabled != softWrapEnabled
    rows = document.rows
    self.viewMode = viewMode
    codeLanguage = nextLanguage
    longestCodeCharacterCount = document.longestCodeCharacterCount
    self.softWrapEnabled = softWrapEnabled
    threadsByRowID = DashboardReviewFileDiffThreadMap.build(
      rows: document.rows,
      threads: conversationThreads.isEmpty ? threads : conversationThreads.map(\.anchor)
    )
    rowIndexByID = Dictionary(
      uniqueKeysWithValues: document.rows.enumerated().map { ($1.id, $0) }
    )
    threadsByID = Dictionary(conversationThreads.map { ($0.id, $0) }) { first, _ in first }
    self.conversationVisibility = conversationVisibility
    cardFontScale = fontScale
    cardViewerLogin = viewerLogin
    cardLoadAvatar = loadAvatar
    cardResolveToggle = onResolveToggle
    cardReply = onReply
    self.onPreferredViewportHeightChange = onPreferredViewportHeightChange
    selectedRowID = selectedRowID.flatMap { selected in
      document.rows.contains(where: { $0.id == selected }) ? selected : nil
    }
    documentPath = document.path
    headRefOid = document.headRefOid
    self.repositoryFullName = repositoryFullName
    font = nextFont
    typographyMetrics = DashboardReviewDiffTypography.layoutMetrics(for: font)
    rowHeight = typographyMetrics.rowHeight
    characterWidth = max(6, ("M" as NSString).size(withAttributes: [.font: font]).width)
    if layoutInputsChanged {
      wrappedRowCache = [:]
      wrappedRowLayouts = []
      semanticCodeLineCache = [:]
    }
    measuredCardHeightCache = [:]
    cardHeightByRowID = [:]
    needsDisplay = true
  }

  /// Horizontal content width (drives the horizontal scroller); independent of
  /// the inline card layout, which only adds vertical gaps.
  func contentWidth(viewportWidth: CGFloat) -> CGFloat {
    guard !softWrapEnabled else {
      return ceil(max(viewportWidth, 1))
    }
    let visibleCharacters = CGFloat(max(longestCodeCharacterCount, 80))
    let codeWidth = visibleCharacters * characterWidth
    let width: CGFloat =
      switch viewMode {
      case .unified:
        max(viewportWidth, 130 + codeWidth)
      case .split:
        max(viewportWidth, 2 * (96 + codeWidth) + 18)
      }
    return ceil(width)
  }

  func resizeForViewportWidth(_ viewportWidth: CGFloat) {
    let width = contentWidth(viewportWidth: viewportWidth)
    rebuildWrappedRowLayouts(contentWidth: width)
    rebuildThreadLayout(contentWidth: width)
    let size = CGSize(width: width, height: ceil(layout.totalHeight))
    if frame.size != size {
      setFrameSize(size)
    }
    layoutThreadCards(contentWidth: width)
    notifyPreferredViewportHeightChanged()
  }

  override func draw(_ dirtyRect: NSRect) {
    guard !rows.isEmpty, let range = layout.visibleRowRange(in: dirtyRect) else { return }
    let visibleCount = range.count
    let interval =
      rows.count >= ReviewFilesPerf.renderSignpostThresholdLines
      ? ReviewFilesPerf.beginAppKitDraw(rowCount: visibleCount)
      : nil
    defer {
      if let interval {
        ReviewFilesPerf.end(interval)
      }
    }
    for index in range {
      let rowLayout =
        wrappedRowLayouts.indices.contains(index)
        ? wrappedRowLayouts[index]
        : .unwrapped(rows[index].text)
      draw(
        row: rows[index], wrappedLayout: rowLayout,
        in: layout.rowRect(index, width: bounds.width)
      )
    }
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    selectedRowID = row(at: convert(event.locationInWindow, from: nil))?.id
    needsDisplay = true
    super.mouseDown(with: event)
  }

  override func keyDown(with event: NSEvent) {
    if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
      copySelectedSourceLine()
      return
    }
    super.keyDown(with: event)
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    guard let row = row(at: convert(event.locationInWindow, from: nil)) else { return nil }
    contextMenuRowID = row.id
    selectedRowID = row.id
    needsDisplay = true
    let menu = NSMenu()
    addMenuItem("Copy Source Line", action: #selector(copyContextSourceLine), to: menu)
    addMenuItem("Copy Line Anchor", action: #selector(copyContextLineAnchor), to: menu)
    if githubPermalink(for: row) != nil {
      addMenuItem("Copy GitHub Permalink", action: #selector(copyContextPermalink), to: menu)
    }
    if let url = firstThreadURL(forRowID: row.id) {
      addMenuItem("Copy Thread URL", action: #selector(copyContextThreadURL(_:)), to: menu)
      menu.item(at: menu.items.count - 1)?.representedObject = url
    }
    menu.addItem(.separator())
    addMenuItem("Copy File Path", action: #selector(copyFilePath), to: menu)
    return menu
  }

  private func firstThreadURL(forRowID rowID: Int) -> String? {
    guard let threads = threadsByRowID[rowID] else { return nil }
    for thread in threads where thread.url != nil {
      return thread.url
    }
    return nil
  }

  func preferredViewportHeight() -> CGFloat {
    min(max(layout.totalHeight, 84), 720)
  }

  func wrappedLayout(for rowID: Int) -> DashboardReviewFileDiffWrappedRowLayout? {
    guard
      let index = rowIndexByID[rowID], wrappedRowLayouts.indices.contains(index)
    else { return nil }
    return wrappedRowLayouts[index]
  }

  private func rebuildWrappedRowLayouts(contentWidth: CGFloat) {
    wrappedRowLayouts = rows.map { row in
      let key = WrapKey(
        rowID: row.id,
        characterLimit: characterLimit(for: row, contentWidth: contentWidth),
        softWrapEnabled: softWrapEnabled
      )
      if let cached = wrappedRowCache[key] {
        return cached
      }
      let layout = DashboardReviewFileDiffWrapLayout.layout(
        row: row,
        language: codeLanguage,
        softWrapEnabled: softWrapEnabled,
        characterLimit: key.characterLimit
      )
      wrappedRowCache[key] = layout
      return layout
    }
  }

  private func characterLimit(
    for row: DashboardReviewFileDiffRow,
    contentWidth: CGFloat
  ) -> Int {
    let availableWidth: CGFloat =
      switch row.kind {
      case .addition, .context, .deletion:
        codeColumnWidth(contentWidth: contentWidth)
      case .contextGap, .hunk, .metadata:
        max(contentWidth - 24, characterWidth)
      }
    return max(Int(floor(availableWidth / characterWidth)), 1)
  }

  private func codeColumnWidth(contentWidth: CGFloat) -> CGFloat {
    switch viewMode {
    case .unified:
      return max(contentWidth - 132, characterWidth)
    case .split:
      let columnWidth = floor((contentWidth - 1) / 2)
      return max(columnWidth - 82, characterWidth)
    }
  }

  func notifyPreferredViewportHeightChanged() {
    guard let onPreferredViewportHeightChange else { return }
    let measuredHeight = preferredViewportHeight()
    DispatchQueue.main.async {
      onPreferredViewportHeightChange(measuredHeight)
    }
  }
}
