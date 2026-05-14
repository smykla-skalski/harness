import SwiftUI

extension PolicyCanvasViewModel {
  /// Update the highlighted group in response to a palette-item hover. Sets
  /// `highlightedGroupID` to the group when entering, clears it on exit.
  /// `dropPalettePayloads(...)` runs first on drop and replaces the highlight
  /// with the new node's selection, so we don't need to coordinate clearing
  /// past the drop frame.
  func setGroupDropTargeted(_ targeted: Bool, groupID: String) {
    if targeted {
      highlightedGroupID = groupID
    } else if highlightedGroupID == groupID {
      highlightedGroupID = nil
    }
  }
}
