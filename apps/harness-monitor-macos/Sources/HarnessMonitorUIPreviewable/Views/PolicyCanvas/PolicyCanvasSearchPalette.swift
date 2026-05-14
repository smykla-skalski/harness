import SwiftUI

/// Cmd+F search overlay for the canvas. Lives above the workspace, takes
/// keyboard focus on appear, and routes selection through the view model's
/// view-state path (no document mutation, no autosave trigger). Rendered by
/// `PolicyCanvasView` only when `searchPaletteVisible` is true.
///
/// State ownership:
/// - `query`, `recentHits`, `selectedHitIndex` are pure UI state owned by
///   this view. They do not flow through `PolicyCanvasChange` (3H's funnel)
///   because the palette never edits the document — it only navigates the
///   user's selection on an existing graph.
/// - Search hits are recomputed on every keystroke through a debounced
///   `.task(id: query)` so a fast typist gets one engine call per pause,
///   not per character. Empty queries skip the engine entirely (the
///   "recent" path takes over).
struct PolicyCanvasSearchPalette: View {
  let viewModel: PolicyCanvasViewModel
  @Binding var isVisible: Bool

  @State private var query: String = ""
  @State private var hits: [PolicyCanvasSearchHit] = []
  @State private var selectedHitIndex: Int = 0
  @State private var recentHits: [PolicyCanvasSearchHit] = []
  @FocusState private var queryFieldFocused: Bool

  private let engine = PolicyCanvasSearchEngine()

  /// Debounce window for keystroke-driven searches. 100ms balances responsive
  /// feedback against engine churn during a fast typist's burst — at 80ms a
  /// `qwerty`-rate typist (~5cps) still emits one engine call per pause; at
  /// 120ms the perceived lag starts to read on the eye.
  private static let debounceMillis: UInt64 = 100

  /// Maximum number of recent hits surfaced when the query is empty. Three
  /// keeps the empty-state list short enough to scan at a glance without
  /// pushing the palette taller than the typical Cmd+F search bar.
  private static let recentLimit: Int = 3

  /// Maximum number of hits rendered in the list. The engine returns every
  /// hit; the palette caps the rendered count so a wildcard-like query on a
  /// 200-node graph doesn't paint a 200-row list.
  private static let renderLimit: Int = 25

  var body: some View {
    VStack(spacing: 0) {
      searchField

      Divider()
        .background(Color.white.opacity(0.07))

      resultsList
    }
    .frame(width: 360)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(Color(red: 0.10, green: 0.11, blue: 0.14))
    )
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color.white.opacity(0.12), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.45), radius: 14, x: 0, y: 8)
    .padding(.top, 14)
    .padding(.trailing, 14)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasSearchPalette)
    .onAppear {
      queryFieldFocused = true
    }
    .task(id: query) {
      await runDebouncedSearch()
    }
  }

  // MARK: - Subviews

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.white.opacity(0.68))

      TextField("Find in policy canvas", text: $query)
        .textFieldStyle(.plain)
        .scaledFont(.callout)
        .foregroundStyle(.white)
        .focused($queryFieldFocused)
        .onSubmit {
          commitSelection()
        }
        .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasSearchField)

      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.white.opacity(0.55))
      }
      .keyboardShortcut(.escape, modifiers: [])
      .harnessPlainButtonStyle()
      .help("Close (Esc)")
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasSearchDismissButton)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  @ViewBuilder private var resultsList: some View {
    let activeHits = currentHits
    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      if activeHits.isEmpty {
        emptyRecentState
      } else {
        listBody(activeHits, header: "Recent")
      }
    } else if activeHits.isEmpty {
      noMatchState
    } else {
      listBody(activeHits, header: nil)
    }
  }

  private var emptyRecentState: some View {
    Text("Start typing to find nodes, edges, or groups.")
      .scaledFont(.caption)
      .foregroundStyle(.white.opacity(0.62))
      .padding(.horizontal, 12)
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasSearchEmptyHint)
  }

  private var noMatchState: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("No matches for \"\(query)\"")
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(.white.opacity(0.86))
      Text("Press Esc to close")
        .scaledFont(.caption2)
        .foregroundStyle(.white.opacity(0.5))
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasSearchNoMatch)
  }

  private func listBody(_ hits: [PolicyCanvasSearchHit], header: String?) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      if let header {
        Text(header)
          .scaledFont(.caption2.weight(.semibold))
          .foregroundStyle(.white.opacity(0.55))
          .padding(.horizontal, 12)
          .padding(.top, 8)
          .padding(.bottom, 4)
      }
      ForEach(
        Array(hits.prefix(Self.renderLimit).enumerated()),
        id: \.element.sortKey
      ) { offset, hit in
        PolicyCanvasSearchPaletteRow(
          hit: hit,
          isHighlighted: offset == selectedHitIndex,
          select: {
            selectedHitIndex = offset
            commit(hit: hit)
          }
        )
      }
    }
    .padding(.bottom, 8)
  }

  // MARK: - Effects

  private func runDebouncedSearch() async {
    do {
      try await Task.sleep(nanoseconds: Self.debounceMillis * 1_000_000)
    } catch {
      return
    }
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      hits = []
      selectedHitIndex = 0
      return
    }
    let next = engine.search(
      query: trimmed,
      nodes: searchableNodes(),
      edges: searchableEdges(),
      groups: searchableGroups()
    )
    hits = next
    selectedHitIndex = next.isEmpty ? 0 : 0
  }

  private var currentHits: [PolicyCanvasSearchHit] {
    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return recentHits
    }
    return hits
  }

  private func commitSelection() {
    let active = currentHits
    guard !active.isEmpty, selectedHitIndex < active.count else {
      return
    }
    commit(hit: active[selectedHitIndex])
  }

  private func commit(hit: PolicyCanvasSearchHit) {
    let selection: PolicyCanvasSelection
    switch hit {
    case .node(let id, _, _, _):
      selection = .node(id)
    case .edge(let id, _, _, _):
      selection = .edge(id)
    case .group(let id, _, _, _):
      selection = .group(id)
    }
    viewModel.select(selection)
    recordRecent(hit)
    dismiss()
  }

  private func recordRecent(_ hit: PolicyCanvasSearchHit) {
    var next = recentHits.filter { $0.sortKey != hit.sortKey }
    next.insert(hit, at: 0)
    if next.count > Self.recentLimit {
      next.removeLast(next.count - Self.recentLimit)
    }
    recentHits = next
  }

  private func dismiss() {
    isVisible = false
  }

  // MARK: - Searchable projections

  private func searchableNodes() -> [PolicyCanvasSearchableNode] {
    viewModel.nodes.map { node in
      PolicyCanvasSearchableNode(
        id: node.id,
        title: node.title,
        kindName: node.kind.title
      )
    }
  }

  private func searchableEdges() -> [PolicyCanvasSearchableEdge] {
    viewModel.edges.map { edge in
      PolicyCanvasSearchableEdge(id: edge.id, label: edge.label)
    }
  }

  private func searchableGroups() -> [PolicyCanvasSearchableGroup] {
    viewModel.groups.map { group in
      PolicyCanvasSearchableGroup(id: group.id, title: group.title)
    }
  }
}

