use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use reqwest::Client;
use serde::Serialize;
use tempfile::tempdir;
use tokio::sync::{broadcast, watch};

use harness::daemon::db::DaemonDb;
use harness::daemon::http::{DaemonHttpState, serve};
use harness::daemon::protocol::StreamEvent;
use harness::daemon::service;
use harness::daemon::state::{self, DaemonManifest};
use harness::daemon::websocket::ReplayBuffer;
use harness::session::service as session_service;
use harness::session::types::{SessionRole, TaskSeverity};

const SAMPLE_COUNT: usize = 10;

#[derive(Serialize)]
struct PerfResult {
    endpoint: String,
    samples_ms: Vec<f64>,
    median_ms: f64,
    target_ms: f64,
    passed: bool,
}

fn median(values: &mut [f64]) -> f64 {
    values.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let mid = values.len() / 2;
    if values.len() % 2 == 0 {
        (values[mid - 1] + values[mid]) / 2.0
    } else {
        values[mid]
    }
}

struct TestDaemon {
    endpoint: String,
    token: String,
    _shutdown_tx: watch::Sender<bool>,
}

async fn start_test_daemon(db: Option<DaemonDb>) -> TestDaemon {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind");
    let addr = listener.local_addr().expect("local addr");
    let endpoint = format!("http://{addr}");
    let token = "test-token".to_string();
    let (sender, _) = broadcast::channel::<StreamEvent>(64);
    let (shutdown_tx, shutdown_rx) = watch::channel(false);

    let manifest = DaemonManifest {
        version: env!("CARGO_PKG_VERSION").to_string(),
        pid: std::process::id(),
        endpoint: endpoint.clone(),
        started_at: harness::workspace::utc_now(),
        token_path: String::new(),
    };

    let db_slot = Arc::new(OnceLock::new());
    if let Some(db) = db {
        db_slot
            .set(Arc::new(Mutex::new(db)))
            .expect("seed daemon db");
    }

    let state = DaemonHttpState {
        token: token.clone(),
        sender,
        manifest,
        daemon_epoch: harness::workspace::utc_now(),
        replay_buffer: Arc::new(Mutex::new(ReplayBuffer::new(64))),
        db: db_slot,
    };

    tokio::spawn(async move {
        let _ = serve(listener, state, shutdown_rx).await;
    });

    let client = Client::new();
    for _ in 0..50 {
        if client
            .get(format!("{endpoint}/v1/health"))
            .bearer_auth(&token)
            .send()
            .await
            .is_ok()
        {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }

    TestDaemon {
        endpoint,
        token,
        _shutdown_tx: shutdown_tx,
    }
}

async fn measure_endpoint(client: &Client, url: &str, token: &str, samples: usize) -> Vec<f64> {
    let mut timings = Vec::with_capacity(samples);
    for _ in 0..samples {
        let start = Instant::now();
        let response = client
            .get(url)
            .bearer_auth(token)
            .send()
            .await
            .expect("request");
        let _body = response.bytes().await.expect("body");
        timings.push(start.elapsed().as_secs_f64() * 1000.0);
    }
    timings
}

fn seed_workspace(tmp: &std::path::Path) {
    state::ensure_daemon_dirs().expect("dirs");

    let project_a = tmp.join("project-a");
    let project_b = tmp.join("project-b");
    fs_err::create_dir_all(&project_a).expect("create project a");
    fs_err::create_dir_all(&project_b).expect("create project b");

    for project in [&project_a, &project_b] {
        std::process::Command::new("git")
            .arg("-C")
            .arg(project)
            .args(["init"])
            .status()
            .expect("git init");
    }

    let state_a =
        session_service::start_session("perf-test", "", &project_a, Some("claude"), Some("s1"))
            .expect("start s1");
    session_service::join_session("s1", SessionRole::Worker, "codex", &[], None, &project_a)
        .expect("join s1");

    let state_b =
        session_service::start_session("perf-test-2", "", &project_b, Some("claude"), Some("s2"))
            .expect("start s2");

    let sessions = [
        ("s1", project_a.as_path(), &state_a),
        ("s2", project_b.as_path(), &state_b),
    ];

    for (session_id, project_dir, session_state) in &sessions {
        let leader = session_state
            .agents
            .keys()
            .find(|id| id.starts_with("claude"))
            .expect("leader agent");
        for i in 0..3 {
            session_service::create_task(
                session_id,
                &format!("perf task {i}"),
                Some("benchmark context"),
                TaskSeverity::Medium,
                leader,
                project_dir,
            )
            .expect("create task");
        }
    }
}

#[ignore]
#[tokio::test]
async fn daemon_http_endpoint_performance_budgets() {
    let tmp = tempdir().expect("tempdir");
    let xdg = tmp.path().to_str().expect("utf8").to_string();

    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg.as_str())),
            ("CLAUDE_SESSION_ID", Some("perf-test-session")),
        ],
        || seed_workspace(tmp.path()),
    );

    let db_path = tmp.path().join("harness/daemon/harness.db");
    let db = DaemonDb::open(&db_path).expect("open db");
    temp_env::with_vars([("XDG_DATA_HOME", Some(xdg.as_str()))], || {
        db.import_from_files()
    })
    .expect("import");

    let daemon = start_test_daemon(Some(db)).await;
    let client = Client::new();

    let endpoints: Vec<(&str, &str, f64)> = vec![
        ("health", "/v1/health", 5.0),
        ("projects", "/v1/projects", 10.0),
        ("sessions", "/v1/sessions", 10.0),
        ("diagnostics", "/v1/diagnostics", 10.0),
        ("session_detail", "/v1/sessions/s1", 30.0),
        ("timeline", "/v1/sessions/s1/timeline", 50.0),
    ];

    let mut results = Vec::new();
    let mut all_passed = true;

    for (name, path, target_ms) in &endpoints {
        let url = format!("{}{}", daemon.endpoint, path);
        let mut samples = measure_endpoint(&client, &url, &daemon.token, SAMPLE_COUNT).await;
        let med = median(&mut samples);
        let passed = med <= *target_ms;
        if !passed {
            all_passed = false;
        }
        results.push(PerfResult {
            endpoint: name.to_string(),
            samples_ms: samples,
            median_ms: med,
            target_ms: *target_ms,
            passed,
        });
    }

    let perf_dir = std::path::Path::new("tmp/perf");
    let _ = fs_err::create_dir_all(perf_dir);
    let json = serde_json::to_string_pretty(&results).expect("serialize results");
    let _ = fs_err::write(perf_dir.join("daemon-http-perf.json"), &json);

    for result in &results {
        let status = if result.passed { "PASS" } else { "FAIL" };
        println!(
            "{}: median {:.2}ms (target <{:.0}ms) [{}]",
            result.endpoint, result.median_ms, result.target_ms, status
        );
    }

    assert!(
        all_passed,
        "one or more endpoints exceeded performance budget"
    );
}

