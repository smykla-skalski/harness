import AVFAudio
import CoreMedia
import Foundation
import Speech

public enum NativeVoiceCaptureError: Error, LocalizedError, Equatable, Sendable {
  case microphonePermissionDenied
  case speechUnavailable
  case unsupportedLocale(String)
  case speechAssetsUnavailable(String)
  case noInputFormat
  case couldNotCopyAudioBuffer
  case couldNotConvertAudioBuffer

  public var errorDescription: String? {
    switch self {
    case .microphonePermissionDenied:
      "Microphone access is disabled for Harness Monitor."
    case .speechUnavailable:
      "Speech transcription is unavailable on this Mac."
    case .unsupportedLocale(let locale):
      "Speech transcription does not support \(locale)."
    case .speechAssetsUnavailable(let locale):
      "Speech assets for \(locale) are unavailable."
    case .noInputFormat:
      "The microphone input format is unavailable."
    case .couldNotCopyAudioBuffer:
      "The microphone audio buffer could not be copied."
    case .couldNotConvertAudioBuffer:
      "The microphone audio buffer could not be converted for speech analysis."
    }
  }
}

@available(macOS 26.0, *)
public actor NativeVoiceCaptureService: VoiceCaptureProviding {
  private struct ActiveCapture {
    let engine: AVAudioEngine
    let analyzer: SpeechAnalyzer
    let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    let analysisTask: Task<Void, Error>
    let resultsTask: Task<Void, Never>
    let outputContinuation: VoiceCaptureEventStream.Continuation
    let reservedLocale: Locale
  }

  private struct TranscriptionModules {
    let locale: Locale
    let transcriber: SpeechTranscriber
    let modules: [any SpeechModule]
  }

  private var activeCapture: ActiveCapture?

  public init() {}

  nonisolated public func capture(configuration: VoiceCaptureConfiguration)
    -> VoiceCaptureEventStream
  {
    VoiceCaptureEventStream { continuation in
      let task = Task {
        await self.startCapture(configuration: configuration, continuation: continuation)
      }
      continuation.onTermination = { _ in
        task.cancel()
        Task { await self.stop() }
      }
    }
  }

  public func stop() async {
    guard let activeCapture else { return }
    self.activeCapture = nil

    activeCapture.outputContinuation.yield(.state(.finishing))
    activeCapture.engine.inputNode.removeTap(onBus: 0)
    activeCapture.engine.stop()
    activeCapture.inputContinuation.finish()
    activeCapture.analysisTask.cancel()
    activeCapture.resultsTask.cancel()
    await activeCapture.analyzer.cancelAndFinishNow()
    await AssetInventory.release(reservedLocale: activeCapture.reservedLocale)
    activeCapture.outputContinuation.yield(.state(.cancelled))
    activeCapture.outputContinuation.finish()
  }

  private func startCapture(
    configuration: VoiceCaptureConfiguration,
    continuation: VoiceCaptureEventStream.Continuation
  ) async {
    do {
      try await configureCapture(configuration: configuration, continuation: continuation)
    } catch {
      continuation.yield(.state(.failed))
      continuation.finish(throwing: error)
    }
  }

  private func configureCapture(
    configuration: VoiceCaptureConfiguration,
    continuation: VoiceCaptureEventStream.Continuation
  ) async throws {
    await stop()

    continuation.yield(.state(.requestingPermission))
    guard await AVAudioApplication.requestRecordPermission() else {
      throw NativeVoiceCaptureError.microphonePermissionDenied
    }
    guard SpeechTranscriber.isAvailable else {
      throw NativeVoiceCaptureError.speechUnavailable
    }

    continuation.yield(.state(.preparingAssets))
    let ready = try await makeTranscriptionModules(configuration: configuration)
    let locale = ready.locale
    let transcriber = ready.transcriber
    let modules = ready.modules

    var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    let inputStream = AsyncStream<AnalyzerInput>(bufferingPolicy: .bufferingNewest(16)) {
      inputContinuation = $0
    }
    guard let inputContinuation else {
      throw NativeVoiceCaptureError.noInputFormat
    }

    let analyzer = SpeechAnalyzer(
      modules: modules,
      options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse)
    )
    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    let naturalFormat = inputNode.outputFormat(forBus: 0)
    guard naturalFormat.sampleRate > 0, naturalFormat.channelCount > 0 else {
      throw NativeVoiceCaptureError.noInputFormat
    }
    let analysisFormat =
      await SpeechAnalyzer.bestAvailableAudioFormat(
        compatibleWith: modules,
        considering: naturalFormat
      ) ?? naturalFormat
    try await analyzer.prepareToAnalyze(in: analysisFormat)

    guard let bufferConverter = VoiceAudioBufferConverter(from: naturalFormat, to: analysisFormat)
    else {
      throw NativeVoiceCaptureError.couldNotConvertAudioBuffer
    }
    let tapState = VoiceAudioTapState(sampleRate: analysisFormat.sampleRate)
    inputNode.installTap(onBus: 0, bufferSize: 4_096, format: naturalFormat) { buffer, _ in
      guard let analyzerBuffer = bufferConverter.convert(buffer) else {
        continuation.finish(throwing: NativeVoiceCaptureError.couldNotConvertAudioBuffer)
        return
      }
      let timing = tapState.nextTiming(frameCount: Int(analyzerBuffer.frameLength))
      let input = AnalyzerInput(
        buffer: analyzerBuffer,
        bufferStartTime: CMTime(seconds: timing.startedAtSeconds, preferredTimescale: 1_000_000)
      )
      inputContinuation.yield(input)

      guard configuration.deliversAudioChunks else { return }
      let audioData = VoiceAudioBufferCodec.data(from: analyzerBuffer)
      let descriptor = VoiceAudioFormatDescriptor(format: analyzerBuffer.format)
      continuation.yield(
        .audio(
          VoiceAudioChunk(
            sequence: timing.sequence,
            format: descriptor,
            frameCount: Int(analyzerBuffer.frameLength),
            startedAtSeconds: timing.startedAtSeconds,
            durationSeconds: timing.durationSeconds,
            audioData: audioData
          )
        )
      )
    }

    let analysisTask = Task {
      try await analyzer.start(inputSequence: inputStream)
    }
    let resultsTask = Task {
      await streamResults(from: transcriber, to: continuation)
    }

    activeCapture = ActiveCapture(
      engine: engine,
      analyzer: analyzer,
      inputContinuation: inputContinuation,
      analysisTask: analysisTask,
      resultsTask: resultsTask,
      outputContinuation: continuation,
      reservedLocale: locale
    )

    try engine.start()
    continuation.yield(.state(.recording))
  }

  private func makeTranscriptionModules(
    configuration: VoiceCaptureConfiguration
  ) async throws -> TranscriptionModules {
    var foundSupportedLocale = false
    for candidate in HarnessMonitorVoiceLocaleSupport.candidateLocales(
      for: configuration.localeIdentifier
    ) {
      guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: candidate) else {
        continue
      }
      foundSupportedLocale = true
      let transcriber = SpeechTranscriber(
        locale: locale,
        preset: .timeIndexedProgressiveTranscription
      )
      let modules: [any SpeechModule] = [transcriber]
      do {
        try await prepareAssets(for: modules, locale: locale)
        return TranscriptionModules(locale: locale, transcriber: transcriber, modules: modules)
      } catch let error as NativeVoiceCaptureError {
        guard error == .speechAssetsUnavailable(locale.identifier) else {
          throw error
        }
      }
    }

    if foundSupportedLocale {
      throw NativeVoiceCaptureError.speechAssetsUnavailable(configuration.localeIdentifier)
    }
    throw NativeVoiceCaptureError.unsupportedLocale(configuration.localeIdentifier)
  }

  private func prepareAssets(for modules: [any SpeechModule], locale: Locale) async throws {
    switch await AssetInventory.status(forModules: modules) {
    case .installed:
      break
    case .supported, .downloading:
      if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
        try await request.downloadAndInstall()
      }
      guard await AssetInventory.status(forModules: modules) == .installed else {
        throw NativeVoiceCaptureError.speechAssetsUnavailable(locale.identifier)
      }
    case .unsupported:
      throw NativeVoiceCaptureError.speechAssetsUnavailable(locale.identifier)
    @unknown default:
      throw NativeVoiceCaptureError.speechAssetsUnavailable(locale.identifier)
    }

    guard try await AssetInventory.reserve(locale: locale) else {
      throw NativeVoiceCaptureError.speechAssetsUnavailable(locale.identifier)
    }
  }

  nonisolated private func streamResults(
    from transcriber: SpeechTranscriber,
    to continuation: VoiceCaptureEventStream.Continuation
  ) async {
    do {
      var sequence: UInt64 = 0
      for try await result in transcriber.results {
        sequence += 1
        let text = String(result.text.characters)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }
        continuation.yield(
          .transcript(
            VoiceTranscriptSegment(
              sequence: sequence,
              text: text,
              isFinal: result.isFinal,
              startedAtSeconds: result.range.start.seconds,
              durationSeconds: result.range.duration.seconds
            )
          )
        )
      }
      continuation.finish()
    } catch is CancellationError {
      continuation.finish()
    } catch {
      continuation.finish(throwing: error)
    }
  }
}
