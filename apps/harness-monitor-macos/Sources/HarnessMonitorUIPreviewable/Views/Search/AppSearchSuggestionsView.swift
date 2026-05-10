import HarnessMonitorKit
import SwiftUI

/// Sectioned popover content rendered inside `.searchSuggestions { … }`.
///
/// Each row is a `Button`; Return and click both run `onPick`. The
/// host wires `onPick` to a single route + clear-query + dismiss pass
/// so the per-route list filter drops back to its unfiltered state
/// after drilling into a hit.
public struct AppSearchSuggestionsView: View {
  let results: AppSearchResults
  let onPick: (AppSearchHit) -> Void

  public init(
    results: AppSearchResults,
    onPick: @escaping (AppSearchHit) -> Void
  ) {
    self.results = results
    self.onPick = onPick
  }

  public var body: some View {
    ForEach(results.sections) { section in
      Section {
        ForEach(section.hits) { hit in
          row(for: hit)
        }
      } header: {
        sectionHeader(section)
      }
    }
  }

  private func row(for hit: AppSearchHit) -> some View {
    Button {
      onPick(hit)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: hit.systemImage)
          .foregroundStyle(.secondary)
          .frame(width: 18)
        VStack(alignment: .leading, spacing: 1) {
          Text(hit.title)
          if let subtitle = hit.subtitle, !subtitle.isEmpty {
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private func sectionHeader(_ section: AppSearchSection) -> some View {
    HStack(spacing: 6) {
      Text(section.domain.label)
      if section.truncated {
        Spacer(minLength: 4)
        Text("Top \(section.hits.count)")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }
}
