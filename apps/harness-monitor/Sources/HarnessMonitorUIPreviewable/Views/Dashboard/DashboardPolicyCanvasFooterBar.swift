import AppKit
import HarnessMonitorKit
import SwiftUI

struct DashboardPolicyCanvasFooterBar: View {
  @ScaledMetric(relativeTo: .callout)
  private var footerBarHeight = 44.0

  let workspace: TaskBoardPolicyCanvasWorkspace?
  let selectedCanvasId: String?
  let isCanvasMutationDisabled: Bool
  let createCanvas: @MainActor () -> Void
  let selectCanvas: @MainActor (TaskBoardPolicyCanvasSummary) -> Void
  let duplicateCanvasFromTab: @MainActor (TaskBoardPolicyCanvasSummary) -> Void
  let renameCanvasFromTab: @MainActor (TaskBoardPolicyCanvasSummary) -> Void
  let deleteCanvasFromTab: @MainActor (TaskBoardPolicyCanvasSummary) -> Void

  var body: some View {
    VStack(spacing: 0) {
      Divider()

      HStack(spacing: 0) {
        tabStrip
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

        Divider()
          .frame(maxHeight: .infinity)

        createCanvasButton
          .padding(.leading, HarnessMonitorTheme.spacingMD)
      }
      .padding(.horizontal, HarnessMonitorTheme.spacingMD)
      .frame(height: footerBarHeight)
    }
    .background(.background)
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder private var tabStrip: some View {
    if let workspace {
      if workspace.canvases.isEmpty {
        footerStatusLabel("No canvases", systemImage: "square.dashed")
      } else {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 0) {
            ForEach(workspace.canvases) { canvas in
              DashboardPolicyCanvasFooterTab(
                canvas: canvas,
                isSelected: canvas.canvasId == (selectedCanvasId ?? workspace.activeCanvasId),
                isActive: canvas.canvasId == workspace.activeCanvasId,
                select: { selectCanvas(canvas) }
              )
              .contextMenu {
                Button("Duplicate") {
                  duplicateCanvasFromTab(canvas)
                }
                .disabled(isCanvasMutationDisabled)

                Button("Rename") {
                  renameCanvasFromTab(canvas)
                }
                .disabled(isCanvasMutationDisabled)

                Divider()

                Button("Delete", role: .destructive) {
                  deleteCanvasFromTab(canvas)
                }
                .disabled(isCanvasMutationDisabled)
              }
            }
          }
        }
        .frame(maxHeight: .infinity, alignment: .leading)
        .scrollIndicators(.hidden)
        .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardPolicyCanvasFooterTabs)
      }
    } else {
      footerStatusLabel("Loading canvases", systemImage: "square.on.square")
    }
  }

  private var createCanvasButton: some View {
    Button(action: createCanvas) {
      Label("New Canvas", systemImage: "plus")
        .labelStyle(.iconOnly)
    }
    .disabled(isCanvasMutationDisabled)
    .help("Create a new policy canvas")
  }

  private func footerStatusLabel(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
      .scaledFont(.callout.weight(.medium))
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
  }
}

private struct DashboardPolicyCanvasFooterTab: View {
  @ScaledMetric(relativeTo: .callout)
  private var tabHorizontalPadding = 14.0
  @ScaledMetric(relativeTo: .callout)
  private var tabMaxWidth = 220.0

  let canvas: TaskBoardPolicyCanvasSummary
  let isSelected: Bool
  let isActive: Bool
  let select: @MainActor () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: select) {
      Text(canvas.title)
        .font(.callout.weight(.medium))
        .lineLimit(1)
        .truncationMode(.tail)
      .padding(.horizontal, tabHorizontalPadding)
      .frame(maxWidth: tabMaxWidth, alignment: .leading)
      .frame(maxHeight: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(
      DashboardPolicyCanvasFooterTabButtonStyle(
        isSelected: isSelected,
        isHovering: isHovering
      )
    )
    .frame(maxHeight: .infinity)
    .foregroundStyle(.primary)
    .help(helpText)
    .accessibilityLabel(canvas.title)
    .accessibilityValue(accessibilityValue)
    .onHover { hovering in
      updateHoverState(hovering)
    }
    .onDisappear {
      guard isHovering else { return }
      NSCursor.pop()
      isHovering = false
    }
  }

  private var helpText: String {
    "\(canvas.title) - \(metadataText)"
  }

  private var accessibilityValue: String {
    var parts: [String] = []
    if isActive {
      parts.append("Active")
    }
    if isSelected {
      parts.append("Selected")
    }
    parts.append(metadataText)
    return parts.joined(separator: ", ")
  }

  private var metadataText: String {
    var parts = [
      "revision \(canvas.revision)",
      "\(canvas.nodeCount) nodes",
      "\(canvas.groupCount) groups",
    ]
    if let latestSimulationSucceeded = canvas.latestSimulationSucceeded {
      if latestSimulationSucceeded {
        parts.append("latest simulation passed")
      } else {
        parts.append("latest simulation found issues")
      }
    }
    return parts.joined(separator: ", ")
  }

  private func updateHoverState(_ hovering: Bool) {
    guard isHovering != hovering else { return }
    isHovering = hovering
    if hovering {
      NSCursor.pointingHand.push()
    } else {
      NSCursor.pop()
    }
  }
}

