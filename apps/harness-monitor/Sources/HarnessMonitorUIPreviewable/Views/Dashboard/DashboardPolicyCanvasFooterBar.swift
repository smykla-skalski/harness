import HarnessMonitorKit
import SwiftUI

struct DashboardPolicyCanvasFooterBar: View {
  let workspace: TaskBoardPolicyCanvasWorkspace?
  let selectedCanvasId: String?
  let selectedCanvas: TaskBoardPolicyCanvasSummary?
  let isCanvasMutationDisabled: Bool
  let createCanvas: @MainActor () -> Void
  let duplicateCanvas: @MainActor () -> Void
  let renameCanvas: @MainActor () -> Void
  let deleteCanvas: @MainActor () -> Void
  let selectCanvas: @MainActor (TaskBoardPolicyCanvasSummary) -> Void
  let duplicateCanvasFromTab: @MainActor (TaskBoardPolicyCanvasSummary) -> Void
  let renameCanvasFromTab: @MainActor (TaskBoardPolicyCanvasSummary) -> Void
  let deleteCanvasFromTab: @MainActor (TaskBoardPolicyCanvasSummary) -> Void

  var body: some View {
    VStack(spacing: 0) {
      Divider()

      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        tabStrip
          .frame(maxWidth: .infinity, alignment: .leading)

        Divider()
          .frame(height: 24)

        actionStrip
      }
      .padding(.horizontal, HarnessMonitorTheme.spacingMD)
      .padding(.vertical, HarnessMonitorTheme.spacingSM)
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
          HStack(spacing: HarnessMonitorTheme.spacingXS) {
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
        .scrollIndicators(.hidden)
        .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardPolicyCanvasFooterTabs)
      }
    } else {
      footerStatusLabel("Loading canvases", systemImage: "square.on.square")
    }
  }

  private var actionStrip: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Button(action: createCanvas) {
        Label("New Canvas", systemImage: "plus")
          .labelStyle(.iconOnly)
      }
      .disabled(isCanvasMutationDisabled)
      .help("Create a new policy canvas")

      Button("Duplicate", action: duplicateCanvas)
        .disabled(selectedCanvas == nil || isCanvasMutationDisabled)

      Button("Rename", action: renameCanvas)
        .disabled(selectedCanvas == nil || isCanvasMutationDisabled)

      Button("Delete", role: .destructive, action: deleteCanvas)
        .disabled(selectedCanvas == nil || isCanvasMutationDisabled)
    }
  }

  private func footerStatusLabel(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
      .scaledFont(.callout.weight(.medium))
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct DashboardPolicyCanvasFooterTab: View {
  let canvas: TaskBoardPolicyCanvasSummary
  let isSelected: Bool
  let isActive: Bool
  let select: @MainActor () -> Void

  var body: some View {
    Button(action: select) {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        if isActive {
          Circle()
            .fill(Color.accentColor)
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
        }

        Text(canvas.title)
          .font(.callout.weight(isSelected ? .semibold : .medium))
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .padding(.horizontal, 10)
      .frame(height: 28)
      .frame(maxWidth: 190)
      .contentShape(Rectangle())
    }
    .harnessPlainButtonStyle()
    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
    .background {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06))
    }
    .overlay {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(
          isSelected ? Color.accentColor.opacity(0.38) : Color.primary.opacity(0.08),
          lineWidth: 1
        )
    }
    .help(helpText)
    .accessibilityLabel(canvas.title)
    .accessibilityValue(accessibilityValue)
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
