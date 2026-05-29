import SwiftUI

enum PolicyCanvasEdgeLegendDefaults {
  static let isVisibleKey = "policyCanvas.edgeLegend.isVisible"
  static let isVisibleDefault = true
}

/// Three-row legend explaining how edge stroke color + dash pattern map to
/// the semantic kind (`.flow` / `.control` / `.error`). Closes nielsen H6
/// "recognition rather than recall" - sighted users no longer have to
/// memorize the color/dash mapping or hover every edge to learn it.
///
/// The legend sits as a viewport overlay aligned with the zoom controls and
/// shortcut disclosure (per the canvas chrome convention). It floats above
/// the viewport scrollview so it stays visible regardless of pan/zoom, and
/// it can be collapsed via the disclosure header when the user wants the
/// full canvas area.
struct PolicyCanvasEdgeKindLegend: View {
  @AppStorage(PolicyCanvasEdgeLegendDefaults.isVisibleKey)
  private var isVisible = PolicyCanvasEdgeLegendDefaults.isVisibleDefault
  @Environment(\.colorScheme)
  private var colorScheme
  /// Persist the disclosure state per session so a returning user does
  /// not have to re-collapse the legend on every launch. Nielsen H8
  /// (aesthetic & minimalist) — for a user who has internalized the
  /// color/dash mapping, an always-expanded legend is irrelevant chrome.
  /// First launch keeps the legend visible so the mapping is learnable;
  /// subsequent launches honor the user's last choice.
  @SceneStorage("policyCanvas.edgeLegend.isExpanded")
  private var isExpanded: Bool = false

  var body: some View {
    if isVisible {
      VStack(alignment: .leading, spacing: 0) {
        header
        if isExpanded {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(PolicyCanvasEdgeKind.allCases, id: \.self) { kind in
              row(for: kind)
            }
          }
          .padding(.horizontal, 10)
          .padding(.bottom, 8)
          .transition(.opacity.combined(with: .move(edge: .top)))
        }
      }
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(PolicyCanvasVisualStyle.floatingControlBackground(colorScheme))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(PolicyCanvasVisualStyle.floatingControlBorder(colorScheme), lineWidth: 1)
      )
      .frame(width: 168)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Edge legend")
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasEdgeLegend)
    }
  }

  private var header: some View {
    Button {
      withAnimation(.easeInOut(duration: 0.18)) {
        isExpanded.toggle()
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "scribble")
          .imageScale(.small)
          .foregroundStyle(.secondary)
        Text("Edges")
          .scaledFont(.caption.weight(.semibold))
          .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
        Spacer(minLength: 0)
        Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
          .imageScale(.small)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .frame(minHeight: PolicyCanvasVisualStyle.floatingControlMinHeight)
      .contentShape(Rectangle())
    }
    .harnessPlainButtonStyle()
    .accessibilityLabel(isExpanded ? "Hide edge legend" : "Show edge legend")
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasEdgeLegendToggle)
  }

  private func row(for kind: PolicyCanvasEdgeKind) -> some View {
    HStack(spacing: 8) {
      swatch(for: kind)
      Text(label(for: kind))
        .scaledFont(.caption2)
        .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isStaticText)
    // Split label + value so VoiceOver announces two semantic slots
    // ("flow", "solid") instead of one compound string. Matches how
    // the edge stroke pairs `accessibilityLabel = name` with
    // `accessibilityValue = kind word` - the legend now follows the
    // same shape.
    .accessibilityLabel(kind.accessibilityWord)
    .accessibilityValue(kind.dashDescription)
  }

  private func swatch(for kind: PolicyCanvasEdgeKind) -> some View {
    PolicyCanvasEdgeLegendSwatch(kind: kind)
      .frame(width: 32, height: 6)
  }

  /// Visible legend label. Sentence-case kind name paired with the same
  /// `dashDescription` vocabulary the hover tooltip and VoiceOver use, so
  /// sighted users learn the same words AT users hear.
  private func label(for kind: PolicyCanvasEdgeKind) -> String {
    let kindName = kind.accessibilityWord.capitalized
    return "\(kindName) · \(kind.dashDescription)"
  }
}

/// Single-row dashed swatch that mirrors the production stroke for a given
/// kind. Renders the kind's accent color with the kind's `strokeDashPattern`
/// so the legend stays in sync with the canvas - bumping a kind's color or
/// pattern in `PolicyCanvasEdgeKind` reflects here automatically.
private struct PolicyCanvasEdgeLegendSwatch: View {
  let kind: PolicyCanvasEdgeKind

  var body: some View {
    Canvas { context, size in
      var path = Path()
      path.move(to: CGPoint(x: 0, y: size.height / 2))
      path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
      context.stroke(
        path,
        with: .color(kind.accentColor),
        style: StrokeStyle(
          lineWidth: 2,
          lineCap: .round,
          lineJoin: .round,
          dash: kind.strokeDashPattern
        )
      )
    }
  }
}
