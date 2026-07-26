use std::collections::BTreeMap;

use super::model::{CreateInfo, Feature, FeatureInfo};

pub(super) fn features() -> BTreeMap<Feature, FeatureInfo> {
    let mut map = core_features();
    map.extend(extended_features());
    map.extend(operational_features());
    map
}

fn core_features() -> BTreeMap<Feature, FeatureInfo> {
    BTreeMap::from([
        (
            Feature::Bootstrap,
            FeatureInfo::new("initialize a test run with cluster and session context")
                .command("harness setup bootstrap"),
        ),
        (
            Feature::JsonDiff,
            FeatureInfo::new("key-by-key JSON diff between two payloads")
                .command("harness run diff"),
        ),
    ])
}

fn extended_features() -> BTreeMap<Feature, FeatureInfo> {
    BTreeMap::from([
        (
            Feature::Observation,
            FeatureInfo::new("session monitoring through doctor, scan, watch, and dump").commands(
                &[
                    "harness observe doctor",
                    "harness observe scan",
                    "harness observe watch",
                    "harness observe dump",
                ],
            ),
        ),
        (
            Feature::PreCompactHandoff,
            FeatureInfo::new("context compaction before session handoff")
                .command("harness-hook pre-compact"),
        ),
        (
            Feature::ProgressHeartbeat,
            FeatureInfo::new("30-second heartbeat during long operations to signal liveness"),
        ),
        (
            Feature::RunLifecycle,
            FeatureInfo::new("full run lifecycle: start, resume, execute, report, finish")
                .commands(&[
                    "harness run start",
                    "harness run resume",
                    "harness run finish",
                    "harness run doctor",
                    "harness run repair",
                    "harness run init",
                    "harness run preflight",
                    "harness run runner-state",
                    "harness run report group",
                    "harness run report check",
                    "harness run closeout",
                ]),
        ),
        (
            Feature::SessionLifecycle,
            FeatureInfo::new(
                "start and stop session boundaries for observation and state tracking",
            )
            .commands(&["harness-hook session-start", "harness-hook session-stop"]),
        ),
        (
            Feature::TaskManagement,
            FeatureInfo::new("background task polling and log tailing for long-running operations")
                .commands(&["harness run task wait", "harness run task tail"]),
        ),
        (
            Feature::TrackedRecording,
            FeatureInfo::new("record arbitrary shell commands with stdout capture and audit trail")
                .command("harness run record"),
        ),
    ])
}

fn operational_features() -> BTreeMap<Feature, FeatureInfo> {
    BTreeMap::from([
        (
            Feature::BugFoundGate,
            FeatureInfo::new("KSR016 enforcement during Phase 4+ to gate on discovered bugs"),
        ),
        (
            Feature::GlobalDelay,
            FeatureInfo::new("--delay flag for pre-command sleep on any harness invocation"),
        ),
        (
            Feature::HookSystem,
            FeatureInfo::new(
                "tool-lifecycle hooks tool-guard and tool-result, plus the \
                 audit-turn notification shim",
            )
            .command("harness-hook"),
        ),
        (
            Feature::IdempotentGroupReporting,
            FeatureInfo::new("report group accepts re-reports gracefully without duplication")
                .command("harness run report group"),
        ),
    ])
}

pub(super) fn create() -> CreateInfo {
    CreateInfo {
        available: true,
        commands: vec![
            "harness create begin".into(),
            "harness create save".into(),
            "harness create show".into(),
            "harness create reset".into(),
            "harness create validate".into(),
            "harness create approval-begin".into(),
        ],
        description: "interactive suite create with discovery workers and approval gates".into(),
    }
}
