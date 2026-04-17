import HarnessMonitorKit
import Observation
import SwiftUI

extension HarnessVoiceInputButton {
  @Observable
  final class ViewModel {
    var isPopoverPresented = false
    var isRecording = false
    var statusText = "Ready"
    var partialTranscript = ""
    var finalTranscript = ""
    var voiceSessionID: String?
    var captureTask: Task<Void, Never>?
    var processingSessionTask: Task<VoiceSessionStartResponse?, Never>?
    var pendingAudioChunks: [VoiceAudioChunk] = []
    var pendingTranscriptSegments: [VoiceTranscriptSegment] = []
    var pendingAutoInsert = false
    var failurePresentation: VoiceCaptureFailurePresentation?
  }
}
