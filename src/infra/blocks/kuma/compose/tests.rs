use super::*;

#[test]
fn single_zone_recipe_builds_topology() {
    let recipe = single_zone_recipe(
        "harness-demo",
        "harness-demo",
        "172.57.0.0/16",
        "cp",
        "kumahq/kuma-cp:latest",
        "memory",
    );

    let topology = recipe.to_topology();
    assert_eq!(topology.project_name, "harness-demo");
    assert_eq!(topology.network.name, "harness-demo");
    assert_eq!(topology.services.len(), 1);
    assert_eq!(topology.services[0].name, "cp");
}

#[test]
fn postgres_recipe_adds_postgres_service() {
    let recipe = single_zone_recipe(
        "harness-demo",
        "harness-demo",
        "172.57.0.0/16",
        "cp",
        "kumahq/kuma-cp:latest",
        "postgres",
    );

    let topology = recipe.to_topology();
    assert_eq!(topology.services.len(), 2);
    assert_eq!(topology.services[0].name, "postgres");
    assert_eq!(topology.services[1].name, "cp");
}

#[test]
fn global_two_zones_recipe_builds_three_control_planes() {
    let recipe = global_two_zones_recipe(
        RecipeBase {
            project_name: "mesh".into(),
            network_name: "mesh-net".into(),
            subnet: "172.57.0.0/16".into(),
            image: "kumahq/kuma-cp:latest".into(),
            store_type: "memory".into(),
        },
        "global",
        "zone-1",
        "zone-2",
        "east",
        "west",
    );

    let topology = recipe.to_topology();
    let names = topology
        .services
        .iter()
        .map(|service| service.name.as_str())
        .collect::<Vec<_>>();
    assert_eq!(names, vec!["global", "zone-1", "zone-2"]);
}
