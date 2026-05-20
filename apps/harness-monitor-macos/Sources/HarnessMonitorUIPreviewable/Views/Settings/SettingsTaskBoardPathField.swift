import AppKit
import HarnessMonitorKit
import SwiftUI

struct TaskBoardSettingsPathFieldConfig {
  let title: String
  let accessibilityIdentifier: String
  let bookmarkKind: BookmarkStore.Record.Kind
  let allowsDirectories: Bool
  let allowsFiles: Bool

  static func directory(
    title: String,
    accessibilityIdentifier: String
  ) -> Self {
    Self(
      title: title,
      accessibilityIdentifier: accessibilityIdentifier,
      bookmarkKind: .taskBoardDirectory,
      allowsDirectories: true,
      allowsFiles: false
    )
  }

  static func keyFile(
    title: String,
    accessibilityIdentifier: String
  ) -> Self {
    Self(
      title: title,
      accessibilityIdentifier: accessibilityIdentifier,
      bookmarkKind: .taskBoardKeyFile,
      allowsDirectories: false,
      allowsFiles: true
    )
  }
}

extension SettingsTaskBoardEditingSurface {
  @ViewBuilder
  func pathField(
    _ config: TaskBoardSettingsPathFieldConfig,
    text: Binding<String>
  ) -> some View {
    LabeledContent(config.title) {
      HStack(alignment: .center, spacing: HarnessMonitorTheme.itemSpacing) {
        TextField(config.title, text: text)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier(config.accessibilityIdentifier)
        Button("Choose...") {
          guard let url = selectPath(config) else { return }
          if config.bookmarkKind == .taskBoardKeyFile {
            let decision = SettingsTaskBoardKeyFilePermissionGuard.evaluate(
              url: url,
              fileName: config.title
            )
            if case .cancelled = decision {
              return
            }
          }
          Task { @MainActor in
            do {
              text.wrappedValue = try await store.authorizeTaskBoardPath(
                url,
                kind: config.bookmarkKind
              )
            } catch {
              store.presentFailureFeedback(
                "Could not authorize \(config.title.lowercased()): \(error.localizedDescription)"
              )
            }
          }
        }
      }
    }
  }

  @MainActor
  func selectPath(_ config: TaskBoardSettingsPathFieldConfig) -> URL? {
    let panel = NSOpenPanel()
    panel.prompt = "Choose"
    panel.message = config.title
    panel.canChooseDirectories = config.allowsDirectories
    panel.canChooseFiles = config.allowsFiles
    panel.canCreateDirectories = config.allowsDirectories
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    guard panel.runModal() == .OK else {
      return nil
    }
    return panel.url
  }
}
