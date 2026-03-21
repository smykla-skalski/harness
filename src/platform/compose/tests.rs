use std::fs;

use super::*;

#[test]
fn single_zone_produces_valid_yaml() {
    let compose = single_zone(
        "kuma-cp:latest",
        "harness-net",
        "172.57.0.0/16",
        "memory",
        "cp",
    );
    let yaml = compose.to_yaml().unwrap();
    assert!(yaml.contains("kuma-cp:latest"));
    assert!(yaml.contains("harness-net"));
    assert!(yaml.contains("KUMA_ENVIRONMENT"));
    assert!(yaml.contains("5681:5681"));
    assert!(!yaml.contains("postgres"));
}

#[test]
fn single_zone_with_postgres() {
    let compose = single_zone("kuma-cp:latest", "net", "172.57.0.0/16", "postgres", "cp");
    let yaml = compose.to_yaml().unwrap();
    assert!(yaml.contains("postgres"));
    assert!(yaml.contains("KUMA_STORE_POSTGRES_HOST"));
    assert!(compose.services.contains_key("postgres"));
}

#[test]
fn global_zone_produces_both_services() {
    let compose = global_zone(
        "kuma-cp:latest",
        "net",
        "172.57.0.0/16",
        "memory",
        "global-cp",
        "zone-cp",
        "zone-1",
    );
    let yaml = compose.to_yaml().unwrap();
    assert!(yaml.contains("global-cp"));
    assert!(yaml.contains("zone-cp"));
    assert!(yaml.contains("KUMA_MODE: global"));
    assert!(yaml.contains("KUMA_MODE: zone"));
    assert!(yaml.contains("zone-1"));
    assert!(yaml.contains("grpcs://global-cp:5685"));
}

#[test]
fn global_two_zones_produces_three_services() {
    let compose = global_two_zones(GlobalTwoZonesConfig {
        image: "kuma-cp:latest",
        network_name: "net",
        subnet: "172.57.0.0/16",
        store_type: "memory",
        global_name: "global-cp",
        zone1: ZoneConfig {
            name: "zone-1-cp",
            label: "zone-1",
        },
        zone2: ZoneConfig {
            name: "zone-2-cp",
            label: "zone-2",
        },
    });
    assert!(compose.services.contains_key("global-cp"));
    assert!(compose.services.contains_key("zone-1-cp"));
    assert!(compose.services.contains_key("zone-2-cp"));
    let z1 = &compose.services["zone-1-cp"];
    assert!(z1.ports.contains(&"15681:5681".into()));
    let z2 = &compose.services["zone-2-cp"];
    assert!(z2.ports.contains(&"25681:5681".into()));
}

#[test]
fn compose_file_deterministic_output() {
    let c1 = single_zone("img", "net", "172.57.0.0/16", "memory", "cp");
    let c2 = single_zone("img", "net", "172.57.0.0/16", "memory", "cp");
    assert_eq!(c1.to_yaml().unwrap(), c2.to_yaml().unwrap());
}

#[test]
fn compose_file_writes_to_disk() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("docker-compose.yaml");
    let compose = single_zone("img", "net", "172.57.0.0/16", "memory", "cp");
    compose.write_to(&path).unwrap();
    let content = fs::read_to_string(&path).unwrap();
    assert!(content.contains("img"));
}

#[test]
fn network_has_ipam_config() {
    let compose = single_zone("img", "harness-net", "172.57.0.0/16", "memory", "cp");
    let net = &compose.networks["harness-net"];
    let ipam = net.ipam.as_ref().unwrap();
    assert_eq!(net.driver, "bridge");
    assert_eq!(ipam.config[0].subnet, "172.57.0.0/16");
}

#[test]
fn global_zone_zone_uses_memory_store_even_with_postgres_global() {
    let compose = global_zone(
        "img",
        "net",
        "172.57.0.0/16",
        "postgres",
        "global-cp",
        "zone-cp",
        "zone-1",
    );
    let zone_env = &compose.services["zone-cp"].environment;
    let global_env = &compose.services["global-cp"].environment;
    assert_eq!(zone_env.get("KUMA_STORE_TYPE").unwrap(), "memory");
    assert_eq!(global_env.get("KUMA_STORE_TYPE").unwrap(), "postgres");
}
