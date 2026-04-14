use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum VoiceProcessingSink {
    LocalDaemon,
    RemoteProcessor,
    AgentBridge,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum VoiceRouteTargetKind {
    CodexPrompt,
    CodexContext,
    Signal,
    SystemFocusedField,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VoiceRouteTarget {
    pub kind: VoiceRouteTargetKind,
    pub run_id: Option<String>,
    pub agent_id: Option<String>,
    pub command: Option<String>,
    pub action_hint: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VoiceAudioFormatDescriptor {
    pub sample_rate: f64,
    pub channel_count: usize,
    pub common_format: String,
    pub interleaved: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VoiceTranscriptSegment {
    pub sequence: u64,
    pub text: String,
    pub is_final: bool,
    pub started_at_seconds: f64,
    pub duration_seconds: f64,
    pub confidence: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VoiceSessionStartRequest {
    pub actor: String,
    pub locale_identifier: String,
    pub requested_sinks: Vec<VoiceProcessingSink>,
    pub route_target: VoiceRouteTarget,
    pub requires_confirmation: bool,
    pub remote_processor_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VoiceSessionStartResponse {
    pub voice_session_id: String,
    pub accepted_sinks: Vec<VoiceProcessingSink>,
    pub status: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VoiceAudioChunkRequest {
    pub actor: String,
    pub sequence: u64,
    pub format: VoiceAudioFormatDescriptor,
    pub frame_count: usize,
    pub started_at_seconds: f64,
    pub duration_seconds: f64,
    pub audio_base64: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VoiceTranscriptUpdateRequest {
    pub actor: String,
    pub segment: VoiceTranscriptSegment,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum VoiceSessionFinishReason {
    Completed,
    Cancelled,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VoiceSessionFinishRequest {
    pub actor: String,
    pub reason: VoiceSessionFinishReason,
    pub confirmed_text: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VoiceSessionMutationResponse {
    pub voice_session_id: String,
    pub status: String,
}
