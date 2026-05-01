@preconcurrency import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

private enum ScreenshotDefaults {
  static let usage = "screenshot [--window-id id] [--display-id id] [--include-cursor]"
}

private enum ScreenshotTarget {
  case explicitWindows([CGWindowID], preferredDisplayID: CGDirectDisplayID?)
  case mainDisplay
  case display(CGDirectDisplayID)
}

private struct ScreenshotArguments {
  let windowIDs: [CGWindowID]
  let displayID: CGDirectDisplayID?
  let includeCursor: Bool

  init(_ args: [String]) throws {
    var windowIDs: [CGWindowID] = []
    var displayID: CGDirectDisplayID?
    var includeCursor = false
    var index = 0
    while index < args.count {
      switch args[index] {
      case "--window-id":
        guard index + 1 < args.count else {
          throw InputToolError.usage(ScreenshotDefaults.usage)
        }
        guard let parsed = UInt32(args[index + 1]) else {
          throw InputToolError.invalidNumber(args[index + 1])
        }
        windowIDs.append(parsed)
        index += 2
      case "--display-id":
        guard index + 1 < args.count else {
          throw InputToolError.usage(ScreenshotDefaults.usage)
        }
        guard let parsed = UInt32(args[index + 1]) else {
          throw InputToolError.invalidNumber(args[index + 1])
        }
        displayID = parsed
        index += 2
      case "--include-cursor":
        includeCursor = true
        index += 1
      default:
        throw InputToolError.usage("unknown flag: \(args[index])")
      }
    }

    self.windowIDs = windowIDs
    self.displayID = displayID
    self.includeCursor = includeCursor
  }

  var target: ScreenshotTarget {
    if !windowIDs.isEmpty {
      .explicitWindows(windowIDs, preferredDisplayID: displayID)
    } else if let displayID {
      .display(displayID)
    } else {
      .mainDisplay
    }
  }
}

private struct ResolvedScreenshotTarget {
  let filter: SCContentFilter
  let info: SCShareableContentInfo
}

private struct ShareableWindowList: Codable {
  let windowIDs: [CGWindowID]
}

func handleScreenshot(_ args: [String]) async throws {
  let arguments = try ScreenshotArguments(args)
  await prepareScreenCaptureApplicationContext()
  guard CGPreflightScreenCaptureAccess() else {
    throw InputToolError.screenCaptureDenied
  }
  let resolved = try await resolveScreenshotTarget(arguments.target)
  let configuration = screenshotConfiguration(for: resolved.info, includeCursor: arguments.includeCursor)
  let image = try await captureScreenshotImage(filter: resolved.filter, configuration: configuration)
  let png = try pngData(for: image)
  FileHandle.standardOutput.write(png)
}

func handleListShareableWindows(_ args: [String]) async throws {
  guard args.isEmpty else {
    throw InputToolError.usage("list-shareable-windows")
  }
  await prepareScreenCaptureApplicationContext()
  guard CGPreflightScreenCaptureAccess() else {
    throw InputToolError.screenCaptureDenied
  }
  let shareableContent = try await shareableContent()
  let payload = ShareableWindowList(windowIDs: harnessMonitorWindows(in: shareableContent).map(\.windowID))
  let data = try JSONEncoder().encode(payload)
  FileHandle.standardOutput.write(data)
}

@MainActor
private func prepareScreenCaptureApplicationContext() {
  _ = NSApplication.shared
  NSApp.setActivationPolicy(.prohibited)
}

private func resolveScreenshotTarget(_ target: ScreenshotTarget) async throws -> ResolvedScreenshotTarget {
  let shareableContent = try await shareableContent()
  switch target {
  case .explicitWindows(let windowIDs, let preferredDisplayID):
    return try resolveExplicitWindowCapture(
      windowIDs: windowIDs,
      preferredDisplayID: preferredDisplayID,
      in: shareableContent
    )
  case .display(let displayID):
    return try resolveApplicationWindowCapture(in: shareableContent, preferredDisplayID: displayID)
  case .mainDisplay:
    return try resolveApplicationWindowCapture(in: shareableContent, preferredDisplayID: nil)
  }
}

