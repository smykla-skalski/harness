use std::collections::BTreeMap;

use super::{
    ComposeDependsOn, ComposeDependsOnEntry, ComposeFile, ComposeHealthcheck, ComposeIpam,
    ComposeIpamConfig, ComposeNetwork, ComposeService,
};

/// Generate a compose file for single-zone universal topology.
#[must_use]
pub fn single_zone(
    image: &str,
    network_name: &str,
    subnet: &str,
    store_type: &str,
    cp_name: &str,
) -> ComposeFile {
    let mut services = BTreeMap::new();
    let mut env = cp_env("zone", store_type);
    if store_type == "postgres" {
        postgres_cp_env(&mut env);
    }

    let (depends_on, is_postgres) = if store_type == "postgres" {
        services.insert("postgres".into(), postgres_service(network_name));
        let mut deps = BTreeMap::new();
        deps.insert(
            "postgres".into(),
            ComposeDependsOnEntry {
                condition: "service_healthy".into(),
            },
        );
        (ComposeDependsOn::Conditional(deps), true)
    } else {
        (ComposeDependsOn::Simple(vec![]), false)
    };

    let mut service = ComposeService::new(image, network_name)
        .with_environment(env)
        .with_ports(vec!["5681:5681".into(), "5678:5678".into()])
        .with_depends_on(depends_on)
        .with_command(cp_command(store_type));
    if let Some(ep) = cp_entrypoint(store_type) {
        service = service.with_entrypoint(ep);
    }
    if is_postgres {
        service = service.with_restart("on-failure");
    }
    services.insert(cp_name.into(), service);

    let mut networks = BTreeMap::new();
    networks.insert(network_name.into(), bridge_network(subnet));
    ComposeFile { services, networks }
}

/// Generate a compose file for global+zone universal topology.
#[must_use]
pub fn global_zone(
    image: &str,
    network_name: &str,
    subnet: &str,
    store_type: &str,
    global_name: &str,
    zone_name: &str,
    zone_label: &str,
) -> ComposeFile {
    let mut services = BTreeMap::new();

    let mut global_env = cp_env("global", store_type);
    let (global_depends, is_postgres) = postgres_depends(store_type, network_name, &mut services);

    if store_type == "postgres" {
        postgres_cp_env(&mut global_env);
    }

    let mut global_service = ComposeService::new(image, network_name)
        .with_environment(global_env)
        .with_ports(vec!["5681:5681".into(), "5685:5685".into()])
        .with_depends_on(global_depends)
        .with_command(cp_command(store_type));
    if let Some(ep) = cp_entrypoint(store_type) {
        global_service = global_service.with_entrypoint(ep);
    }
    if is_postgres {
        global_service = global_service.with_restart("on-failure");
    }
    services.insert(global_name.into(), global_service);

    let mut zone_env = cp_env("zone", "memory");
    zone_env.insert("KUMA_MULTIZONE_ZONE_NAME".into(), zone_label.into());
    zone_env.insert(
        "KUMA_MULTIZONE_ZONE_GLOBAL_ADDRESS".into(),
        format!("grpcs://{global_name}:5685"),
    );
    zone_env.insert(
        "KUMA_MULTIZONE_ZONE_KDS_TLS_SKIP_VERIFY".into(),
        "true".into(),
    );

    let zone_service = ComposeService::new(image, network_name)
        .with_environment(zone_env)
        .with_ports(vec!["15681:5681".into(), "15678:5678".into()])
        .with_depends_on(ComposeDependsOn::Simple(vec![global_name.into()]))
        .with_command(vec!["run".into()]);
    services.insert(zone_name.into(), zone_service);

    let mut networks = BTreeMap::new();
    networks.insert(network_name.into(), bridge_network(subnet));
    ComposeFile { services, networks }
}

/// Zone settings for multi-zone compose generation.
#[derive(Debug, Clone, Copy)]
pub struct ZoneConfig<'a> {
    pub name: &'a str,
    pub label: &'a str,
}

/// Config for global+two-zones universal topology.
#[derive(Debug, Clone, Copy)]
pub struct GlobalTwoZonesConfig<'a> {
    pub image: &'a str,
    pub network_name: &'a str,
    pub subnet: &'a str,
    pub store_type: &'a str,
    pub global_name: &'a str,
    pub zone1: ZoneConfig<'a>,
    pub zone2: ZoneConfig<'a>,
}

