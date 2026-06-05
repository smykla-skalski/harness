import HarnessMonitorCore
import HarnessMonitorMirrorStore
import SwiftUI
import WidgetKit

struct RootView: View {
  @Environment(MirrorStore.self)
  private var store
  @State private var pendingAttention: MobileAttentionItem?
  @State private var pendingCancellation: MobileCommandRecord?
  @State private var pendingRetry: MobileCommandRecord?
  @State private var composerPresented = false
  @Namespace private var reviewZoom
  @Namespace private var sessionZoom

  var body: some View {
    @Bindable var store = store
    NavigationStack {
      navigationList
        .refreshable {
          await store.refresh()
        }
        .task {
          WidgetCenter.shared.reloadAllTimelines()
          await store.load()
        }
        .task {
          await store.runForegroundRefreshLoop()
        }
        .confirmationDialog(
          pendingAttention?.commandKind?.title ?? "Confirm",
          isPresented: Binding(
            get: { pendingAttention != nil },
            set: { if !$0 { pendingAttention = nil } }
          ),
          titleVisibility: .visible
        ) {
          Button("Confirm") {
            guard let pendingAttention else {
              return
            }
            Task {
              await store.queueCommand(from: pendingAttention)
              self.pendingAttention = nil
            }
          }
          Button("Cancel", role: .cancel) {
            pendingAttention = nil
          }
        } message: {
          Text(pendingAttention?.confirmationMessage ?? "")
        }
        .confirmationDialog(
          "Retry Command",
          isPresented: Binding(
            get: { pendingRetry != nil },
            set: { if !$0 { pendingRetry = nil } }
          ),
          titleVisibility: .visible
        ) {
          Button("Retry") {
            guard let pendingRetry else {
              return
            }
            Task {
              await store.retry(pendingRetry)
              self.pendingRetry = nil
            }
          }
          Button("Cancel", role: .cancel) {
            pendingRetry = nil
          }
        } message: {
          Text(pendingRetry?.confirmationText ?? "")
        }
        .confirmationDialog(
          "Cancel Command",
          isPresented: Binding(
            get: { pendingCancellation != nil },
            set: { if !$0 { pendingCancellation = nil } }
          ),
          titleVisibility: .visible
        ) {
          Button("Cancel Command", role: .destructive) {
            guard let pendingCancellation else {
              return
            }
            Task {
              await store.cancel(pendingCancellation)
              self.pendingCancellation = nil
            }
          }
          Button("Keep Queued", role: .cancel) {
            pendingCancellation = nil
          }
        } message: {
          Text(pendingCancellation?.confirmationText ?? "")
        }
        .sheet(isPresented: $composerPresented) {
          NavigationStack {
            WatchCommandComposerView(store: store, initialStationID: store.selectedStationID)
          }
        }
        .alert("Authentication failed", isPresented: $store.lastAuthenticationFailed) {
          Button("OK", role: .cancel) {}
        }
    }
  }

  @ViewBuilder private var navigationList: some View {
    List {
      statusSection
      needsYouSection
      reviewsSection
      liveWorkSection
      commandsSection
    }
    .navigationTitle("Harness")
    .navigationDestination(for: WatchReviewDetailRoute.self) { route in
      WatchReviewDetailView(reviewID: route.reviewID, sourceID: route.sourceID, zoom: reviewZoom)
    }
    .navigationDestination(for: WatchSessionDetailRoute.self) { route in
      WatchSessionDetailView(
        sessionID: route.sessionID, sourceID: route.sourceID, zoom: sessionZoom)
    }
  }

  @ViewBuilder private var statusSection: some View {
    Section {
      WatchStatusRow(status: store.syncStatus)
    }
  }

  @ViewBuilder private var needsYouSection: some View {
    Section("Needs you") {
      if store.snapshot.sortedAttention.isEmpty {
        Label("Clear", systemImage: "checkmark.circle")
      } else {
        ForEach(store.snapshot.sortedAttention.prefix(6)) { item in
          attentionRow(item)
        }
      }
    }
  }

  @ViewBuilder private var reviewsSection: some View {
    Section("Reviews") {
      let reviews = store.reviewsForSelectedStation
      if reviews.isEmpty {
        Label("No reviews", systemImage: "checkmark.seal")
      } else {
        ForEach(reviews.prefix(6)) { review in
          reviewRow(review)
        }
      }
    }
  }

  @ViewBuilder private var liveWorkSection: some View {
    Section("Live Work") {
      if store.sessionsForSelectedStation.isEmpty && store.taskBoardForSelectedStation.isEmpty {
        Label("No active work", systemImage: "tray")
      } else {
        ForEach(store.sessionsForSelectedStation.prefix(3)) { session in
          WatchSessionRow(session: session)
        }
        ForEach(store.taskBoardForSelectedStation.prefix(4)) { item in
          WatchTaskBoardRow(item: item)
        }
      }
    }
  }

  @ViewBuilder private var commandsSection: some View {
    @Bindable var store = store
    Section("Commands") {
      Button {
        composerPresented = true
      } label: {
        Label("New Command", systemImage: "plus.circle")
      }
      .disabled(store.snapshot.stations.isEmpty)
      if store.snapshot.stations.count > 1 {
        Picker("Station", selection: $store.selectedStationID) {
          ForEach(store.snapshot.stations) { station in
            Text(station.displayName).tag(station.id)
          }
        }
      }
      ForEach(store.commandsForSelectedStation.prefix(4)) { command in
        WatchCommandRow(
          command: command,
          retry: {
            pendingRetry = command
          },
          cancel: {
            pendingCancellation = command
          }
        )
      }
    }
  }

  @ViewBuilder
  private func attentionRow(_ item: MobileAttentionItem) -> some View {
    if let reviewID = item.navigableReviewID(in: store.snapshot.reviews) {
      NavigationLink(
        value: WatchReviewDetailRoute(reviewID: reviewID, sourceID: "attn-review-\(reviewID)")
      ) {
        WatchAttentionRow(item: item, canSubmit: false, submit: {})
      }
      .matchedTransitionSource(id: "attn-review-\(reviewID)", in: reviewZoom)
    } else if let sessionID = item.navigableSessionID(in: store.snapshot.sessions) {
      NavigationLink(
        value: WatchSessionDetailRoute(sessionID: sessionID, sourceID: "session-\(item.id)")
      ) {
        WatchAttentionRow(item: item, canSubmit: false, submit: {})
      }
      .matchedTransitionSource(id: "session-\(item.id)", in: sessionZoom)
    } else {
      WatchAttentionRow(
        item: item,
        canSubmit: store.canQueueCommand(stationID: item.stationID)
      ) {
        pendingAttention = item
      }
    }
  }

  @ViewBuilder
  private func reviewRow(_ review: MobileReviewSummary) -> some View {
    NavigationLink(
      value: WatchReviewDetailRoute(reviewID: review.id, sourceID: "list-review-\(review.id)")
    ) {
      WatchReviewRow(review: review)
    }
    .matchedTransitionSource(id: "list-review-\(review.id)", in: reviewZoom)
  }
}

#Preview {
  RootView()
    .environment(MirrorStore(demoModeEnabled: true, profile: .watch))
}
