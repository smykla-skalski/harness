import HarnessMonitorKit
import SwiftUI

struct SettingsReviewsTimelinePane: View {
  private static let kindDisplayNames: [ReviewTimelineKind: String] = [
    .issueComment: "Comments",
    .review: "Reviews",
    .reviewThread: "Review threads",
    .commit: "Commits",
    .headRefForcePushed: "Force pushes",
    .headRefDeleted: "Head branch deleted",
    .headRefRestored: "Head branch restored",
    .baseRefChanged: "Base branch changed",
    .baseRefForcePushed: "Base branch force-pushed",
    .baseRefDeleted: "Base branch deleted",
    .labeled: "Label added",
    .unlabeled: "Label removed",
    .assigned: "Assigned",
    .unassigned: "Unassigned",
    .merged: "Merged",
    .closed: "Closed",
    .reopened: "Reopened",
    .renamedTitle: "Renamed title",
    .reviewRequested: "Review requested",
    .reviewRequestRemoved: "Review request removed",
    .reviewDismissed: "Review dismissed",
    .readyForReview: "Ready for review",
    .convertToDraft: "Converted to draft",
    .autoMergeEnabled: "Auto-merge enabled",
    .autoMergeDisabled: "Auto-merge disabled",
    .autoRebaseEnabled: "Auto-rebase enabled",
    .autoSquashEnabled: "Auto-squash enabled",
    .locked: "Locked",
    .unlocked: "Unlocked",
    .pinned: "Pinned",
    .unpinned: "Unpinned",
    .milestoned: "Milestoned",
    .demilestoned: "Demilestoned",
    .referenced: "Referenced",
    .crossReferenced: "Cross-referenced",
    .mentioned: "Mentioned",
    .subscribed: "Subscribed",
    .unsubscribed: "Unsubscribed",
    .markedAsDuplicate: "Marked as duplicate",
    .unmarkedAsDuplicate: "Unmarked as duplicate",
    .transferred: "Transferred",
    .connected: "Linked",
    .disconnected: "Unlinked",
    .revisionMarker: "Revision marker",
    .unknown: "Unknown event",
  ]

  let isActive: Bool
  @Binding var draft: DashboardReviewsPreferences
  // Pre-filter via `.onChange(of: hiddenKindsSearchText)` rather than
  // computing `.filter(...)` inline in ForEach: filtering O(45) every
  // body call burns work that the debounce + cached @State path avoids.
  // ForEach(filteredHiddenKinds, id: \.rawValue) keeps toggle identity
  // stable as the list grows/shrinks with the search query.
  @State private var hiddenKindsSearchText = ""
  @State private var filteredHiddenKinds: [ReviewTimelineKind] =
    ReviewTimelineKind.allCases
  @State private var hiddenKindsSearchTask: Task<Void, Never>?

  init(
    draft: Binding<DashboardReviewsPreferences>,
    isActive: Bool = true
  ) {
    self.isActive = isActive
    _draft = draft
  }

  var body: some View {
    if isActive {
      activeBody
    } else {
      Color.clear
        .onAppear {
          hiddenKindsSearchTask?.cancel()
          hiddenKindsSearchTask = nil
        }
    }
  }

  private var activeBody: some View {
    Form {
      timelineSection
      hiddenEventTypesSection
    }
    .settingsDetailFormStyle()
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsReviewsPane("timeline"))
  }

  private var timelineSection: some View {
    Section {
      Toggle("Show activity timeline", isOn: $draft.showActivityTimeline)
      Stepper(
        "Initial page size: \(draft.timelineInitialPageSize)",
        value: $draft.timelineInitialPageSize,
        in: Self.timelinePageSizeRange,
        step: 10
      )
      Stepper(
        "Load older batch size: \(draft.timelineLoadOlderBatchSize)",
        value: $draft.timelineLoadOlderBatchSize,
        in: Self.timelinePageSizeRange,
        step: 10
      )
      Toggle(
        "Auto-collapse heavy review threads",
        isOn: $draft.timelineAutoCollapseHeavyReviewThreads
      )
    } header: {
      Text("Timeline")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text(
        """
        Stepper bounds: 10–100 in 10-step increments — `Picker(10…100)` would \
        mount 91 rows on Settings open.
        """
      )
    }
  }

  private var hiddenEventTypesSection: some View {
    Section {
      TextField("Search", text: $hiddenKindsSearchText)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("Search hidden event types")
      if filteredHiddenKinds.isEmpty {
        ContentUnavailableView.search(text: hiddenKindsSearchText)
      } else {
        ForEach(filteredHiddenKinds, id: \.rawValue) { kind in
          Toggle(
            kindDisplayName(kind),
            isOn: Binding(
              get: { draft.timelineHiddenKinds.contains(kind) },
              set: { hide in
                var current = draft.timelineHiddenKinds
                if hide {
                  current.insert(kind)
                } else {
                  current.remove(kind)
                }
                draft.timelineHiddenKinds = current
              }
            )
          )
        }
      }
    } header: {
      Text("Hidden Event Types")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text("Toggle which GitHub event types appear in the review PR conversation feed.")
    }
    .onChange(of: hiddenKindsSearchText) { _, query in
      hiddenKindsSearchTask?.cancel()
      hiddenKindsSearchTask = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
          filteredHiddenKinds = ReviewTimelineKind.allCases
        } else {
          filteredHiddenKinds = ReviewTimelineKind.allCases.filter { kind in
            kindDisplayName(kind).localizedCaseInsensitiveContains(trimmed)
          }
        }
      }
    }
  }

  private func kindDisplayName(_ kind: ReviewTimelineKind) -> String {
    Self.kindDisplayNames[kind] ?? "Unknown event"
  }

  private static let timelinePageSizeRange: ClosedRange<Int> = ClosedRange(
    uncheckedBounds: (
      lower: DashboardReviewsPreferences.minimumTimelinePageSize,
      upper: DashboardReviewsPreferences.maximumTimelinePageSize
    )
  )
}
