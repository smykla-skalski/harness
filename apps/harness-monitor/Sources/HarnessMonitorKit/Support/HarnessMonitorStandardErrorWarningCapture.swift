import Darwin
import Foundation
import os

struct HarnessMonitorBufferedLineSplitter {
  private var buffered = Data()

  mutating func append(_ data: Data) -> [String] {
    guard !data.isEmpty else {
      return []
    }
    buffered.append(data)
    return drainCompleteLines()
  }

  mutating func flush() -> [String] {
    guard !buffered.isEmpty else {
      return []
    }
    let line = Self.decode(Data(buffered))
    buffered.removeAll(keepingCapacity: false)
    return [line]
  }

  private mutating func drainCompleteLines() -> [String] {
    var lines: [String] = []
    while let lineBreakIndex = buffered.firstIndex(where: Self.isLineBreak) {
      let line = Data(buffered[..<lineBreakIndex])
      let lineBreak = buffered[lineBreakIndex]
      buffered.removeSubrange(...lineBreakIndex)
      if lineBreak == 0x0D, buffered.first == 0x0A {
        buffered.removeFirst()
      }
      lines.append(Self.decode(line))
    }
    return lines
  }

  private static func isLineBreak(_ byte: UInt8) -> Bool {
    byte == 0x0A || byte == 0x0D
  }

  private static func decode(_ data: Data) -> String {
    (String(bytes: data, encoding: .utf8) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

enum HarnessMonitorSwiftUIWarningMatcher {
  private static let attributeGraphFragment = "AttributeGraph: cycle detected through attribute"
  private static let focusedValueFragment =
    "FocusedValue update tried to update multiple times per frame"
  private static let ignoredFragments = [
    "OSLOG-",
    "Mirrored SwiftUI runtime warning from stderr:",
    "SwiftUI runtime warning:",
  ]

  static func mirroredLogMessage(for line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }
    guard ignoredFragments.allSatisfy({ !trimmed.contains($0) }) else {
      return nil
    }
    if let message = extractedMessage(containing: attributeGraphFragment, in: trimmed) {
      return message
    }
    if let message = extractedMessage(containing: focusedValueFragment, in: trimmed) {
      return message
    }
    return nil
  }

  private static func extractedMessage(containing fragment: String, in line: String) -> String? {
    guard let fragmentRange = line.range(of: fragment) else {
      return nil
    }
    var message = String(line[fragmentRange.lowerBound...])
    message = message.replacingOccurrences(of: "===", with: "")
    message = message.trimmingCharacters(in: CharacterSet(charactersIn: "= \t"))
    return message.isEmpty ? nil : message
  }
}

public final class HarnessMonitorStandardErrorWarningCapture {
  private let queue = DispatchQueue(label: "io.harnessmonitor.stderr-warning-capture")
  private var source: DispatchSourceRead?
  private var readFileDescriptor: Int32 = -1
  private var originalStandardErrorFileDescriptor: Int32 = -1
  private var lineSplitter = HarnessMonitorBufferedLineSplitter()

  public init() {}

  deinit {
    stop()
  }

  public func start() {
    guard source == nil else {
      return
    }

    var pipeDescriptors: [Int32] = [0, 0]
    guard Darwin.pipe(&pipeDescriptors) == 0 else {
      logInstallFailure(step: "pipe", errnoValue: errno)
      return
    }

    let readFileDescriptor = pipeDescriptors[0]
    let writeFileDescriptor = pipeDescriptors[1]

    guard Self.makeNonBlocking(readFileDescriptor) else {
      let errnoValue = errno
      Darwin.close(readFileDescriptor)
      Darwin.close(writeFileDescriptor)
      logInstallFailure(step: "fcntl", errnoValue: errnoValue)
      return
    }

    let originalStandardErrorFileDescriptor = Darwin.dup(STDERR_FILENO)
    guard originalStandardErrorFileDescriptor >= 0 else {
      let errnoValue = errno
      Darwin.close(readFileDescriptor)
      Darwin.close(writeFileDescriptor)
      logInstallFailure(step: "dup", errnoValue: errnoValue)
      return
    }

    guard Darwin.dup2(writeFileDescriptor, STDERR_FILENO) >= 0 else {
      let errnoValue = errno
      Darwin.close(readFileDescriptor)
      Darwin.close(writeFileDescriptor)
      Darwin.close(originalStandardErrorFileDescriptor)
      logInstallFailure(step: "dup2", errnoValue: errnoValue)
      return
    }

    Darwin.close(writeFileDescriptor)

    self.readFileDescriptor = readFileDescriptor
    self.originalStandardErrorFileDescriptor = originalStandardErrorFileDescriptor

    let source = DispatchSource.makeReadSource(
      fileDescriptor: readFileDescriptor,
      queue: queue
    )
    source.setEventHandler { [weak self] in
      self?.consumeAvailableBytes()
    }
    source.setCancelHandler { [weak self] in
      self?.tearDownCapture()
    }

    self.source = source
    source.resume()
  }

  public func stop() {
    guard let source else {
      return
    }
    self.source = nil
    source.cancel()
  }

  private func consumeAvailableBytes() {
    guard readFileDescriptor >= 0 else {
      return
    }

    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
      let bytesRead = Darwin.read(readFileDescriptor, &buffer, buffer.count)
      if bytesRead > 0 {
        let chunk = Data(buffer.prefix(bytesRead))
        mirrorToOriginalStandardError(chunk)
        let lines = lineSplitter.append(chunk)
        for line in lines {
          logMirroredWarningIfNeeded(line)
        }
        if bytesRead < buffer.count {
          return
        }
        continue
      }

      if bytesRead == 0 {
        return
      }

      if errno == EAGAIN || errno == EWOULDBLOCK {
        return
      }

      HarnessMonitorLogger.swiftui.error(
        "Failed reading stderr warning stream: errno \(errno, privacy: .public)"
      )
      return
    }
  }

  private func mirrorToOriginalStandardError(_ data: Data) {
    guard originalStandardErrorFileDescriptor >= 0 else {
      return
    }

    data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else {
        return
      }
      var writtenByteCount = 0
      while writtenByteCount < rawBuffer.count {
        let bytesWritten = Darwin.write(
          originalStandardErrorFileDescriptor,
          baseAddress.advanced(by: writtenByteCount),
          rawBuffer.count - writtenByteCount
        )
        if bytesWritten > 0 {
          writtenByteCount += bytesWritten
          continue
        }
        if errno == EINTR {
          continue
        }
        return
      }
    }
  }

