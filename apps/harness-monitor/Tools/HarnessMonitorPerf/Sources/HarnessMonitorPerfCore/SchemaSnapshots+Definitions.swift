import Foundation

extension SchemaSnapshots {
    static func document(
        fileName: String,
        title: String,
        required: [String],
        properties: RawSchema,
        additionalProperties: Any = false,
        defs: RawSchema? = nil
    ) -> RawSchema {
        var schema = object(
            required: required,
            properties: properties,
            additionalProperties: additionalProperties
        )
        schema["$schema"] = schemaDraft
        schema["$id"] = schemaBaseID + fileName
        schema["title"] = title
        if let defs { schema["$defs"] = defs }
        return schema
    }

    static func object(
        required: [String] = [],
        properties: RawSchema = [:],
        additionalProperties: Any = false,
        nullable: Bool = false
    ) -> RawSchema {
        var schema: RawSchema = [
            "type": nullable ? ["object", "null"] : "object",
            "additionalProperties": additionalProperties,
        ]
        if !required.isEmpty { schema["required"] = required }
        if !properties.isEmpty { schema["properties"] = properties }
        return schema
    }

    static func array(
        items: Any,
        nullable: Bool = false
    ) -> RawSchema {
        [
            "type": nullable ? ["array", "null"] : "array",
            "items": items,
        ]
    }

    static func scalar(
        _ type: String,
        nullable: Bool = false
    ) -> RawSchema {
        ["type": nullable ? [type, "null"] : type]
    }

    static func ref(_ path: String) -> RawSchema {
        ["$ref": path]
    }

    static func oneOf(_ values: [Any]) -> RawSchema {
        ["oneOf": values]
    }

    static func metricTiersSchema(nullable: Bool = false) -> RawSchema {
        object(
            required: ["hard_budget", "investigative"],
            properties: [
                "hard_budget": array(items: scalar("string")),
                "investigative": array(items: scalar("string")),
            ],
            nullable: nullable
        )
    }

    static func launchMetricsSchema(nullable: Bool = false) -> RawSchema {
        object(
            required: [
                "app_init_to_ready_ms",
                "measured_from",
                "state_label",
                "window_id",
                "includes_bootstrap_in_scenario_measurement",
            ],
            properties: [
                "app_init_to_ready_ms": scalar("number"),
                "measured_from": scalar("string"),
                "state_label": scalar("string"),
                "window_id": scalar("string"),
                "includes_bootstrap_in_scenario_measurement": scalar("boolean"),
            ],
            nullable: nullable
        )
    }

    static func daemonDataHomeProbeSchema() -> RawSchema {
        object(
            required: [
                "data_home",
                "exists",
                "regular_file_count",
                "total_bytes",
                "contains_daemon_manifest",
                "contains_sqlite_database",
                "contains_sqlite_wal",
                "contains_sqlite_shm",
            ],
            properties: [
                "data_home": scalar("string"),
                "exists": scalar("boolean"),
                "regular_file_count": scalar("integer"),
                "total_bytes": scalar("integer"),
                "contains_daemon_manifest": scalar("boolean"),
                "contains_sqlite_database": scalar("boolean"),
                "contains_sqlite_wal": scalar("boolean"),
                "contains_sqlite_shm": scalar("boolean"),
            ]
        )
    }
}
