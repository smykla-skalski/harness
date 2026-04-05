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

enum ToolbarTickerDirection {
  case up
  case down

  var pushEdge: Edge {
    switch self {
    case .up:
      .bottom
    case .down:
      .top
    }
  }
}

struct ToolbarStatusTickerView: View {
  let messages: [ToolbarStatusMessage]
  var direction: ToolbarTickerDirection = .up
  var cycleInterval: TimeInterval = 4
  @State private var currentIndex: Int = 0
  private static let tickerHeight: CGFloat = 16

  private var currentMessage: ToolbarStatusMessage? {
    guard !messages.isEmpty else { return nil }
    let safeIndex = currentIndex % messages.count
    return messages[safeIndex]
  }

  var body: some View {
    ZStack {
      if let message = currentMessage {
        HStack(spacing: 5) {
          Text(message.text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          if let systemImage = message.systemImage {
            Image(systemName: systemImage)
              .font(.caption2.weight(.semibold))
              .foregroundStyle(message.tint)
          }
        }
        .id(message.id)
        .transition(.push(from: direction.pushEdge))
      }
    }
    .frame(height: Self.tickerHeight)
    .clipped()
    .fixedSize(horizontal: true, vertical: false)
    .task(id: messages.count) {
      guard messages.count > 1 else { return }
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(cycleInterval))
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
          currentIndex = (currentIndex + 1) % messages.count
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(currentMessage?.text ?? "No status")
    .accessibilityIdentifier(HarnessMonitorAccessibility.toolbarStatusTicker)
  }
}

#Preview("Ticker - Split Flap Up") {
  VStack(spacing: 24) {
    ToolbarStatusTickerView(
      messages: [
        .init(text: "Running Harness Monitor", systemImage: "gearshape.fill", tint: .blue),
        .init(text: "3 sessions active", systemImage: "antenna.radiowaves.left.and.right", tint: .green),
        .init(text: "Build succeeded", systemImage: "checkmark.circle.fill", tint: .green),
        .init(text: "Indexing workspace", systemImage: "magnifyingglass", tint: .orange),
      ],
      direction: .up,
      cycleInterval: 2
    )
    .background(.quaternary, in: Capsule())

    ToolbarStatusTickerView(
      messages: [
        .init(text: "Scrolling down", systemImage: "arrow.down", tint: .blue),
        .init(text: "Next message", systemImage: "text.bubble", tint: .green),
        .init(text: "Third entry", systemImage: "3.circle", tint: .orange),
      ],
      direction: .down,
      cycleInterval: 2
    )
    .background(.quaternary, in: Capsule())
  }
  .padding(24)
}
