use harness_kernel::errors::CliError;
use harness_observe::application::{execute_dump_mode, execute_scan_mode};
use harness_observe::watch::execute_watch;

use super::request::{ObserveDoctorRequest, ObserveRequest};
use crate::observe::doctor;

pub(crate) fn execute(request: ObserveRequest) -> Result<i32, CliError> {
    match request {
        ObserveRequest::Scan(request) => execute_scan_mode(&request),
        ObserveRequest::Watch(request) => execute_watch(
            &request.session_id,
            request.poll_interval,
            request.timeout,
            &request.filter,
        ),
        ObserveRequest::Dump(request) => execute_dump_mode(&request),
        ObserveRequest::Doctor(request) => execute_doctor_mode(&request),
    }
}

fn execute_doctor_mode(request: &ObserveDoctorRequest) -> Result<i32, CliError> {
    doctor::execute_doctor(request.json, request.project_dir.as_deref(), request.agent)
}
