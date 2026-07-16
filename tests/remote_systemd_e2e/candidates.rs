use std::fs;
use std::io::Write as _;
use std::os::unix::fs::PermissionsExt as _;
use std::path::Path;

pub const CORRUPTION_MARKER_NAME: &str = "remote-systemd-e2e-database-corrupted";
pub const CORRUPTION_MARKER_VALUE: &str = "candidate database corruption reached stable storage";

pub fn prepare_candidates(
    binary_source: &Path,
    valid_candidate_path: &Path,
    crash_candidate_path: &Path,
    spoofed_candidate_path: &Path,
) -> Result<(), String> {
    prepare_valid_candidate(
        binary_source,
        valid_candidate_path,
        b"\nHARNESS_REMOTE_SYSTEMD_E2E_CANDIDATE\n",
    )?;
    prepare_valid_candidate(
        binary_source,
        crash_candidate_path,
        b"\nHARNESS_REMOTE_SYSTEMD_E2E_CRASH_CANDIDATE\n",
    )?;
    prepare_corrupting_candidate(spoofed_candidate_path)
}

fn prepare_corrupting_candidate(path: &Path) -> Result<(), String> {
    let candidate = format!(
        "#!/bin/sh\n\
         set -eu\n\
         if [ \"$1\" = \"--version\" ]; then\n\
           echo 'harness 999.0.0'\n\
           exit 0\n\
         fi\n\
         database=\"$HARNESS_DAEMON_DATA_HOME/harness/daemon/external/harness.db\"\n\
         marker=\"$HARNESS_DAEMON_DATA_HOME/harness/{CORRUPTION_MARKER_NAME}\"\n\
         printf 'candidate-corrupted-database\\n' > \"$database\"\n\
         sync -f \"$database\"\n\
         printf '%s\\n' '{CORRUPTION_MARKER_VALUE}' > \"$marker\"\n\
         sync -f \"$marker\"\n\
         printf '%s\\n' '{CORRUPTION_MARKER_VALUE}' >&2\n\
         exit 1\n"
    );
    fs::write(path, candidate).map_err(|error| {
        format!(
            "write spoofed systemd upgrade candidate {}: {error}",
            path.display()
        )
    })?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).map_err(|error| {
        format!(
            "make spoofed systemd upgrade candidate executable {}: {error}",
            path.display()
        )
    })
}

fn prepare_valid_candidate(
    binary_source: &Path,
    candidate_path: &Path,
    differentiator: &[u8],
) -> Result<(), String> {
    fs::copy(binary_source, candidate_path).map_err(|error| {
        format!(
            "copy valid systemd upgrade candidate {}: {error}",
            candidate_path.display()
        )
    })?;
    let mut candidate = fs::OpenOptions::new()
        .append(true)
        .open(candidate_path)
        .map_err(|error| {
            format!(
                "open valid systemd upgrade candidate {}: {error}",
                candidate_path.display()
            )
        })?;
    candidate.write_all(differentiator).map_err(|error| {
        format!(
            "differentiate valid systemd upgrade candidate {}: {error}",
            candidate_path.display()
        )
    })?;
    candidate.sync_all().map_err(|error| {
        format!(
            "sync valid systemd upgrade candidate {}: {error}",
            candidate_path.display()
        )
    })
}
