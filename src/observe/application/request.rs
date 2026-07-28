use harness_observe::application::{ObserveDumpRequest, ObserveScanRequest, ObserveWatchRequest};
use harness_protocol::agent::HookAgent;

/// `ObserveRequest::Doctor` is the only variant `application::execute` handles
/// locally: doctor mode reads `crate::setup`, which `harness-observe` cannot
/// see, so its request type stays here alongside the dispatcher that calls it.
#[derive(Debug, Clone)]
pub(crate) enum ObserveRequest {
    Scan(ObserveScanRequest),
    Watch(ObserveWatchRequest),
    Dump(ObserveDumpRequest),
    Doctor(ObserveDoctorRequest),
}

#[derive(Debug, Clone)]
pub(crate) struct ObserveDoctorRequest {
    pub(crate) json: bool,
    pub(crate) project_dir: Option<String>,
    pub(crate) agent: Option<HookAgent>,
}
