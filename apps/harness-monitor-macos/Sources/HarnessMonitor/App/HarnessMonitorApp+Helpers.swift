import AppKit
import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

extension HarnessMonitorApp {
  func handleOpenFolder(_ result: Result<[URL], any Error>) async {
    let record = await appStore.handleImportedFolder(result)
    HarnessMonitorLogger.swiftui.info(
      "Open folder importer handling finished: bookmarked=\((record != nil), privacy: .public)"
    )
  }

  func increaseTextSize() {
    guard HarnessMonitorTextSize.canIncrease(textSizeIndex) else {
      return
    }
    textSizeIndex += 1
  }

  func decreaseTextSize() {
    guard HarnessMonitorTextSize.canDecrease(textSizeIndex) else {
      return
    }
    textSizeIndex -= 1
  }

  func resetTextSize() {
    textSizeIndex = HarnessMonitorTextSize.defaultIndex
  }

  func refreshStore() {
    Task {
      await appStore.manualRefresh()
    }
  }

  func presentOpenFolder() {
    HarnessMonitorLogger.swiftui.info(
      "Presenting open folder importer: token=\(appStore.openFolderRequest, privacy: .public)"
    )
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "Open"
    panel.message = "Select a project folder"
    let parent = NSApp.keyWindow ?? NSApp.mainWindow
    let store = appStore
    let completion: @Sendable (NSApplication.ModalResponse) -> Void = { [store] response in
      Task { @MainActor in
        let result: Result<[URL], any Error> =
          response == .OK ? .success(panel.urls) : .success([])
        let record = await store.handleImportedFolder(result)
        HarnessMonitorLogger.swiftui.info(
          "Open folder importer handling finished: bookmarked=\((record != nil), privacy: .public)"
        )
      }
    }
    if let parent {
      panel.beginSheetModal(for: parent, completionHandler: completion)
    } else {
      panel.begin(completionHandler: completion)
    }
  }
}