private struct DashboardPolicyCanvasFooterTabButtonStyle: ButtonStyle {
  let isSelected: Bool
  let isHovering: Bool

  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  private var borderWidth: CGFloat {
    colorSchemeContrast == .increased ? 2 : 1
  }

  private var separatorColor: Color {
    if isSelected {
      return Color.accentColor.opacity(colorSchemeContrast == .increased ? 0.34 : 0.24)
    }
    return HarnessMonitorTheme.controlBorder.opacity(
      colorSchemeContrast == .increased ? 0.96 : 0.76
    )
  }

  private func backgroundColor(isPressed: Bool) -> Color {
    if isSelected {
      return Color.accentColor.opacity(isPressed ? 0.22 : (isHovering ? 0.18 : 0.14))
    }
    if isHovering {
      return HarnessMonitorTheme.secondaryInk.opacity(isPressed ? 0.12 : 0.08)
    }
    if isPressed {
      return HarnessMonitorTheme.secondaryInk.opacity(0.06)
    }
    return .clear
  }

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .frame(maxHeight: .infinity, alignment: .leading)
      .background {
        Rectangle()
          .fill(backgroundColor(isPressed: configuration.isPressed))
      }
      .overlay(alignment: .trailing) {
        Rectangle()
          .fill(separatorColor)
          .frame(width: borderWidth)
      }
      .contentShape(Rectangle())
      .opacity(configuration.isPressed ? 0.97 : 1)
  }
}

struct DashboardPolicyCanvasNameSheet: View {
  let request: DashboardPolicyCanvasNameRequest
  let onSubmit: @MainActor (String) -> Void

  @Environment(\.dismiss)
  private var dismiss
  @FocusState private var titleFieldFocused: Bool
  @State private var draftTitle: String

  init(
    request: DashboardPolicyCanvasNameRequest,
    onSubmit: @escaping @MainActor (String) -> Void
  ) {
    self.request = request
    self.onSubmit = onSubmit
    _draftTitle = State(initialValue: request.initialTitle)
  }

  private var trimmedTitle: String {
    draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      Text(request.title)
        .font(.title3.weight(.semibold))

      Text(request.message)
        .foregroundStyle(.secondary)

      TextField("Canvas title", text: $draftTitle)
        .textFieldStyle(.roundedBorder)
        .focused($titleFieldFocused)
        .onSubmit(submit)

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) {
          dismiss()
        }
        Button(request.actionTitle, action: submit)
          .keyboardShortcut(.defaultAction)
          .disabled(trimmedTitle.isEmpty)
      }
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(width: 360)
    .task {
      titleFieldFocused = true
    }
  }

  @MainActor
  private func submit() {
    guard !trimmedTitle.isEmpty else {
      return
    }
    onSubmit(trimmedTitle)
    dismiss()
  }
}

struct DashboardPolicyCanvasNameRequest: Identifiable {
  enum Mode {
    case create
    case duplicate(source: TaskBoardPolicyCanvasSummary)
    case rename(canvas: TaskBoardPolicyCanvasSummary)
  }

  let id = UUID()
  let mode: Mode
  let initialTitle: String

  static func create(initialTitle: String) -> Self {
    Self(mode: .create, initialTitle: initialTitle)
  }

  static func duplicate(
    source: TaskBoardPolicyCanvasSummary,
    initialTitle: String
  ) -> Self {
    Self(mode: .duplicate(source: source), initialTitle: initialTitle)
  }

  static func rename(
    canvas: TaskBoardPolicyCanvasSummary,
    initialTitle: String
  ) -> Self {
    Self(mode: .rename(canvas: canvas), initialTitle: initialTitle)
  }

  var title: String {
    switch mode {
    case .create:
      "Create Canvas"
    case .duplicate:
      "Duplicate Canvas"
    case .rename:
      "Rename Canvas"
    }
  }

  var message: String {
    switch mode {
    case .create:
      "Choose a name for the new policy canvas."
    case .duplicate(let source):
      "Create a copy of “\(source.title)” with a new canvas name."
    case .rename(let canvas):
      "Update the display name for “\(canvas.title)”."
    }
  }

  var actionTitle: String {
    switch mode {
    case .create:
      "Create"
    case .duplicate:
      "Duplicate"
    case .rename:
      "Rename"
    }
  }
}
