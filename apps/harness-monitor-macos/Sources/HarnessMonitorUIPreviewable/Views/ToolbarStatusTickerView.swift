import HarnessMonitorKit
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

extension ToolbarStatusMessage {
  init(_ state: HarnessMonitorStore.StatusMessageState) {
    self.init(
      id: state.id,
      text: state.text,
      systemImage: state.systemImage,
      tint: state.tone.color
    )
  }
}

extension HarnessMonitorStore.StatusMessageTone {
  fileprivate var color: Color {
    switch self {
    case .secondary:
      .secondary
    case .info:
      .blue
    case .success:
      .green
    case .caution:
      .orange
    }
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

struct ToolbarStatusTickerCapsule<TrailingAccessory: View>: View {
  let messages: [ToolbarStatusMessage]
  let trailingAccessory: TrailingAccessory
  private let contentHorizontalInset: CGFloat = 12

  init(
    messages: [ToolbarStatusMessage],
    @ViewBuilder trailingAccessory: () -> TrailingAccessory
  ) {
    self.messages = messages
    self.trailingAccessory = trailingAccessory()
  }

  var body: some View {
    HStack(spacing: 8) {
      Spacer(minLength: 0)
      ToolbarStatusTickerView(messages: messages, direction: .up)
        .lineLimit(1)
        .truncationMode(.tail)
      trailingAccessory
    }
    .accessibilityFrameMarker(HarnessMonitorAccessibility.toolbarStatusTickerContentFrame)
    .padding(.horizontal, contentHorizontalInset)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    ZStack(alignment: .trailing) {
      if let message = currentMessage {
        tickerLabel(message)
          .id(message.id)
          .transition(.push(from: direction.pushEdge))
      }
    }
    .frame(height: Self.tickerHeight)
    .clipped()
    .task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(cycleInterval))
        guard !Task.isCancelled, messages.count > 1 else { continue }
        withAnimation(.easeInOut(duration: 0.25)) {
          currentIndex = (currentIndex + 1) % messages.count
        }
      }
    }
    .onChange(of: messages.count) { _, newCount in
      if currentIndex >= newCount {
        currentIndex = 0
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(currentMessage?.text ?? "No status")
  }

  private func tickerLabel(_ message: ToolbarStatusMessage) -> some View {
    Text(message.text)
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .lineLimit(1)
  }
}

#Preview("Ticker - Split Flap Up") {
  VStack(spacing: 24) {
    ToolbarStatusTickerView(
      messages: [
        .init(text: "Running Harness Monitor", systemImage: "gearshape.fill", tint: .blue),
        .init(
          text: "3 sessions active", systemImage: "antenna.radiowaves.left.and.right", tint: .green),
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
