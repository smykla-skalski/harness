use std::collections::BTreeMap;

use crate::infra::blocks::compose::{
    ComposeTopology, HealthcheckSpec, NetworkSpec, ServiceDependency, ServiceSpec,
};

/// Input describing a single Kuma control-plane service in a compose recipe.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KumaControlPlaneSpec {
    pub name: String,
    pub image: String,
    pub mode: String,
    pub zone: Option<String>,
    pub env: BTreeMap<String, String>,
    pub ports: Vec<(u16, u16)>,
    pub depends_on: Vec<ServiceDependency>,
}

/// Input describing an optional Postgres backing service used by some universal
/// layouts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KumaPostgresSpec {
    pub service_name: String,
    pub image: String,
    pub database: String,
    pub user: String,
    pub password: String,
}

/// Kuma-specific compose recipe input.
///
/// This intentionally models only the Kuma-layer concerns. Rendering into the
/// generic `ComposeTopology` is handled by the helper functions below.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KumaComposeRecipe {
    pub project_name: String,
    pub network_name: String,
    pub subnet: String,
    pub control_planes: Vec<KumaControlPlaneSpec>,
    pub postgres: Option<KumaPostgresSpec>,
}

impl KumaComposeRecipe {
    #[must_use]
    pub fn to_topology(&self) -> ComposeTopology {
        let mut services = Vec::new();

        if let Some(postgres) = &self.postgres {
            services.push(postgres_service(postgres));
        }

        services.extend(self.control_planes.iter().map(control_plane_service));

        ComposeTopology {
            project_name: self.project_name.clone(),
            network: NetworkSpec {
                name: self.network_name.clone(),
                subnet: self.subnet.clone(),
            },
            services,
        }
    }
}

/// Build a single-zone Kuma universal compose topology recipe.
#[must_use]
pub fn single_zone_recipe(
    project_name: impl Into<String>,
    network_name: impl Into<String>,
    subnet: impl Into<String>,
    control_plane_name: impl Into<String>,
    image: impl Into<String>,
    store_type: impl Into<String>,
) -> KumaComposeRecipe {
    let store_type = store_type.into();
    let postgres = (store_type == "postgres").then_some(default_postgres_spec());

    let mut env = base_cp_env("zone", &store_type);
    env.insert("KUMA_MODE".to_string(), "zone".to_string());

    KumaComposeRecipe {
        project_name: project_name.into(),
        network_name: network_name.into(),
        subnet: subnet.into(),
        control_planes: vec![KumaControlPlaneSpec {
            name: control_plane_name.into(),
            image: image.into(),
            mode: "zone".to_string(),
            zone: None,
            env,
            ports: vec![(5681, 5681), (5678, 5678)],
            depends_on: postgres
                .as_ref()
                .map(|pg| {
                    vec![ServiceDependency {
                        service_name: pg.service_name.clone(),
                        condition: Some("service_healthy".to_string()),
                    }]
                })
                .unwrap_or_default(),
        }],
        postgres,
    }
}

/// Common base parameters shared across multi-zone compose recipe builders.
pub struct RecipeBase {
    pub project_name: String,
    pub network_name: String,
    pub subnet: String,
    pub image: String,
    pub store_type: String,
}