private func shareableContent() async throws -> SCShareableContent {
  do {
    return try await SCShareableContent.current
  } catch {
    throw mappedScreenshotError(error)
  }
}

private func resolveApplicationWindowCapture(
  in shareableContent: SCShareableContent,
  preferredDisplayID: CGDirectDisplayID?
) throws -> ResolvedScreenshotTarget {
  let appWindows = harnessMonitorWindows(in: shareableContent)
  guard !appWindows.isEmpty else {
    throw InputToolError.notFound("Harness Monitor windows")
  }
  if preferredDisplayID == nil, appWindows.count == 1, let window = appWindows.first {
    let filter = SCContentFilter(desktopIndependentWindow: window)
    return ResolvedScreenshotTarget(filter: filter, info: SCShareableContent.info(for: filter))
  }
  let displayWindows: [SCWindow]
  let display: SCDisplay
  if let preferredDisplayID {
    guard let preferredDisplay = shareableContent.displays.first(where: { $0.displayID == preferredDisplayID }) else {
      throw InputToolError.notFound("display \(preferredDisplayID)")
    }
    display = preferredDisplay
    displayWindows = appWindows.filter { $0.frame.intersects(preferredDisplay.frame) }
    guard !displayWindows.isEmpty else {
      throw InputToolError.notFound("Harness Monitor windows on display \(preferredDisplayID)")
    }
  } else {
    display = try resolveSingleDisplay(
      in: shareableContent.displays,
      windows: appWindows,
      label: "Harness Monitor windows"
    )
    displayWindows = appWindows.filter { $0.frame.intersects(display.frame) }
  }
  let filter = SCContentFilter(display: display, including: displayWindows)
  return ResolvedScreenshotTarget(filter: filter, info: SCShareableContent.info(for: filter))
}

private func resolveExplicitWindowCapture(
  windowIDs: [CGWindowID],
  preferredDisplayID: CGDirectDisplayID?,
  in shareableContent: SCShareableContent
) throws -> ResolvedScreenshotTarget {
  let harnessWindows = harnessMonitorWindows(in: shareableContent)
  let harnessWindowsByID = Dictionary(uniqueKeysWithValues: harnessWindows.map { ($0.windowID, $0) })
  let missingWindowIDs = Set(windowIDs).subtracting(Set(harnessWindowsByID.keys))
  guard missingWindowIDs.isEmpty else {
    throw missingHarnessWindowError(missingWindowIDs)
  }
  let requestedWindows = windowIDs.compactMap { harnessWindowsByID[$0] }
  if requestedWindows.count == 1, preferredDisplayID == nil, let window = requestedWindows.first {
    let filter = SCContentFilter(desktopIndependentWindow: window)
    return ResolvedScreenshotTarget(filter: filter, info: SCShareableContent.info(for: filter))
  }

  let label = requestedWindowLabel(windowIDs)
  let display: SCDisplay
  if let preferredDisplayID {
    guard let preferredDisplay = shareableContent.displays.first(where: { $0.displayID == preferredDisplayID }) else {
      throw InputToolError.notFound("display \(preferredDisplayID)")
    }
    guard requestedWindows.allSatisfy({ $0.frame.intersects(preferredDisplay.frame) }) else {
      throw InputToolError.screenshotFailed(
        "\(label) span multiple displays; pass a display containing every requested window or capture one window at a time"
      )
    }
    display = preferredDisplay
  } else {
    display = try resolveSingleDisplay(
      in: shareableContent.displays,
      windows: requestedWindows,
      label: label
    )
  }
  let displayWindows = requestedWindows.filter { $0.frame.intersects(display.frame) }
  guard displayWindows.count == requestedWindows.count else {
    throw InputToolError.screenshotFailed(
      "\(label) do not all belong to display \(display.displayID)"
    )
  }
  let filter = SCContentFilter(display: display, including: displayWindows)
  return ResolvedScreenshotTarget(filter: filter, info: SCShareableContent.info(for: filter))
}

