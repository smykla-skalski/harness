import SwiftUI

struct ToolbarStatusMessage: Equatable, Identifiable {
  let id: String
  let text: String
  let systemImage: String?
  let tint: Color

  init(
    id: String = UUID().uuidString,
    text: String,
    systemImage: String? = nil,
    tint: Color = .secondary
  ) {
    self.id = id
    self.text = text
    self.systemImage = systemImage
    self.tint = tint
  }
}

struct ToolbarStatusTickerToolbar: ToolbarContent {
  let messages: [ToolbarStatusMessage]

  var body: some ToolbarContent {
    ToolbarItem(placement: .automatic) {
      ToolbarStatusTickerView(messages: messages)
    }
  }
}

private struct ToolbarStatusTickerView: View {
  let messages: [ToolbarStatusMessage]
  @State private var currentIndex: Int = 0
  @State private var tickerID: String = ""
  private static let tickerHeight: CGFloat = 20
  private static let cycleInterval: TimeInterval = 4

  private var currentMessage: ToolbarStatusMessage? {
    guard !messages.isEmpty else { return nil }
    let safeIndex = currentIndex % messages.count
    return messages[safeIndex]
  }

  var body: some View {
    Group {
      if let message = currentMessage {
        HStack(spacing: 5) {
          if let systemImage = message.systemImage {
            Image(systemName: systemImage)
              .font(.caption2.weight(.semibold))
              .foregroundStyle(message.tint)
          }
          Text(message.text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .id(tickerID)
        .transition(
          .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .top).combined(with: .opacity)
          )
        )
      }
    }
    .frame(height: Self.tickerHeight)
    .clipped()
    .fixedSize(horizontal: true, vertical: false)
    .onAppear {
      tickerID = currentMessage?.id ?? ""
    }
    .task(id: messages.count) {
      guard messages.count > 1 else { return }
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(Self.cycleInterval))
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
          currentIndex = (currentIndex + 1) % messages.count
          tickerID = currentMessage?.id ?? ""
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(currentMessage?.text ?? "No status")
    .accessibilityIdentifier(HarnessMonitorAccessibility.toolbarStatusTicker)
  }
}

#Preview("Status Ticker - Cycling") {
  NavigationSplitView {
    List { Text("Sidebar") }
      .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
  } detail: {
    Text("Detail content")
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  .toolbar {
    ToolbarStatusTickerToolbar(messages: [
      .init(text: "Running Harness Monitor", systemImage: "gearshape.fill", tint: .blue),
      .init(text: "3 sessions active", systemImage: "antenna.radiowaves.left.and.right", tint: .green),
      .init(text: "Build succeeded", systemImage: "checkmark.circle.fill", tint: .green),
      .init(text: "Indexing workspace", systemImage: "magnifyingglass", tint: .orange),
    ])
  }
  .frame(width: 900, height: 400)
}

#Preview("Status Ticker - Single Message") {
  NavigationSplitView {
    List { Text("Sidebar") }
      .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
  } detail: {
    Text("Detail content")
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  .toolbar {
    ToolbarStatusTickerToolbar(messages: [
      .init(text: "Ready", systemImage: "checkmark.circle.fill", tint: .green),
    ])
  }
  .frame(width: 900, height: 400)
}