/// Single row in the palette result list. Renders the hit's display title
/// with the matched substring highlighted, a small kind icon, and a chevron
/// affordance on the trailing edge. Tap or Return commits the selection.
private struct PolicyCanvasSearchPaletteRow: View {
  let hit: PolicyCanvasSearchHit
  let isHighlighted: Bool
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      HStack(spacing: 10) {
        Image(systemName: iconName)
          .foregroundStyle(iconTint)
          .frame(width: 18)

        VStack(alignment: .leading, spacing: 2) {
          highlightedTitle
          Text(typeLabel)
            .scaledFont(.caption2)
            .foregroundStyle(.white.opacity(0.45))
        }

        Spacer(minLength: 0)

        Image(systemName: "return")
          .scaledFont(.caption2)
          .foregroundStyle(.white.opacity(isHighlighted ? 0.55 : 0.0))
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(isHighlighted ? Color.cyan.opacity(0.18) : Color.clear)
          .padding(.horizontal, 6)
      )
    }
    .harnessPlainButtonStyle()
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasSearchResult(hit.sortKey))
  }

  /// Render the title with the matched substring tinted. Uses
  /// `AttributedString` rather than `Text + Text` because the latter is
  /// deprecated on macOS 26. The default tint covers the whole title; the
  /// match range gets a foreground override. When `matchedRange` is nil
  /// (kind-name match or folded-length-changed title) the entire string
  /// stays at the default tint.
  private var highlightedTitle: some View {
    let title = hit.displayTitle
    var attributed = AttributedString(title)
    attributed.foregroundColor = .white
    if let range = matchedRange(in: title),
      let attributedRange = Range(range, in: attributed)
    {
      attributed[attributedRange].foregroundColor = .yellow
    }
    return Text(attributed)
      .scaledFont(.callout)
      .lineLimit(1)
  }

  /// Map the engine's match range (computed against the diacritic-folded
  /// title) onto the original title for display. The folded copy preserves
  /// UTF-16 indices for the alphabetic characters this engine targets, so
  /// the same `Range<String.Index>` describes the same characters in both
  /// strings as long as the folded copy and original have the same length —
  /// which is the case for `.diacriticInsensitive` folding on Latin-script
  /// titles. For titles that do change length under folding (rare in this
  /// app's policy domain), the highlight is skipped rather than risking an
  /// index mismatch.
  private func matchedRange(in title: String) -> Range<String.Index>? {
    switch hit {
    case .node(_, _, let range, _),
      .edge(_, _, let range, _),
      .group(_, _, let range, _):
      guard let range else {
        return nil
      }
      let folded = title.folding(options: .diacriticInsensitive, locale: nil)
      guard folded.count == title.count else {
        return nil
      }
      return range
    }
  }

  private var iconName: String {
    switch hit {
    case .node:
      return "circle.grid.cross"
    case .edge:
      return "arrow.right"
    case .group:
      return "rectangle.dashed"
    }
  }

  private var iconTint: Color {
    switch hit {
    case .node:
      return .cyan
    case .edge:
      return .orange
    case .group:
      return .purple
    }
  }

  private var typeLabel: String {
    switch hit {
    case .node:
      return "Node"
    case .edge:
      return "Edge"
    case .group:
      return "Group"
    }
  }
}