/// Build a global+two-zones Kuma universal compose topology recipe.
#[must_use]
pub fn global_two_zones_recipe(
    base: RecipeBase,
    global_name: impl Into<String>,
    zone1_name: impl Into<String>,
    zone2_name: impl Into<String>,
    zone1_label: impl Into<String>,
    zone2_label: impl Into<String>,
) -> KumaComposeRecipe {
    let project_name = base.project_name;
    let network_name = base.network_name;
    let subnet = base.subnet;
    let global_name = global_name.into();
    let zone1_name = zone1_name.into();
    let zone2_name = zone2_name.into();
    let zone1_label = zone1_label.into();
    let zone2_label = zone2_label.into();
    let image = base.image;
    let store_type = base.store_type;

    let postgres = (store_type == "postgres").then_some(default_postgres_spec());

    let global_depends_on = postgres
        .as_ref()
        .map(|pg| {
            vec![ServiceDependency {
                service_name: pg.service_name.clone(),
                condition: Some("service_healthy".to_string()),
            }]
        })
        .unwrap_or_default();

    let zone_dependency = ServiceDependency {
        service_name: global_name.clone(),
        condition: Some("service_started".to_string()),
    };

    let mut global_env = base_cp_env("global", &store_type);
    global_env.insert("KUMA_MODE".to_string(), "global".to_string());

    let mut zone1_env = base_cp_env("zone", &store_type);
    zone1_env.insert("KUMA_MODE".to_string(), "zone".to_string());
    zone1_env.insert("KUMA_ZONE".to_string(), zone1_label.clone());

    let mut zone2_env = base_cp_env("zone", &store_type);
    zone2_env.insert("KUMA_MODE".to_string(), "zone".to_string());
    zone2_env.insert("KUMA_ZONE".to_string(), zone2_label.clone());

    KumaComposeRecipe {
        project_name,
        network_name,
        subnet,
        control_planes: vec![
            KumaControlPlaneSpec {
                name: global_name,
                image: image.clone(),
                mode: "global".to_string(),
                zone: None,
                env: global_env,
                ports: vec![(5681, 5681), (5678, 5678)],
                depends_on: global_depends_on,
            },
            KumaControlPlaneSpec {
                name: zone1_name,
                image: image.clone(),
                mode: "zone".to_string(),
                zone: Some(zone1_label),
                env: zone1_env,
                ports: vec![],
                depends_on: vec![zone_dependency.clone()],
            },
            KumaControlPlaneSpec {
                name: zone2_name,
                image,
                mode: "zone".to_string(),
                zone: Some(zone2_label),
                env: zone2_env,
                ports: vec![],
                depends_on: vec![zone_dependency],
            },
        ],
        postgres,
    }
}

fn control_plane_service(spec: &KumaControlPlaneSpec) -> ServiceSpec {
    ServiceSpec {
        name: spec.name.clone(),
        image: spec.image.clone(),
        environment: spec.env.clone(),
        ports: spec.ports.clone(),
        command: vec!["run".to_string()],
        entrypoint: None,
        depends_on: spec.depends_on.clone(),
        healthcheck: Some(default_cp_healthcheck()),
        restart: Some("unless-stopped".to_string()),
    }
}

fn postgres_service(spec: &KumaPostgresSpec) -> ServiceSpec {
    let mut environment = BTreeMap::new();
    environment.insert("POSTGRES_DB".to_string(), spec.database.clone());
    environment.insert("POSTGRES_USER".to_string(), spec.user.clone());
    environment.insert("POSTGRES_PASSWORD".to_string(), spec.password.clone());

    ServiceSpec {
        name: spec.service_name.clone(),
        image: spec.image.clone(),
        environment,
        ports: vec![],
        command: Vec::new(),
        entrypoint: None,
        depends_on: Vec::new(),
        healthcheck: Some(HealthcheckSpec {
            test: vec![
                "CMD-SHELL".to_string(),
                "pg_isready -U $POSTGRES_USER -d $POSTGRES_DB".to_string(),
            ],
            interval_seconds: Some(5),
            timeout_seconds: Some(5),
            retries: Some(20),
            start_period_seconds: Some(5),
        }),
        restart: Some("unless-stopped".to_string()),
    }
}

fn default_cp_healthcheck() -> HealthcheckSpec {
    HealthcheckSpec {
        test: vec![
            "CMD-SHELL".to_string(),
            "wget -q -O - http://127.0.0.1:5681 >/dev/null 2>&1 || exit 1".to_string(),
        ],
        interval_seconds: Some(5),
        timeout_seconds: Some(5),
        retries: Some(24),
        start_period_seconds: Some(10),
    }
}

fn base_cp_env(mode: &str, store_type: &str) -> BTreeMap<String, String> {
    let mut env = BTreeMap::new();
    env.insert("KUMA_ENVIRONMENT".to_string(), "universal".to_string());
    env.insert("KUMA_MODE".to_string(), mode.to_string());
    env.insert("KUMA_STORE_TYPE".to_string(), store_type.to_string());
    env
}

fn default_postgres_spec() -> KumaPostgresSpec {
    KumaPostgresSpec {
        service_name: "postgres".to_string(),
        image: "postgres:16".to_string(),
        database: "kuma".to_string(),
        user: "kuma".to_string(),
        password: "kuma".to_string(),
    }
}

#[cfg(test)]
mod tests;
