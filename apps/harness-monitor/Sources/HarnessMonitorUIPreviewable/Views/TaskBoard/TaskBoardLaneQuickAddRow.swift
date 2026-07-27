import HarnessMonitorKit
import SwiftUI

/// The add-a-task affordance pinned under a lane's cards. Collapsed it is a
/// quiet button; opened it is a title field that stays put after each task, so
/// a run of them can be typed without going back to the full form.
struct TaskBoardLaneQuickAddRow: View {
  let lane: TaskBoardInboxLane
  let selectionModel: TaskBoardCardSelectionModel
  let actions: TaskBoardOverviewActions
  @State private var title: String
  @FocusState private var isFieldFocused: Bool
  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.taskBoardLaneAppearance)
  private var laneAppearance
  @Environment(\.colorScheme)
  private var colorScheme
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency

  /// `draftTitle` seeds the field for a static render; the board leaves it empty.
  init(
    lane: TaskBoardInboxLane,
    selectionModel: TaskBoardCardSelectionModel,
    actions: TaskBoardOverviewActions,
    draftTitle: String = ""
  ) {
    self.lane = lane
    self.selectionModel = selectionModel
    self.actions = actions
    _title = State(initialValue: draftTitle)
  }

  private var metrics: TaskBoardLaneMetrics { TaskBoardLaneMetrics(fontScale: fontScale) }
  private var isOpen: Bool { selectionModel.quickAddLane == lane }
  private var laneColor: Color { taskBoardLaneColor(for: lane, appearance: laneAppearance) }

  /// Level with the cards above it in dark, where a darker well would read as a
  /// hole punched in the lane. Light keeps the app's usual field background,
  /// which is already all but the card's own white.
  private var fieldFill: Color {
    colorScheme == .dark
      ? taskBoardCardSurfaceFill(colorScheme: colorScheme, reduceTransparency: reduceTransparency)
      : Color(nsColor: .textBackgroundColor).opacity(0.42)
  }
  private var labelFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }
  private var fieldFont: Font {
    HarnessMonitorTextSize.scaledFont(.subheadline.weight(.semibold), by: fontScale)
  }

  var body: some View {
    Group {
      if isOpen {
        titleField
      } else {
        openButton
      }
    }
    .padding(.horizontal, metrics.laneInnerPadding)
    .padding(.bottom, metrics.laneInnerPadding)
  }

  private var openButton: some View {
    Button {
      selectionModel.beginQuickAdd(in: lane)
    } label: {
      HStack(spacing: metrics.rowTextSpacing) {
        Image(systemName: "plus")
        Text("Add task")
        Spacer(minLength: 0)
      }
      .font(labelFont)
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      .padding(.horizontal, metrics.cardPadding)
      .padding(.vertical, metrics.laneSpacing)
      .contentShape(Rectangle())
    }
    .harnessPlainButtonStyle()
    .taskBoardLaneToggleFeedback(lane: lane, cornerRadius: metrics.cardCornerRadius)
    .help("Add a task to \(lane.title)")
    .accessibilityLabel("Add a task to \(lane.title)")
    .accessibilityIdentifier("harness.task-board.lane-quick-add.\(lane.rawValue)")
  }

  private var titleField: some View {
    HStack(spacing: metrics.rowTextSpacing) {
      TextField("Task title", text: $title)
        .textFieldStyle(.plain)
        .font(fieldFont)
        .foregroundStyle(HarnessMonitorTheme.ink)
        .lineLimit(1)
        .focused($isFieldFocused)
        .onSubmit(submit)
        .onKeyPress(.escape) {
          dismiss()
          return .handled
        }
        .accessibilityLabel("New task in \(lane.title)")
        .accessibilityIdentifier("harness.task-board.lane-quick-add-field.\(lane.rawValue)")
      // Escape is the fast way out, but the Edit menu can claim that key for a
      // sidebar selection, so the way out is also something to click.
      Button(action: dismiss) {
        Image(systemName: "xmark")
          .font(labelFont)
          // The glyph is small, the target must not be: 24pt is the macOS
          // minimum, and the shape makes the padding around the mark clickable
          // rather than leaving a hole the pointer can land in.
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .harnessPlainButtonStyle()
      .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
      .help("Discard this task")
      .accessibilityLabel("Discard this task")
      .accessibilityIdentifier("harness.task-board.lane-quick-add-cancel.\(lane.rawValue)")
    }
    .padding(.horizontal, metrics.cardPadding)
    .padding(.vertical, metrics.laneSpacing)
    .background {
      RoundedRectangle(cornerRadius: metrics.cardCornerRadius, style: .continuous)
        .fill(fieldFill)
    }
    .overlay {
      RoundedRectangle(cornerRadius: metrics.cardCornerRadius, style: .continuous)
        .strokeBorder(laneColor.opacity(0.5), lineWidth: 1)
    }
    .task {
      isFieldFocused = true
    }
    .onChange(of: isFieldFocused) { _, focused in
      // An empty field someone has clicked away from is clutter; one they left
      // text in is unfinished work, and closing it would throw the text away.
      if !focused, title.isBlank {
        selectionModel.endQuickAdd(in: lane)
      }
    }
  }

  /// Deliberately not gated on an action being in flight: creating a task marks
  /// the board busy for a moment, and disabling the field on its own submit is
  /// what would break typing several in a row.
  private func submit() {
    guard let request = TaskBoardLaneQuickAdd.request(title: title, lane: lane) else {
      return
    }
    title = ""
    actions.createTaskBoardItem(request)
  }

  private func dismiss() {
    title = ""
    selectionModel.endQuickAdd(in: lane)
  }
}
