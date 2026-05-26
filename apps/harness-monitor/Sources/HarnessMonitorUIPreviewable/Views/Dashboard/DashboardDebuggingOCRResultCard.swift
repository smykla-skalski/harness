import AppKit
import SwiftUI

struct DashboardOCRResultCard: View {
  let item: DashboardOCRImageItem
  let isHighlighted: Bool
  let onPreviewImage: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingLG) {
      imagePreview
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        titleRow
        if let sourceDetail = item.sourceDetail {
          Text(sourceDetail)
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        recognizedTextView
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .background {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .fill(HarnessMonitorTheme.ink.opacity(0.035))
    }
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .strokeBorder(borderTint, lineWidth: isHighlighted ? 2 : 1)
    }
    .shadow(
      color: isHighlighted ? HarnessMonitorTheme.success.opacity(0.18) : .clear,
      radius: isHighlighted ? 14 : 0,
      y: isHighlighted ? 6 : 0
    )
    .animation(.easeOut(duration: 0.22), value: isHighlighted)
  }

  private var borderTint: Color {
    isHighlighted
      ? HarnessMonitorTheme.success.opacity(0.72)
      : HarnessMonitorTheme.controlBorder.opacity(0.36)
  }

  private var imagePreview: some View {
    Button(action: onPreviewImage) {
      Image(nsImage: item.image)
        .resizable()
        .scaledToFit()
        .frame(width: 132, height: 96)
        .background(HarnessMonitorTheme.ink.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM))
        .overlay {
          RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM)
            .strokeBorder(HarnessMonitorTheme.controlBorder.opacity(0.32), lineWidth: 1)
        }
    }
    .harnessPlainButtonStyle()
    .help("Preview full size")
    .accessibilityLabel("Preview \(item.sourceName)")
  }

  private var titleRow: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
      Text(item.sourceName)
        .scaledFont(.headline.weight(.semibold))
        .lineLimit(1)
        .truncationMode(.middle)
      DashboardOCRStatusBadge(status: item.status)
      Spacer()
      if !item.recognizedText.isEmpty {
        Button {
          HarnessMonitorClipboard.copy(item.recognizedText)
        } label: {
          Label("Copy", systemImage: "doc.on.clipboard")
        }
        .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
        .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      }
    }
  }

  @ViewBuilder private var recognizedTextView: some View {
    switch item.status {
    case .pending, .recognizing:
      ProgressView()
        .controlSize(.small)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
    case .recognized:
      Text(item.recognizedText)
        .scaledFont(.caption.monospaced())
        .textSelection(.enabled)
        .padding(HarnessMonitorTheme.spacingMD)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(HarnessMonitorTheme.ink.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM))
    case .empty:
      ContentUnavailableView("No text found", systemImage: "text.viewfinder")
        .frame(maxWidth: .infinity, minHeight: 96)
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle")
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.danger)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
    }
  }
}

private struct DashboardOCRStatusBadge: View {
  let status: DashboardOCRStatus

  var body: some View {
    Text(status.label)
      .scaledFont(.caption.weight(.bold))
      .foregroundStyle(tint)
      .harnessPillPadding()
      .background(tint.opacity(0.09), in: Capsule())
      .overlay {
        Capsule().strokeBorder(tint.opacity(0.32), lineWidth: 1)
      }
  }

  private var tint: Color {
    switch status {
    case .pending, .recognizing:
      HarnessMonitorTheme.secondaryInk
    case .recognized:
      HarnessMonitorTheme.success
    case .empty:
      HarnessMonitorTheme.caution
    case .failed:
      HarnessMonitorTheme.danger
    }
  }
}
