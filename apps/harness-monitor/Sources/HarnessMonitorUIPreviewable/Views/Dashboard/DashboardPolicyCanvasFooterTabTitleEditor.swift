import SwiftUI

struct DashboardPolicyCanvasFooterTabTitleEditor: View {
  let title: String
  let maxWidth: CGFloat
  let horizontalPadding: CGFloat
  let accessibilityIdentifier: String
  let submit: @MainActor (String) -> Void
  let cancel: @MainActor () -> Void

  @FocusState private var isTitleFieldFocused: Bool
  @State private var draftTitle: String

  init(
    title: String,
    maxWidth: CGFloat,
    horizontalPadding: CGFloat,
    accessibilityIdentifier: String,
    submit: @escaping @MainActor (String) -> Void,
    cancel: @escaping @MainActor () -> Void
  ) {
    self.title = title
    self.maxWidth = maxWidth
    self.horizontalPadding = horizontalPadding
    self.accessibilityIdentifier = accessibilityIdentifier
    self.submit = submit
    self.cancel = cancel
    _draftTitle = State(initialValue: title)
  }

  var body: some View {
    titleReserve
      .opacity(0)
      .overlay(alignment: .leading) {
        titleField
      }
      .clipped()
      .task {
        draftTitle = title
        isTitleFieldFocused = true
      }
  }

  private var titleReserve: some View {
    Text(title)
      .font(.callout.weight(.medium))
      .lineLimit(1)
      .truncationMode(.tail)
      .padding(.horizontal, horizontalPadding)
      .frame(maxWidth: maxWidth, alignment: .leading)
      .frame(maxHeight: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .accessibilityHidden(true)
  }

  private var titleField: some View {
    TextField("Canvas title", text: $draftTitle)
      .textFieldStyle(.plain)
      .font(.callout.weight(.medium))
      .lineLimit(1)
      .padding(.horizontal, horizontalPadding)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      .focused($isTitleFieldFocused)
      .accessibilityLabel("Canvas title")
      .accessibilityIdentifier(accessibilityIdentifier)
      .onSubmit(submitDraft)
      .onKeyPress(.escape) {
        draftTitle = title
        cancel()
        return .handled
      }
  }

  @MainActor
  private func submitDraft() {
    let trimmedTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else {
      return
    }
    submit(trimmedTitle)
  }
}
