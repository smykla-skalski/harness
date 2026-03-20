use super::*;

#[test]
fn dataplane_collection_extracts_known_fields() {
    let value = serde_json::json!({
        "total": 1,
        "items": [
            {
                "name": "dp-1",
                "mesh": "default",
                "networking": {
                    "address": "192.0.2.10"
                },
                "healthy": true
            }
        ]
    });

    let collection = UniversalDataplaneCollection::from_api_value(value);

    assert_eq!(collection.items.len(), 1);
    assert_eq!(collection.items[0].name, "dp-1");
    assert_eq!(collection.items[0].mesh.as_deref(), Some("default"));
    assert_eq!(collection.items[0].address.as_deref(), Some("192.0.2.10"));
    assert_eq!(
        collection.items[0].extra.get("healthy"),
        Some(&serde_json::Value::Bool(true))
    );
    assert_eq!(
        collection.extra.get("total"),
        Some(&serde_json::Value::from(1))
    );
}

#[test]
fn dataplane_snapshot_reads_nested_meta_fields() {
    let value = serde_json::json!({
        "meta": {
            "name": "dp-2",
            "mesh": "demo"
        },
        "dataplane": {
            "networking": {
                "address": "198.51.100.8"
            }
        }
    });

    let snapshot = UniversalDataplaneSnapshot::from_api_value(value);

    assert_eq!(snapshot.name, "dp-2");
    assert_eq!(snapshot.mesh.as_deref(), Some("demo"));
    assert_eq!(snapshot.address.as_deref(), Some("198.51.100.8"));
}