/// Generate a compose file for global+two-zones universal topology.
#[must_use]
pub fn global_two_zones(config: GlobalTwoZonesConfig<'_>) -> ComposeFile {
    let mut services = BTreeMap::new();

    let mut global_env = cp_env("global", config.store_type);
    let (global_depends, is_postgres) =
        postgres_depends(config.store_type, config.network_name, &mut services);

    if config.store_type == "postgres" {
        postgres_cp_env(&mut global_env);
    }

    let mut global_service = ComposeService::new(config.image, config.network_name)
        .with_environment(global_env)
        .with_ports(vec!["5681:5681".into(), "5685:5685".into()])
        .with_depends_on(global_depends)
        .with_command(cp_command(config.store_type));
    if let Some(ep) = cp_entrypoint(config.store_type) {
        global_service = global_service.with_entrypoint(ep);
    }
    if is_postgres {
        global_service = global_service.with_restart("on-failure");
    }
    services.insert(config.global_name.into(), global_service);

    for (i, zone) in [config.zone1, config.zone2].iter().enumerate() {
        let port_offset = u16::try_from(i).unwrap_or(0) * 10000 + 15681;
        let xds_offset = u16::try_from(i).unwrap_or(0) * 10000 + 15678;

        let mut zone_env = cp_env("zone", "memory");
        zone_env.insert("KUMA_MULTIZONE_ZONE_NAME".into(), zone.label.into());
        zone_env.insert(
            "KUMA_MULTIZONE_ZONE_GLOBAL_ADDRESS".into(),
            format!("grpcs://{}:5685", config.global_name),
        );
        zone_env.insert(
            "KUMA_MULTIZONE_ZONE_KDS_TLS_SKIP_VERIFY".into(),
            "true".into(),
        );

        let zone_service = ComposeService::new(config.image, config.network_name)
            .with_environment(zone_env)
            .with_ports(vec![
                format!("{port_offset}:5681"),
                format!("{xds_offset}:5678"),
            ])
            .with_depends_on(ComposeDependsOn::Simple(vec![config.global_name.into()]))
            .with_command(vec!["run".into()]);
        services.insert(zone.name.into(), zone_service);
    }

    let mut networks = BTreeMap::new();
    networks.insert(config.network_name.into(), bridge_network(config.subnet));
    ComposeFile { services, networks }
}

/// Build `depends_on` for postgres-backed CP services. Returns whether postgres is used.
fn postgres_depends(
    store_type: &str,
    network_name: &str,
    services: &mut BTreeMap<String, ComposeService>,
) -> (ComposeDependsOn, bool) {
    if store_type != "postgres" {
        return (ComposeDependsOn::Simple(vec![]), false);
    }
    services.insert("postgres".into(), postgres_service(network_name));
    let mut deps = BTreeMap::new();
    deps.insert(
        "postgres".into(),
        ComposeDependsOnEntry {
            condition: "service_healthy".into(),
        },
    );
    (ComposeDependsOn::Conditional(deps), true)
}

fn bridge_network(subnet: &str) -> ComposeNetwork {
    ComposeNetwork {
        driver: "bridge".into(),
        ipam: Some(ComposeIpam {
            config: vec![ComposeIpamConfig {
                subnet: subnet.into(),
            }],
        }),
    }
}

fn cp_env(kuma_mode: &str, store_type: &str) -> BTreeMap<String, String> {
    let mut env = BTreeMap::new();
    env.insert("KUMA_ENVIRONMENT".into(), "universal".into());
    env.insert("KUMA_MODE".into(), kuma_mode.into());
    env.insert("KUMA_STORE_TYPE".into(), store_type.into());
    env
}

fn postgres_cp_env(env: &mut BTreeMap<String, String>) {
    env.insert("KUMA_STORE_POSTGRES_HOST".into(), "postgres".into());
    env.insert("KUMA_STORE_POSTGRES_PORT".into(), "5432".into());
    env.insert("KUMA_STORE_POSTGRES_USER".into(), "kuma".into());
    env.insert("KUMA_STORE_POSTGRES_PASSWORD".into(), "kuma".into());
    env.insert("KUMA_STORE_POSTGRES_DB_NAME".into(), "kuma".into());
}

/// Command args for a CP service. Postgres needs migration before run.
fn cp_command(store_type: &str) -> Vec<String> {
    if store_type == "postgres" {
        vec!["kuma-cp migrate up && kuma-cp run".into()]
    } else {
        vec!["run".into()]
    }
}

/// Entrypoint override for CP services. Postgres needs sh to chain commands.
fn cp_entrypoint(store_type: &str) -> Option<Vec<String>> {
    if store_type == "postgres" {
        Some(vec!["sh".into(), "-c".into()])
    } else {
        None
    }
}

fn postgres_service(network_name: &str) -> ComposeService {
    let mut env = BTreeMap::new();
    env.insert("POSTGRES_USER".into(), "kuma".into());
    env.insert("POSTGRES_PASSWORD".into(), "kuma".into());
    env.insert("POSTGRES_DB".into(), "kuma".into());
    ComposeService::new("postgres:16-alpine", network_name)
        .with_environment(env)
        .with_ports(vec!["5432:5432".into()])
        .with_healthcheck(ComposeHealthcheck {
            test: vec!["CMD-SHELL".into(), "pg_isready -U kuma -d kuma".into()],
            interval: "2s".into(),
            timeout: "5s".into(),
            retries: 10,
        })
}
