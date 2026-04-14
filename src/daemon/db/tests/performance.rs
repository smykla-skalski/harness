use super::*;

    #[test]
    fn health_counts_meets_performance_budget() {
        let db = seeded_performance_db(16, 8);

        median_runtime_budget_ms("health_counts", 31, 5, || {
            let counts = db.health_counts().expect("health counts");
            assert_eq!(counts.0, 16);
            assert_eq!(counts.2, 128);
        });
    }

    #[test]
    fn list_project_summaries_meets_performance_budget() {
        let db = seeded_performance_db(16, 8);

        median_runtime_budget_ms("list_project_summaries", 21, 20, || {
            let summaries = db.list_project_summaries().expect("project summaries");
            assert_eq!(summaries.len(), 16);
        });
    }

    #[test]
    fn list_session_summaries_full_meets_performance_budget() {
        let db = seeded_performance_db(16, 8);

        median_runtime_budget_ms("list_session_summaries_full", 21, 35, || {
            let summaries = db.list_session_summaries_full().expect("session summaries");
            assert_eq!(summaries.len(), 128);
        });
    }

    #[test]
    fn resolve_session_meets_performance_budget() {
        let db = seeded_performance_db(16, 8);

        median_runtime_budget_ms("resolve_session", 31, 10, || {
            let resolved = db
                .resolve_session("sess-7-5")
                .expect("resolve session")
                .expect("session present");
            assert_eq!(resolved.state.session_id, "sess-7-5");
        });
    }

    #[test]
    fn extract_transition_kind_parses_tagged_enum() {
        let json = r#"{"SessionStarted":{"context":"test"}}"#;
        assert_eq!(extract_transition_kind(json), "SessionStarted");
    }

    #[test]
    fn extract_transition_kind_parses_unit_variant() {
        let json = r#""SessionEnded""#;
        assert_eq!(extract_transition_kind(json), "SessionEnded");
    }
