import HarnessMonitorCloudKit
import SwiftUI
import WidgetKit

struct RootView: View {
  @State private var state: LoadState = .loading

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          headerCard
          deepLinkNote
          footnote
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
      }
      .navigationTitle("Harness")
    }
    .task {
      WidgetCenter.shared.reloadAllTimelines()
      await refresh()
    }
  }

  private var headerCard: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Needs you")
            .font(.caption2)
            .foregroundStyle(.secondary)
          Text(countLabel)
            .font(.system(.title, design: .rounded, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(countColor)
        }
        Spacer()
        Image(systemName: countSymbol)
          .font(.title3)
          .foregroundStyle(countSymbolColor)
      }
      Divider()
      Text(statusLine)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(.thinMaterial)
    )
  }

  private var deepLinkNote: some View {
    Label {
      Text("Add the Needs-Me complication to a watch face for at-a-glance access.")
        .font(.caption2)
    } icon: {
      Image(systemName: "applewatch.watchface")
    }
    .foregroundStyle(.secondary)
  }

  private var footnote: some View {
    Text("Review pull requests on your Mac. Counts sync via iCloud.")
      .font(.caption2)
      .foregroundStyle(.tertiary)
  }

  private var countLabel: String {
    switch state {
    case .loading: return "--"
    case .loaded(let snapshot): return String(snapshot.count)
    case .empty: return "0"
    case .notAuthenticated: return "--"
    case .offline(let cached): return cached.map { String($0.count) } ?? "--"
    case .unknownError(let cached): return cached.map { String($0.count) } ?? "--"
    }
  }

  private var countColor: Color {
    switch state {
    case .loaded, .empty:
      return .primary
    case .offline(.some), .unknownError(.some):
      return .secondary
    case .loading, .notAuthenticated, .offline, .unknownError:
      return .secondary
    }
  }

  private var countSymbol: String {
    switch state {
    case .loading: return "ellipsis.circle"
    case .loaded, .empty: return "checkmark.icloud"
    case .notAuthenticated: return "icloud.slash"
    case .offline: return "wifi.slash"
    case .unknownError: return "exclamationmark.triangle"
    }
  }

  private var countSymbolColor: Color {
    switch state {
    case .loaded, .empty: return .primary
    case .loading: return .secondary
    case .notAuthenticated, .offline, .unknownError: return .orange
    }
  }

  private var statusLine: String {
    switch state {
    case .loading:
      return "Syncing…"
    case .loaded(let snapshot):
      return "Synced \(snapshot.updatedAt.formatted(.relative(presentation: .numeric)))"
    case .empty:
      return "No data yet — open the Mac app once."
    case .notAuthenticated:
      return "Sign in to iCloud on your iPhone, then reopen this app."
    case .offline(let cached):
      if let cached {
        return
          "Offline · last sync \(cached.updatedAt.formatted(.relative(presentation: .numeric)))"
      }
      return "Offline · connect to Wi-Fi to sync."
    case .unknownError(let cached):
      if let cached {
        return
          "Sync failed · cached value from \(cached.updatedAt.formatted(.relative(presentation: .numeric)))"
      }
      return "Sync failed · will retry shortly."
    }
  }

  private func refresh() async {
    let store = NeedsMeCloudKitStore.shared
    do {
      if let snapshot = try await store.fetchCurrent() {
        state = .loaded(snapshot)
      } else if let cached = await store.lastKnown() {
        state = .loaded(cached)
      } else {
        state = .empty
      }
      WidgetCenter.shared.reloadAllTimelines()
    } catch NeedsMeCloudKitError.notAuthenticated {
      state = .notAuthenticated
    } catch NeedsMeCloudKitError.networkUnavailable {
      let cached = await store.lastKnown()
      state = .offline(cached)
    } catch {
      let cached = await store.lastKnown()
      state = .unknownError(cached)
    }
  }
}

private enum LoadState {
  case loading
  case loaded(NeedsMeSnapshot)
  case empty
  case notAuthenticated
  case offline(NeedsMeSnapshot?)
  case unknownError(NeedsMeSnapshot?)
}

#Preview {
  RootView()
}
