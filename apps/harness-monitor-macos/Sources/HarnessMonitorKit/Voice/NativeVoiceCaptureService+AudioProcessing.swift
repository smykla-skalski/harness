import AVFAudio
import CoreMedia
import Foundation

final class VoiceAudioBufferConverter: @unchecked Sendable {
  private let lock = NSLock()
  private let converter: AVAudioConverter?
  private let outputFormat: AVAudioFormat

  init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) {
    self.outputFormat = outputFormat
    guard !inputFormat.hasSameVoiceLayout(as: outputFormat) else {
      self.converter = nil
      return
    }
    guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
      return nil
    }
    self.converter = converter
  }

  func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    lock.withLock {
      guard let converter else {
        return VoiceAudioBufferCodec.copy(buffer)
      }

      let frameCapacity = convertedFrameCapacity(for: buffer)
      guard
        let converted = AVAudioPCMBuffer(
          pcmFormat: outputFormat,
          frameCapacity: frameCapacity
        )
      else {
        return nil
      }

      let inputProvider = VoiceAudioConverterInputProvider(buffer: buffer)
      var conversionError: NSError?
      let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
        inputProvider.nextBuffer(outStatus: outStatus)
      }

      switch status {
      case .haveData, .inputRanDry, .endOfStream:
        return converted.frameLength > 0 ? converted : nil
      case .error:
        return nil
      @unknown default:
        return nil
      }
    }
  }

  private func convertedFrameCapacity(for buffer: AVAudioPCMBuffer) -> AVAudioFrameCount {
    let ratio = outputFormat.sampleRate / buffer.format.sampleRate
    let estimatedFrames = (Double(buffer.frameLength) * ratio).rounded(.up)
    return AVAudioFrameCount(max(1, estimatedFrames + 16))
  }
}

final class VoiceAudioConverterInputProvider: @unchecked Sendable {
  private var buffer: AVAudioPCMBuffer?

  init(buffer: AVAudioPCMBuffer) {
    self.buffer = buffer
  }

  func nextBuffer(outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
    guard let buffer else {
      outStatus.pointee = .noDataNow
      return nil
    }
    self.buffer = nil
    outStatus.pointee = .haveData
    return buffer
  }
}

struct VoiceAudioTiming {
  let sequence: UInt64
  let startedAtSeconds: Double
  let durationSeconds: Double
}

final class VoiceAudioTapState: @unchecked Sendable {
  private let lock = NSLock()
  private let sampleRate: Double
  private var nextSequence: UInt64 = 0
  private var frameOffset: Int64 = 0

  init(sampleRate: Double) {
    self.sampleRate = sampleRate
  }

  func nextTiming(frameCount: Int) -> VoiceAudioTiming {
    lock.withLock {
      nextSequence += 1
      let startedAtSeconds = Double(frameOffset) / sampleRate
      let durationSeconds = Double(frameCount) / sampleRate
      frameOffset += Int64(frameCount)
      return VoiceAudioTiming(
        sequence: nextSequence,
        startedAtSeconds: startedAtSeconds,
        durationSeconds: durationSeconds
      )
    }
  }
}

enum VoiceAudioBufferCodec {
  static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard
      let copied = AVAudioPCMBuffer(
        pcmFormat: buffer.format,
        frameCapacity: buffer.frameLength
      )
    else {
      return nil
    }
    copied.frameLength = buffer.frameLength

    let copiedAllBuffers = withAudioBuffers(buffer.audioBufferList) { sourceBuffers in
      withMutableAudioBuffers(copied.mutableAudioBufferList) { targetBuffers in
        guard sourceBuffers.count == targetBuffers.count else {
          return false
        }

        for index in sourceBuffers.indices {
          guard let source = sourceBuffers[index].mData,
            let target = targetBuffers[index].mData
          else {
            continue
          }
          let byteCount = Int(sourceBuffers[index].mDataByteSize)
          memcpy(target, source, byteCount)
          targetBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }
        return true
      }
    }
    return copiedAllBuffers ? copied : nil
  }

  static func data(from buffer: AVAudioPCMBuffer) -> Data {
    var data = Data()
    withAudioBuffers(buffer.audioBufferList) { buffers in
      for audioBuffer in buffers {
        guard let source = audioBuffer.mData else { continue }
        data.append(
          contentsOf: UnsafeRawBufferPointer(
            start: source,
            count: Int(audioBuffer.mDataByteSize)
          )
        )
      }
    }
    return data
  }

  private static func withAudioBuffers<Result>(
    _ list: UnsafePointer<AudioBufferList>,
    _ body: (UnsafeBufferPointer<AudioBuffer>) -> Result
  ) -> Result {
    let count = Int(list.pointee.mNumberBuffers)
    return withUnsafePointer(to: list.pointee.mBuffers) { bufferPointer in
      bufferPointer.withMemoryRebound(to: AudioBuffer.self, capacity: count) { audioBufferPointer in
        body(UnsafeBufferPointer(start: audioBufferPointer, count: count))
      }
    }
  }

  private static func withMutableAudioBuffers<Result>(
    _ list: UnsafeMutablePointer<AudioBufferList>,
    _ body: (UnsafeMutableBufferPointer<AudioBuffer>) -> Result
  ) -> Result {
    let count = Int(list.pointee.mNumberBuffers)
    return withUnsafeMutablePointer(to: &list.pointee.mBuffers) { bufferPointer in
      bufferPointer.withMemoryRebound(to: AudioBuffer.self, capacity: count) { audioBufferPointer in
        body(UnsafeMutableBufferPointer(start: audioBufferPointer, count: count))
      }
    }
  }
}

extension VoiceAudioFormatDescriptor {
  init(format: AVAudioFormat) {
    self.init(
      sampleRate: format.sampleRate,
      channelCount: Int(format.channelCount),
      commonFormat: format.commonFormat.voiceDescription,
      interleaved: format.isInterleaved
    )
  }
}

extension AVAudioFormat {
  fileprivate func hasSameVoiceLayout(as other: AVAudioFormat) -> Bool {
    sampleRate == other.sampleRate
      && channelCount == other.channelCount
      && commonFormat == other.commonFormat
      && isInterleaved == other.isInterleaved
  }
}

extension AVAudioCommonFormat {
  fileprivate var voiceDescription: String {
    switch self {
    case .pcmFormatFloat32:
      "pcm_f32"
    case .pcmFormatFloat64:
      "pcm_f64"
    case .pcmFormatInt16:
      "pcm_i16"
    case .pcmFormatInt32:
      "pcm_i32"
    case .otherFormat:
      "other"
    @unknown default:
      "unknown"
    }
  }
}
