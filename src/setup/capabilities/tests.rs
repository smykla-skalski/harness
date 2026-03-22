use crate::kernel::topology::Platform;

use super::capabilities;
use super::data::{cluster_topologies, create, features, platforms};
use super::model::{CapabilitiesReport, Feature};

#[test]
fn capabilities_returns_zero() {
    assert_eq!(capabilities().unwrap(), 0);
}

#[test]
fn output_contains_expected_sections() {
    let caps = CapabilitiesReport {
        create: create(),
        cluster_topologies: cluster_topologies(),
        features: features(),
        platforms: platforms(),
    };
    assert!(caps.create.available);
    assert!(!caps.cluster_topologies.is_empty());
    assert!(!caps.features.is_empty());
    assert!(!caps.platforms.is_empty());
}

#[test]
fn platforms_lists_both() {
    let platform_list = platforms();
    let names: Vec<Platform> = platform_list.iter().map(|info| info.name).collect();
    assert!(names.contains(&Platform::Kubernetes));
    assert!(names.contains(&Platform::Universal));
}

#[test]
fn features_include_universal_only_items() {
    let feature_map = features();
    let tokens = feature_map.get(&Feature::DataplaneTokens).unwrap();
    assert!(tokens.available);
    let platforms = tokens.platforms.as_ref().unwrap();
    assert_eq!(platforms.len(), 1);
    assert_eq!(platforms[0], Platform::Universal);
}

#[test]
fn lifecycle_features_use_top_level_commands() {
    let feature_map = features();
    let pre_compact = feature_map.get(&Feature::PreCompactHandoff).unwrap();
    assert_eq!(pre_compact.command.as_deref(), Some("harness pre-compact"));

    let session = feature_map.get(&Feature::SessionLifecycle).unwrap();
    assert_eq!(
        session.commands.as_deref(),
        Some(
            &[
                "harness session-start".to_string(),
                "harness session-stop".to_string(),
            ][..]
        )
    );
}

#[test]
fn json_round_trip() {
    let caps = CapabilitiesReport {
        create: create(),
        cluster_topologies: cluster_topologies(),
        features: features(),
        platforms: platforms(),
    };
    let json = serde_json::to_string(&caps).unwrap();
    let deserialized: CapabilitiesReport = serde_json::from_str(&json).unwrap();
    assert_eq!(caps, deserialized);
}

#[test]
fn features_include_api_cluster_bootstrap() {
    let feature_map = features();
    assert!(feature_map.contains_key(&Feature::ApiAccess));
    assert!(feature_map.contains_key(&Feature::Bootstrap));
    assert!(feature_map.contains_key(&Feature::ClusterManagement));
}

#[test]
fn feature_count_is_current() {
    let feature_map = features();
    assert_eq!(
        feature_map.len(),
        30,
        "feature count changed - update this test"
    );
}

#[test]
fn feature_keys_are_snake_case() {
    let feature_map = features();
    let value = serde_json::to_value(&feature_map).unwrap();
    let map = value.as_object().unwrap();
    for key in map.keys() {
        assert!(
            key.chars()
                .all(|character| character.is_ascii_lowercase() || character == '_'),
            "feature key {key:?} is not snake_case"
        );
    }
}
