import AppKit
import HarnessMonitorKit
import ImageIO
import os

private let diskCacheLog = Logger(subsystem: "io.harnessmonitor", category: "thumbnail")

extension BackgroundThumbnailCache {
  // MARK: - Disk cache

  private func diskCachePath(key: String, extension ext: String) -> URL {
    cacheDirectory.appendingPathComponent("\(key).\(ext)")
  }

  func loadFromDiskCache(key: String, expectedMtime: TimeInterval?) -> CGImage? {
    let jpegURL = diskCachePath(key: key, extension: "jpg")
    let metaURL = diskCachePath(key: key, extension: "meta")

    guard FileManager.default.fileExists(atPath: jpegURL.path),
      FileManager.default.fileExists(atPath: metaURL.path)
    else {
      return nil
    }

    guard
      let metaString = try? String(contentsOf: metaURL, encoding: .utf8).trimmingCharacters(
        in: .whitespacesAndNewlines
      )
    else {
      return nil
    }

    if let expectedMtime {
      guard let storedMtime = TimeInterval(metaString),
        abs(storedMtime - expectedMtime) < 0.001
      else {
        return nil
      }
    } else {
      guard metaString == "bundled" else {
        return nil
      }
    }

    let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]

    guard
      let source = CGImageSourceCreateWithURL(
        jpegURL as CFURL,
        sourceOptions as CFDictionary
      )
    else {
      return nil
    }

    let imageOptions: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
    return CGImageSourceCreateImageAtIndex(source, 0, imageOptions as CFDictionary)
  }

  func saveToDiskCache(image: CGImage, key: String, sourceMtime: TimeInterval?) {
    do {
      try FileManager.default.createDirectory(
        at: cacheDirectory,
        withIntermediateDirectories: true
      )
    } catch {
      diskCacheLog.warning("Failed to create cache directory: \(error)")
      return
    }

    let jpegURL = diskCachePath(key: key, extension: "jpg")
    let metaURL = diskCachePath(key: key, extension: "meta")

    let cacheImage = opaqueRGBImage(from: image, maxPixelSize: nil) ?? image
    let rep = NSBitmapImageRep(cgImage: cacheImage)
    guard
      let jpegData = rep.representation(
        using: .jpeg,
        properties: [.compressionFactor: 0.85]
      )
    else {
      return
    }

    let tmpJPEG = cacheDirectory.appendingPathComponent(".\(key).jpg.tmp")
    let tmpMeta = cacheDirectory.appendingPathComponent(".\(key).meta.tmp")

    do {
      try jpegData.write(to: tmpJPEG, options: .atomic)
      _ = try FileManager.default.replaceItemAt(jpegURL, withItemAt: tmpJPEG)
    } catch {
      diskCacheLog.warning("Failed to write thumbnail: \(error)")
      try? FileManager.default.removeItem(at: tmpJPEG)
      return
    }

    let metaContent = sourceMtime.map { String($0) } ?? "bundled"
    do {
      try metaContent.write(to: tmpMeta, atomically: true, encoding: .utf8)
      _ = try FileManager.default.replaceItemAt(metaURL, withItemAt: tmpMeta)
    } catch {
      diskCacheLog.warning("Failed to write meta: \(error)")
      try? FileManager.default.removeItem(at: tmpMeta)
    }
  }
}
