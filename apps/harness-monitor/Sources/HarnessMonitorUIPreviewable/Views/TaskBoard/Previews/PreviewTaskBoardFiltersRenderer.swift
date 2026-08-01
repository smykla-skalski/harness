import AppKit
import SwiftUI

/// Shell snapshots for the board's filter surfaces.
public enum TaskBoardFilterPreviewRenderer {
  @MainActor
  public static func dump(toDirectory directory: String) -> Bool {
    do {
      try FileManager.default.createDirectory(
        atPath: directory,
        withIntermediateDirectories: true
      )
    } catch {
      return false
    }

    let defaultIndex = HarnessMonitorTextSize.defaultIndex
    let largestIndex = HarnessMonitorTextSize.scales.count - 1
    return renderFilterSurfaces(
      textSizeIndex: defaultIndex,
      largestTextSizeIndex: largestIndex,
      directory: directory
    )
      && renderSearchSurfaces(
        textSizeIndex: defaultIndex,
        largestTextSizeIndex: largestIndex,
        directory: directory
      )
  }

  @MainActor
  private static func renderFilterSurfaces(
    textSizeIndex: Int,
    largestTextSizeIndex: Int,
    directory: String
  ) -> Bool {
    return render(
      name: "filter-bar-idle",
      size: NSSize(width: 900, height: 120),
      textSizeIndex: textSizeIndex,
      directory: directory
    ) {
      TaskBoardFilterBarPreview(filters: TaskBoardFilterState())
    }
      && render(
        name: "filter-bar-active",
        size: NSSize(width: 900, height: 160),
        textSizeIndex: textSizeIndex,
        directory: directory
      ) {
        TaskBoardFilterBarPreview(filters: TaskBoardFilterPreviewFixtures.narrowedFilters)
      }
      && render(
        name: "filter-bar-active-largest-text",
        size: NSSize(width: 900, height: 260),
        textSizeIndex: largestTextSizeIndex,
        directory: directory
      ) {
        TaskBoardFilterBarPreview(filters: TaskBoardFilterPreviewFixtures.narrowedFilters)
      }
      && render(
        name: "filter-project-dropdown",
        size: NSSize(width: 340, height: 160),
        textSizeIndex: textSizeIndex,
        directory: directory
      ) {
        TaskBoardFacetFilterOptionsPreview(
          facet: .project,
          filters: TaskBoardFilterPreviewFixtures.narrowedFilters
        )
      }
      && render(
        name: "filter-priority-dropdown",
        size: NSSize(width: 340, height: 184),
        textSizeIndex: textSizeIndex,
        directory: directory
      ) {
        TaskBoardFacetFilterOptionsPreview(
          facet: .priority,
          filters: TaskBoardFilterPreviewFixtures.narrowedFilters
        )
      }
      && render(
        name: "filter-popover",
        size: NSSize(width: 420, height: 400),
        textSizeIndex: textSizeIndex,
        directory: directory
      ) {
        TaskBoardFilterPopoverPreview(filters: TaskBoardFilterPreviewFixtures.narrowedFilters)
      }
      && render(
        name: "filter-popover-largest-text",
        size: NSSize(width: 500, height: 520),
        textSizeIndex: largestTextSizeIndex,
        directory: directory
      ) {
        TaskBoardFilterPopoverPreview(filters: TaskBoardFilterPreviewFixtures.narrowedFilters)
      }
      && render(
        name: "filter-empty-state",
        size: NSSize(width: 640, height: 260),
        textSizeIndex: textSizeIndex,
        directory: directory
      ) {
        TaskBoardFilterEmptyStatePreview()
      }
  }

  @MainActor
  private static func renderSearchSurfaces(
    textSizeIndex: Int,
    largestTextSizeIndex: Int,
    directory: String
  ) -> Bool {
    render(
      name: "search-field-idle",
      size: NSSize(width: 420, height: 100),
      textSizeIndex: textSizeIndex,
      directory: directory
    ) {
      TaskBoardSearchFieldPreview(searchText: "")
    }
      && render(
        name: "search-suggestions",
        size: NSSize(width: 420, height: 260),
        textSizeIndex: textSizeIndex,
        directory: directory
      ) {
        TaskBoardSearchFieldPreview(searchText: "polcy", showsSuggestions: true)
      }
      && render(
        name: "search-suggestions-largest-text",
        size: NSSize(width: 520, height: 340),
        textSizeIndex: largestTextSizeIndex,
        directory: directory
      ) {
        TaskBoardSearchFieldPreview(searchText: "polcy", showsSuggestions: true)
      }
      && render(
        name: "search-with-filters",
        size: NSSize(width: 980, height: 170),
        textSizeIndex: textSizeIndex,
        directory: directory
      ) {
        TaskBoardFilterBarPreview(
          filters: TaskBoardFilterPreviewFixtures.narrowedFilters,
          searchText: "policy"
        )
      }
      && renderEmptyStates(textSizeIndex: textSizeIndex, directory: directory)
  }

  @MainActor
  private static func renderEmptyStates(textSizeIndex: Int, directory: String) -> Bool {
    render(
      name: "search-empty-state",
      size: NSSize(width: 640, height: 260),
      textSizeIndex: textSizeIndex,
      directory: directory
    ) {
      TaskBoardFilterEmptyStatePreview(
        filters: TaskBoardFilterState(),
        searchText: "nothing here"
      )
    }
      && render(
        name: "search-and-filter-empty-state",
        size: NSSize(width: 680, height: 280),
        textSizeIndex: textSizeIndex,
        directory: directory
      ) {
        TaskBoardFilterEmptyStatePreview(
          filters: TaskBoardFilterPreviewFixtures.searchEmptyingFilters,
          searchText: "zone"
        )
      }
  }

  @MainActor
  private static func render<Content: View>(
    name: String,
    size: NSSize,
    textSizeIndex: Int,
    directory: String,
    @ViewBuilder content: () -> Content
  ) -> Bool {
    let hosted =
      content()
      .padding(HarnessMonitorTheme.spacingLG)
      .frame(width: size.width, height: size.height, alignment: .topLeading)
      // Stands in for the board's own chrome. Without it the capture is
      // transparent, and every unselected chip and secondary label reads as
      // invisible against whatever the viewer composites it onto.
      .background(Color(nsColor: .windowBackgroundColor))
      .harnessPreviewSceneAppearance(textSizeIndex: textSizeIndex)
    let view = NSHostingView(rootView: hosted)
    // Theme colors are asset-backed, so they resolve against the view's own
    // appearance and not the scene modifier alone.
    view.appearance = NSAppearance(named: .darkAqua)
    view.setFrameSize(size)
    view.layoutSubtreeIfNeeded()

    guard
      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else {
      return false
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else {
      return false
    }

    do {
      try data.write(
        to: URL(fileURLWithPath: directory)
          .appendingPathComponent(name)
          .appendingPathExtension("png"),
        options: .atomic
      )
      return true
    } catch {
      return false
    }
  }
}
