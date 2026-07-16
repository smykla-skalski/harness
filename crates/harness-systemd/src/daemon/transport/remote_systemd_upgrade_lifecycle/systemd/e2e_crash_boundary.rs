use std::env;
use std::num::NonZeroUsize;
use std::process;
use std::sync::atomic::{AtomicUsize, Ordering};

use nix::sys::signal::{Signal, kill};
use nix::unistd::Pid;

use crate::errors::CliError;

use super::io_error;

const SELECTION_ENV: &str = "HARNESS_REMOTE_SYSTEMD_E2E_PAUSE_AT";
static MATCHING_OCCURRENCE: AtomicUsize = AtomicUsize::new(0);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum StartBoundary {
    PermitReloaded,
    ServiceSpawned,
    PermitRemoved,
}

impl StartBoundary {
    const fn name(self) -> &'static str {
        match self {
            Self::PermitReloaded => "permit-reloaded-before-start",
            Self::ServiceSpawned => "main-pid-before-permit-removal",
            Self::PermitRemoved => "permit-removed-before-persistent-reload",
        }
    }

    fn parse(value: &str) -> Result<Self, CliError> {
        match value {
            "permit-reloaded-before-start" => Ok(Self::PermitReloaded),
            "main-pid-before-permit-removal" => Ok(Self::ServiceSpawned),
            "permit-removed-before-persistent-reload" => Ok(Self::PermitRemoved),
            _ => Err(io_error(format!(
                "unknown remote systemd E2E crash boundary {value:?}"
            ))),
        }
    }
}

struct Selection {
    boundary: StartBoundary,
    occurrence: NonZeroUsize,
}

pub(super) fn pause_at(boundary: StartBoundary) -> Result<(), CliError> {
    let Some(selection) = selection()? else {
        return Ok(());
    };
    if selection.boundary != boundary {
        return Ok(());
    }
    let occurrence = MATCHING_OCCURRENCE
        .fetch_add(1, Ordering::SeqCst)
        .checked_add(1)
        .ok_or_else(|| io_error("remote systemd E2E crash occurrence overflow"))?;
    if occurrence != selection.occurrence.get() {
        return Ok(());
    }
    let pid = i32::try_from(process::id())
        .map(Pid::from_raw)
        .map_err(|error| io_error(format!("convert E2E coordinator process id: {error}")))?;
    kill(pid, Signal::SIGSTOP).map_err(|error| {
        io_error(format!(
            "pause at remote systemd E2E boundary {}: {error}",
            boundary.name()
        ))
    })?;
    Err(io_error(format!(
        "remote systemd E2E coordinator resumed from {} instead of being killed",
        boundary.name()
    )))
}

fn selection() -> Result<Option<Selection>, CliError> {
    let Some(value) = env::var_os(SELECTION_ENV) else {
        return Ok(None);
    };
    let value = value
        .into_string()
        .map_err(|_| io_error("remote systemd E2E crash boundary is not UTF-8"))?;
    let (boundary, occurrence) = value.rsplit_once(':').ok_or_else(|| {
        io_error(format!(
            "remote systemd E2E crash boundary must include an occurrence: {value:?}"
        ))
    })?;
    let occurrence = occurrence
        .parse::<NonZeroUsize>()
        .map_err(|error| io_error(format!("parse E2E crash occurrence: {error}")))?;
    Ok(Some(Selection {
        boundary: StartBoundary::parse(boundary)?,
        occurrence,
    }))
}
