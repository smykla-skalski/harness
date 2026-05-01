import HarnessMonitorKit
import SwiftUI

enum MCPStatusViewSupport {
  static func tint(for tone: HarnessMonitorMCPStatusSnapshot.Tone) -> Color {
    switch tone {
    case .secondary:
      .secondary
    case .info:
      .blue
    case .success:
      HarnessMonitorTheme.success
    case .caution:
      HarnessMonitorTheme.caution
    }
  }
}

struct MCPStatusLabel: View {
  enum Variant {
    case detail
    case toolbar
  }

  let status: HarnessMonitorMCPStatusSnapshot
  let variant: Variant

  private var tint: Color {
    MCPStatusViewSupport.tint(for: status.tone)
  }

  private var text: String {
    switch variant {
    case .detail:
      status.title
    case .toolbar:
      status.toolbarLabel
    }
  }

  var body: some View {
    Label(text, systemImage: status.symbolName)
      .scaledFont(font)
      .foregroundStyle(tint)
      .lineLimit(1)
  }

  private var font: Font {
    switch variant {
    case .detail:
      .body.weight(.medium)
    case .toolbar:
      .caption.weight(.semibold)
    }
  }
}
