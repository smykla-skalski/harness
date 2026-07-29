use super::*;

const FIXTURE_READY_TIMEOUT: Duration = Duration::from_secs(30);
const FIXTURE_READY_POLL_INTERVAL: Duration = Duration::from_millis(10);

#[derive(Clone, Copy)]
pub(super) enum IdleSignalScriptBehavior {
    AckOnWake,
    IgnoreWake,
}

pub(super) struct IdleSignalScript {
    path: PathBuf,
    ready_marker: PathBuf,
}

impl IdleSignalScript {
    pub(super) fn path(&self) -> &Path {
        &self.path
    }

    pub(super) fn wait_until_ready(&self) {
        let deadline = Instant::now() + FIXTURE_READY_TIMEOUT;
        while !self.ready_marker.exists() {
            assert!(
                Instant::now() < deadline,
                "idle signal fixture did not consume its initial join prompt at {}",
                self.ready_marker.display()
            );
            thread::sleep(FIXTURE_READY_POLL_INTERVAL);
        }
    }
}

pub(super) fn write_idle_signal_script(
    project: &Path,
    signal_dir: &Path,
    runtime_session_id: &str,
    orchestration_session_id: &str,
    behavior: IdleSignalScriptBehavior,
) -> IdleSignalScript {
    let stem = match behavior {
        IdleSignalScriptBehavior::AckOnWake => "idle-signal-ack",
        IdleSignalScriptBehavior::IgnoreWake => "idle-signal-ignore",
    };
    let path = project.join(format!("{stem}.sh"));
    let ready_marker = project.join(format!("{stem}.ready"));
    let wake_behavior = wake_behavior(
        signal_dir,
        runtime_session_id,
        orchestration_session_id,
        behavior,
    );
    let script = format!(
        r#"#!/bin/sh
IFS= read -r _initial_prompt || exit 1
ready_tmp="{ready_marker}.tmp.$$"
: > "$ready_tmp"
mv "$ready_tmp" "{ready_marker}"
while IFS= read -r _wake_prompt; do
  {wake_behavior}
done
"#,
        ready_marker = ready_marker.display(),
    );
    fs::write(&path, script).expect("write idle signal script");
    let mut permissions = fs::metadata(&path).expect("script metadata").permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&path, permissions).expect("set script executable");
    IdleSignalScript { path, ready_marker }
}

fn wake_behavior(
    signal_dir: &Path,
    runtime_session_id: &str,
    orchestration_session_id: &str,
    behavior: IdleSignalScriptBehavior,
) -> String {
    match behavior {
        IdleSignalScriptBehavior::AckOnWake => format!(
            r#"attempt=0
while [ "$attempt" -lt 600 ]; do
  for signal_file in "{signal_dir}/pending"/*.json; do
    if [ -e "$signal_file" ]; then
      signal_id=$(basename "$signal_file" .json)
      ack_dir="{signal_dir}/acknowledged"
      mkdir -p "$ack_dir"
      ack_path="$ack_dir/$signal_id.ack.json"
      ack_tmp="$ack_path.tmp.$$"
      cat > "$ack_tmp" <<EOF
{{"signal_id":"$signal_id","acknowledged_at":"2026-04-13T00:00:00Z","result":"accepted","agent":"{runtime_session_id}","session_id":"{orchestration_session_id}"}}
EOF
      mv "$ack_tmp" "$ack_path"
      mv "$signal_file" "$ack_dir/$signal_id.json"
      while IFS= read -r _ignored; do :; done
      exit 0
    fi
  done
  attempt=$((attempt + 1))
  sleep 0.05
done
exit 1
"#,
            signal_dir = signal_dir.display(),
        ),
        IdleSignalScriptBehavior::IgnoreWake => {
            "sleep 2\nwhile IFS= read -r _ignored; do :; done\n".to_string()
        }
    }
}
