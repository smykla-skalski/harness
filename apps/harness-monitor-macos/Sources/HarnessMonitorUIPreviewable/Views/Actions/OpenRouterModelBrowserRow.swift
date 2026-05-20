import HarnessMonitorKit
import SwiftUI

struct OpenRouterModelBrowserRow: View, Equatable {
  let model: OpenRouterModelEntry
  let isPinned: Bool
  let onTogglePin: () -> Void
  let onSelect: () -> Void

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.isPinned == rhs.isPinned
      && lhs.model.id == rhs.model.id
      && lhs.model.name == rhs.model.name
      && lhs.model.contextLength == rhs.model.contextLength
  }

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingMD) {
      VStack(alignment: .leading, spacing: 2) {
        Text(model.name ?? model.id)
          .scaledFont(.body.weight(.semibold))
        Text(model.id)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        if let context = model.contextLength {
          Text("Context: \(context.formatted()) tokens")
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
      }
      Spacer()
      pinButton
      Button("Select", action: onSelect)
        .controlSize(.small)
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
  }

  private var pinButton: some View {
    Button(action: onTogglePin) {
      Image(systemName: isPinned ? "pin.fill" : "pin")
        .foregroundStyle(isPinned ? HarnessMonitorTheme.accent : HarnessMonitorTheme.secondaryInk)
    }
    .harnessPlainButtonStyle()
    .help(isPinned ? "Unpin model" : "Pin model")
    .accessibilityLabel(isPinned ? "Unpin \(model.id)" : "Pin \(model.id)")
  }
}

struct OpenRouterBrowserProviderChip: View, Equatable {
  let label: String
  let isSelected: Bool
  let action: () -> Void

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.isSelected == rhs.isSelected && lhs.label == rhs.label
  }

  var body: some View {
    Button(action: action) {
      Text(label)
        .scaledFont(.caption)
        .padding(.horizontal, HarnessMonitorTheme.spacingSM)
        .padding(.vertical, 4)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(isSelected ? HarnessMonitorTheme.accent.opacity(0.18) : Color.clear)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .stroke(
              isSelected
                ? HarnessMonitorTheme.accent : HarnessMonitorTheme.secondaryInk.opacity(0.3),
              lineWidth: 0.5
            )
        )
    }
    .harnessPlainButtonStyle()
  }
}
