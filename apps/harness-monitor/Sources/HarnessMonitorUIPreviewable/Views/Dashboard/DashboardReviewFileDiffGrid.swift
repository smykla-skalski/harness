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
  @Environment(\.reviewLineSelectionContext)
  private var lineSelectionContext

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
      .init(
        document: document,
        viewMode: viewMode,
        fontScale: fontScale,
        softWrapEnabled: softWrapEnabled,
        threads: threads,
        repositoryFullName: repositoryFullName,
        conversation: .init(
          threads: conversation?.threads ?? [],
          visibility: conversation?.visibility ?? .all,
          viewerLogin: conversation?.viewerLogin,
          loadAvatar: conversation?.loadAvatar,
          onResolveToggle: conversation?.onResolveToggle,
          onReply: conversation?.onReply,
          onPreferredViewportHeightChange: { height in
            scrollView.invalidateIntrinsicContentSize()
            onPreferredViewportHeightChange?(height)
          }
        ),
        deepLinkID: lineSelectionContext?.deepLinkID ?? "",
        lineSelection: lineSelectionContext?.selection,
        onSelectLines: lineSelectionContext?.onSelectLines
      )
    )
    contentView.resizeForViewportWidth(scrollView.contentSize.width)
    contentView.scrollToPendingLineSelectionIfNeeded()
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
  struct ConversationConfiguration {
    var threads: [DashboardReviewFileThread] = []
    var visibility: ConversationVisibility = .all
    var viewerLogin: String?
    var loadAvatar: TimelineAvatarImageLoader?
    var onResolveToggle: ((String, Bool) async -> Void)?
    var onReply: ((String, String) async -> Bool)?
    var onPreferredViewportHeightChange: (@MainActor (CGFloat) -> Void)?
  }

  struct Configuration {
    let document: DashboardReviewFileDiffDocument
    let viewMode: FilesViewMode
    let fontScale: CGFloat
    var softWrapEnabled = true
    var threads: [DashboardReviewFileThreadAnchor] = []
    var repositoryFullName: String?
    var conversation = ConversationConfiguration()
    var deepLinkID = ""
    var lineSelection: ReviewLineSelection?
    var onSelectLines: (@MainActor (ReviewLineSelection?) -> Void)?
  }

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
  /// Content width of the last `wrappedRowLayouts` rebuild; an unchanged width
  /// skips the re-layout. `-1` forces a rebuild on the first/post-change pass.
  private var lastWrappedContentWidth: CGFloat = -1
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

  // Line-selection feature: gutter click + shift-click range, reported upward
  // via `onSelectLines` and restored from history/deep links via the incoming
  // selection. `selectionAnchorRowID`/`selectedRowID` bound the highlighted row
  // range; `selectionSide` records which diff side the line numbers belong to.
  var onSelectLines: (@MainActor (ReviewLineSelection?) -> Void)?
  var deepLinkID = ""
  var incomingLineSelection: ReviewLineSelection?
  var selectionAnchorRowID: Int?
  var selectionSide: ReviewDiffSide = .right
  var lastScrolledLineSelection: ReviewLineSelection?

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

  func configure(_ configuration: Configuration) {
    let document = configuration.document
    let conversation = configuration.conversation
    let nextFont = DashboardReviewDiffTypography.appKitFont(for: configuration.fontScale)
    let nextLanguage = HarnessCodeLanguage(reviewLanguage: document.language)
    let layoutInputsChanged =
      rows != document.rows
      || self.viewMode != configuration.viewMode
      || codeLanguage != nextLanguage
      || abs(font.pointSize - nextFont.pointSize) > 0.001
      || self.softWrapEnabled != configuration.softWrapEnabled
    rows = document.rows
    self.viewMode = configuration.viewMode
    codeLanguage = nextLanguage
    longestCodeCharacterCount = document.longestCodeCharacterCount
    self.softWrapEnabled = configuration.softWrapEnabled
    threadsByRowID = DashboardReviewFileDiffThreadMap.build(
      rows: document.rows,
      threads: conversation.threads.isEmpty
        ? configuration.threads
        : conversation.threads.map(\.anchor)
    )
    rowIndexByID = Dictionary(
      uniqueKeysWithValues: document.rows.enumerated().map { ($1.id, $0) }
    )
    threadsByID = Dictionary(conversation.threads.map { ($0.id, $0) }) { first, _ in first }
    self.conversationVisibility = conversation.visibility
    cardFontScale = configuration.fontScale
    cardViewerLogin = conversation.viewerLogin
    cardLoadAvatar = conversation.loadAvatar
    cardResolveToggle = conversation.onResolveToggle
    cardReply = conversation.onReply
    self.onPreferredViewportHeightChange = conversation.onPreferredViewportHeightChange
    selectedRowID = selectedRowID.flatMap { selected in
      document.rows.contains(where: { $0.id == selected }) ? selected : nil
    }
    documentPath = document.path
    headRefOid = document.headRefOid
    self.repositoryFullName = configuration.repositoryFullName
    font = nextFont
    typographyMetrics = DashboardReviewDiffTypography.layoutMetrics(for: font)
    rowHeight = typographyMetrics.rowHeight
    characterWidth = DashboardReviewDiffTypography.characterAdvance(for: font)
    if layoutInputsChanged {
      wrappedRowCache = [:]
      wrappedRowLayouts = []
      semanticCodeLineCache = [:]
      lastWrappedContentWidth = -1
    }
    measuredCardHeightCache = [:]
    cardHeightByRowID = [:]
    self.deepLinkID = configuration.deepLinkID
    self.onSelectLines = configuration.onSelectLines
    applyIncomingLineSelectionHighlight(configuration.lineSelection)
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
    handleSelectionClick(
      at: convert(event.locationInWindow, from: nil),
      extendingRange: event.modifierFlags.contains(.shift)
    )
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
    let point = convert(event.locationInWindow, from: nil)
    guard let row = row(at: point) else { return nil }
    // Capture the link against the pre-click selection: a context row inside an
    // active multi-row selection points at the whole range, otherwise just the
    // clicked row.
    let harnessLink = harnessDeepLink(forContextRow: row)
    let harnessLinkTitle = harnessLinkMenuTitle(forContextRow: row)
    prepareContextMenuSelection(forContextRow: row, at: point)
    let menu = NSMenu()
    addMenuItem("Copy Source Line", action: #selector(copyContextSourceLine), to: menu)
    addMenuItem("Copy Line Anchor", action: #selector(copyContextLineAnchor), to: menu)
    if let harnessLink {
      addMenuItem(harnessLinkTitle, action: #selector(copyContextHarnessLink(_:)), to: menu)
      menu.item(at: menu.items.count - 1)?.representedObject = harnessLink
    }
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

  private func rebuildWrappedRowLayouts(contentWidth: CGFloat) {
    // A resize tick with an unchanged width (the common SwiftUI re-invocation
    // from selection, hover, or thread updates) reuses the existing layouts.
    if contentWidth == lastWrappedContentWidth, wrappedRowLayouts.count == rows.count {
      return
    }
    // Bound the cross-width cache so a drag-resize across many widths cannot
    // grow it without limit; `wrappedRowLayouts` always holds the current width.
    if wrappedRowCache.count > rows.count * 2 + 128 {
      wrappedRowCache.removeAll(keepingCapacity: true)
    }
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
    lastWrappedContentWidth = contentWidth
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
      DashboardReviewFileDiffGridGeometry.unifiedCodeColumnWidth(
        contentWidth: contentWidth, characterWidth: characterWidth)
    case .split:
      DashboardReviewFileDiffGridGeometry.splitCodeColumnWidth(
        columnWidth: floor((contentWidth - 1) / 2), characterWidth: characterWidth)
    }
  }
}