  private func logMirroredWarningIfNeeded(_ line: String) {
    guard let message = HarnessMonitorSwiftUIWarningMatcher.mirroredLogMessage(for: line) else {
      return
    }
    HarnessMonitorLogger.swiftui.warning("\(message, privacy: .public)")
  }

  private func tearDownCapture() {
    for line in lineSplitter.flush() {
      logMirroredWarningIfNeeded(line)
    }

    if originalStandardErrorFileDescriptor >= 0 {
      _ = Darwin.dup2(originalStandardErrorFileDescriptor, STDERR_FILENO)
      Darwin.close(originalStandardErrorFileDescriptor)
      originalStandardErrorFileDescriptor = -1
    }

    if readFileDescriptor >= 0 {
      Darwin.close(readFileDescriptor)
      readFileDescriptor = -1
    }
  }

  private static func makeNonBlocking(_ fileDescriptor: Int32) -> Bool {
    let flags = Darwin.fcntl(fileDescriptor, F_GETFL)
    guard flags >= 0 else {
      return false
    }
    return Darwin.fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0
  }

  private func logInstallFailure(step: String, errnoValue: Int32) {
    HarnessMonitorLogger.lifecycle.error(
      "Failed to install stderr capture at \(step, privacy: .public): errno \(errnoValue, privacy: .public)"
    )
  }
}
