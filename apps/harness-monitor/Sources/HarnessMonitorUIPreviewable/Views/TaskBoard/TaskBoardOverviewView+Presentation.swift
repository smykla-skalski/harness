import HarnessMonitorKit

extension TaskBoardOverviewView {
  /// Holds the board still until the typing stops. Clearing skips the wait: the
  /// board someone is asking for back is the one they already had.
  @MainActor
  func applySearchTextWhenSettled() async {
    // Whitespace alone is not a search, so it settles like a clear instead of
    // making the board sit out a wait that changes nothing. The trim belongs
    // here and not in the field's binding: stripping the space as someone
    // types it would leave them unable to type a second word.
    let pending = searchTextValue.isBlank ? "" : searchTextValue
    if !pending.isEmpty {
      try? await Task.sleep(for: .milliseconds(180))
      guard !Task.isCancelled else { return }
    }
    if appliedSearchTextValue != pending {
      appliedSearchTextValue = pending
    }
  }

  @MainActor
  func rebuildPresentation(input: TaskBoardOverviewPresentationInput) async {
    guard !Task.isCancelled else { return }
    presentationGenerationValue &+= 1
    let generation = presentationGenerationValue
    let presentation = await presentationWorkerValue.compute(input: input)
    guard !Task.isCancelled, presentationGenerationValue == generation else {
      return
    }
    if cachedPresentationValue != presentation {
      cachedPresentationValue = presentation
      selectionModelValue.updateVisibleIDs(presentation.orderedCardIDs)
    }
  }
}
