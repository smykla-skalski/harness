import HarnessMonitorKit
import SwiftUI

/// Lightweight app-owned suggestion popover for the native toolbar search.
public struct AppSearchSuggestionsView: View {
  let snapshot: AppSearchSuggestionSnapshot
  let onPick: (AppSearchHit) -> Void

  public init(
    snapshot: AppSearchSuggestionSnapshot,
    onPick: @escaping (AppSearchHit) -> Void
  ) {
    self.snapshot = snapshot
    self.onPick = onPick
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(snapshot.rows) { row in
        Button {
          onPick(row.hit)
        } label: {
          Text(verbatim: row.displayTitle)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .harnessPlainButtonStyle()
        .accessibilityLabel(row.displayTitle)
      }
    }
    .padding(.vertical, 4)
    .frame(width: 320, alignment: .leading)
    .background(.background, in: .rect(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(.quaternary, lineWidth: 1)
    }
  }
}