private func resolveSingleDisplay(
  in displays: [SCDisplay],
  windows: [SCWindow],
  label: String
) throws -> SCDisplay {
  guard !displays.isEmpty else {
    throw InputToolError.queryFailed("no displays available for screen capture")
  }
  let matchingDisplays = displays.filter { display in
    windows.allSatisfy { $0.frame.intersects(display.frame) }
  }
  guard let display = matchingDisplays.first else {
    throw InputToolError.screenshotFailed(
      "\(label) span multiple displays; pass --display-id or capture one window at a time"
    )
  }
  guard matchingDisplays.count == 1 else {
    throw InputToolError.screenshotFailed(
      "\(label) overlap multiple displays; pass --display-id"
    )
  }
  return display
}

private func harnessMonitorWindows(in shareableContent: SCShareableContent) -> [SCWindow] {
  shareableContent.windows.filter(isHarnessMonitorWindow)
}

private func missingHarnessWindowError(_ windowIDs: Set<CGWindowID>) -> InputToolError {
  let ids = windowIDs.sorted()
  if let windowID = ids.first, ids.count == 1 {
    return .notFound("Harness Monitor window \(windowID)")
  }
  let joined = ids.map(String.init).joined(separator: ", ")
  return .notFound("Harness Monitor windows \(joined)")
}

private func requestedWindowLabel(_ windowIDs: [CGWindowID]) -> String {
  if let windowID = windowIDs.first, windowIDs.count == 1 {
    return "Harness Monitor window \(windowID)"
  }
  let joined = windowIDs.map(String.init).joined(separator: ", ")
  return "Harness Monitor windows \(joined)"
}

private func isHarnessMonitorWindow(_ window: SCWindow) -> Bool {
  guard let bundleIdentifier = window.owningApplication?.bundleIdentifier else {
    return false
  }
  return AccessibilityQueryDefaults.preferredBundleIdentifiers.contains(bundleIdentifier)
}

private func screenshotConfiguration(
  for info: SCShareableContentInfo,
  includeCursor: Bool
) -> SCScreenshotConfiguration {
  let configuration = SCScreenshotConfiguration()
  configuration.width = pixelDimension(for: info.contentRect.width, scale: info.pointPixelScale)
  configuration.height = pixelDimension(for: info.contentRect.height, scale: info.pointPixelScale)
  configuration.sourceRect = info.contentRect
  configuration.showsCursor = includeCursor
  return configuration
}

private func captureScreenshotImage(
  filter: SCContentFilter,
  configuration: SCScreenshotConfiguration
) async throws -> CGImage {
  try await withCheckedThrowingContinuation { continuation in
    SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: configuration) { output, error in
      if let error {
        continuation.resume(throwing: mappedScreenshotError(error))
        return
      }
      guard let image = output?.sdrImage ?? output?.hdrImage else {
        continuation.resume(throwing: InputToolError.screenshotFailed("ScreenCaptureKit returned no image"))
        return
      }
      continuation.resume(returning: image)
    }
  }
}

private func pngData(for image: CGImage) throws -> Data {
  let bitmap = NSBitmapImageRep(cgImage: image)
  guard let png = bitmap.representation(using: .png, properties: [:]), !png.isEmpty else {
    throw InputToolError.screenshotFailed("ScreenCaptureKit returned a non-encodable image")
  }
  return png
}

private func pixelDimension(for points: CGFloat, scale: Float) -> Int {
  let scaled = (Double(points) * Double(max(scale, 1))).rounded(.up)
  let clamped = min(max(scaled, 1), Double(Int.max))
  return Int(clamped)
}

private func mappedScreenshotError(_ error: Error) -> InputToolError {
  let nsError = error as NSError
  if nsError.domain == SCStreamErrorDomain, nsError.code == -3801 {
    return .screenCaptureDenied
  }
  return .screenshotFailed(nsError.localizedDescription)
}
