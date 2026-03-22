mod access;
mod capture;
mod current;
pub(crate) mod dependencies;
pub(crate) mod diagnostics;
mod inspection;
mod managed_services;
mod orchestration;
mod preflight;
mod recording;
mod reporting;
mod services;

use crate::run::services::RunServices;
use std::fmt;

/// Application boundary for tracked-run use cases.
pub struct RunApplication {
    services: RunServices,
}

impl fmt::Debug for RunApplication {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RunApplication")
            .field("services", &self.services)
            .finish()
    }
}

pub use crate::run::services::{
    RecordCommandRequest, StartServiceRequest, tail_task_output, wait_for_task_output,
};
pub(crate) use diagnostics::{doctor, repair};
pub(crate) use orchestration::StartRunRequest;
pub(crate) use recording::record_command;
pub(crate) use reporting::check_report_compactness;
pub use reporting::{GroupReportRequest, ReportCheckOutcome};
