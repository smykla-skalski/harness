import Foundation
import SwiftUI

enum DashboardOCRIntakeMessage: Equatable {
  case success(String)
  case failure(String)

  var text: String {
    switch self {
    case .success(let text), .failure(let text):
      text
    }
  }

  var tint: Color {
    switch self {
    case .success:
      HarnessMonitorTheme.success
    case .failure:
      HarnessMonitorTheme.danger
    }
  }

  var systemImage: String {
    switch self {
    case .success:
      "checkmark.circle"
    case .failure:
      "exclamationmark.triangle"
    }
  }
}

struct DashboardOCRIntakeMessageView: View {
  let message: DashboardOCRIntakeMessage

  var body: some View {
    Label(message.text, systemImage: message.systemImage)
      .scaledFont(.caption.weight(.semibold))
      .foregroundStyle(message.tint)
      .padding(.horizontal, HarnessMonitorTheme.spacingMD)
      .padding(.vertical, HarnessMonitorTheme.spacingSM)
      .background(message.tint.opacity(0.08), in: Capsule())
  }
}

struct DashboardOCRPasteFeedback: Identifiable, Equatable {
  let id = UUID()
  let count: Int

  var text: String {
    "Pasted \(count) \(count == 1 ? "image" : "images")"
  }
}

struct DashboardOCRPasteFeedbackView: View {
  let feedback: DashboardOCRPasteFeedback

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "doc.on.clipboard.fill")
        .font(.system(size: 15, weight: .bold))
        .symbolEffect(
          .bounce.up.wholeSymbol,
          options: .speed(1.35),
          value: feedback.id
        )
      Text(feedback.text)
        .scaledFont(.caption.weight(.bold))
    }
    .foregroundStyle(HarnessMonitorTheme.success)
    .padding(.horizontal, HarnessMonitorTheme.spacingLG)
    .padding(.vertical, HarnessMonitorTheme.spacingMD)
    .background(HarnessMonitorTheme.success.opacity(0.17), in: Capsule())
    .overlay {
      Capsule()
        .strokeBorder(HarnessMonitorTheme.success.opacity(0.52), lineWidth: 1)
    }
    .shadow(color: HarnessMonitorTheme.success.opacity(0.18), radius: 18, y: 8)
    .shadow(color: .black.opacity(0.22), radius: 14, y: 7)
    .accessibilityLabel(feedback.text)
  }
}

struct DashboardOCRDropZone: View {
  let isTargeted: Bool

  var body: some View {
    VStack(spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "photo.stack")
        .font(.system(size: 34, weight: .semibold))
        .foregroundStyle(isTargeted ? HarnessMonitorTheme.accent : HarnessMonitorTheme.secondaryInk)
      Text(isTargeted ? "Release Images" : "Drop Images")
        .scaledFont(.headline.weight(.semibold))
      Text("PNG, JPEG, TIFF, HEIC")
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .frame(maxWidth: .infinity, minHeight: 190)
    .background {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .fill(HarnessMonitorTheme.ink.opacity(isTargeted ? 0.07 : 0.03))
    }
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .strokeBorder(
          isTargeted ? HarnessMonitorTheme.accent : HarnessMonitorTheme.controlBorder,
          style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])
        )
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDebuggingOCRDropZone)
  }
}
