use serde_json::Value;

pub(crate) fn normalize_object(value: Value) -> Value {
    let mut normalized = value;
    strip_volatile_fields(&mut normalized);
    prune_noise(&mut normalized);
    normalized
}

fn strip_volatile_fields(value: &mut Value) {
    let Some(root) = value.as_object_mut() else {
        return;
    };

    root.remove("status");

    let Some(metadata) = root.get_mut("metadata").and_then(Value::as_object_mut) else {
        return;
    };

    for key in [
        "creationTimestamp",
        "managedFields",
        "resourceVersion",
        "selfLink",
        "uid",
        "generation",
    ] {
        metadata.remove(key);
    }

    if let Some(annotations) = metadata
        .get_mut("annotations")
        .and_then(Value::as_object_mut)
    {
        annotations.remove("kubectl.kubernetes.io/last-applied-configuration");
    }
}

fn prune_noise(value: &mut Value) -> bool {
    match value {
        Value::Null => true,
        Value::Object(map) => {
            let keys = map.keys().cloned().collect::<Vec<_>>();
            for key in keys {
                let remove = map.get_mut(&key).is_some_and(prune_noise);
                if remove {
                    map.remove(&key);
                }
            }
            map.is_empty()
        }
        Value::Array(values) => {
            for item in values {
                let _ = prune_noise(item);
            }
            false
        }
        Value::Bool(_) | Value::Number(_) | Value::String(_) => false,
    }
}