/// Measure `status_report()` which is the CLI `daemon status` code path.
/// Uses SQLite when the DB exists, file-based discovery otherwise.
#[ignore]
#[test]
fn daemon_status_report_within_budget() {
    let tmp = tempdir().expect("tempdir");
    let xdg = tmp.path().to_str().expect("utf8").to_string();

    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg.as_str())),
            ("CLAUDE_SESSION_ID", Some("status-perf-session")),
        ],
        || {
            state::ensure_daemon_dirs().expect("dirs");
            let project = tmp.path().join("project");
            fs_err::create_dir_all(&project).expect("create project");
            std::process::Command::new("git")
                .arg("-C")
                .arg(&project)
                .args(["init"])
                .status()
                .expect("git init");
            session_service::start_session(
                "status-perf",
                "",
                &project,
                Some("claude"),
                Some("sp1"),
            )
            .expect("start session");
        },
    );

    // Import into DB so status_report uses SQLite path.
    let db_path = tmp.path().join("harness/daemon/harness.db");
    let db = DaemonDb::open(&db_path).expect("open db");
    temp_env::with_vars([("XDG_DATA_HOME", Some(xdg.as_str()))], || {
        db.import_from_files()
    })
    .expect("import");
    drop(db);

    let target_ms = 100.0;
    let mut samples = Vec::with_capacity(SAMPLE_COUNT);

    for _ in 0..SAMPLE_COUNT {
        let start = Instant::now();
        temp_env::with_vars([("XDG_DATA_HOME", Some(xdg.as_str()))], || {
            service::status_report()
        })
        .expect("status report");
        samples.push(start.elapsed().as_secs_f64() * 1000.0);
    }

    let med = median(&mut samples);
    println!("status_report: median {med:.2}ms (target <{target_ms:.0}ms)");
    assert!(
        med <= target_ms,
        "status_report median {med:.2}ms exceeds {target_ms:.0}ms budget"
    );
}
