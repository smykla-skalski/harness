use std::collections::BTreeMap;

use super::model::{Feature, FeatureInfo};

pub(super) fn features() -> BTreeMap<Feature, FeatureInfo> {
    let mut map = cli_features();
    map.extend(hook_features());
    map
}

fn cli_features() -> BTreeMap<Feature, FeatureInfo> {
    BTreeMap::from([
        (
            Feature::Bootstrap,
            FeatureInfo::new("install the repo-aware wrapper and agent hook configs")
                .command("harness setup bootstrap"),
        ),
        (
            Feature::GlobalDelay,
            FeatureInfo::new("--delay flag for pre-command sleep on any harness invocation"),
        ),
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
            Feature::ProgressHeartbeat,
            FeatureInfo::new("30-second heartbeat during long operations to signal liveness"),
        ),
    ])
}

fn hook_features() -> BTreeMap<Feature, FeatureInfo> {
    BTreeMap::from([
        (
            Feature::HookSystem,
            FeatureInfo::new(
                "tool-lifecycle hooks tool-guard and tool-result, plus the \
                 audit-turn notification shim",
            )
            .commands(&[
                "harness-hook tool-guard",
                "harness-hook tool-result",
                "harness-hook audit-turn",
            ]),
        ),
        (
            Feature::PreCompactHandoff,
            FeatureInfo::new("context compaction before session handoff")
                .command("harness-hook pre-compact"),
        ),
        (
            Feature::SessionLifecycle,
            FeatureInfo::new(
                "start and stop session boundaries for observation and state tracking",
            )
            .commands(&["harness-hook session-start", "harness-hook session-stop"]),
        ),
    ])
}
