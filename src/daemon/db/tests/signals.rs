use super::*;

    #[test]
    fn derive_effective_signal_status_past_expiry_flips_pending_to_expired() {
        let signal = sample_signal_record("2020-01-01T00:00:00Z");
        let status = derive_effective_signal_status(SessionSignalStatus::Pending, &signal.signal);
        assert_eq!(status, SessionSignalStatus::Expired);
    }

    #[test]
    fn derive_effective_signal_status_future_expiry_stays_pending() {
        let signal = sample_signal_record("2099-12-31T23:59:59Z");
        let status = derive_effective_signal_status(SessionSignalStatus::Pending, &signal.signal);
        assert_eq!(status, SessionSignalStatus::Pending);
    }

    #[test]
    fn derive_effective_signal_status_delivered_passes_through() {
        let signal = sample_signal_record("2020-01-01T00:00:00Z");
        let status = derive_effective_signal_status(SessionSignalStatus::Delivered, &signal.signal);
        assert_eq!(status, SessionSignalStatus::Delivered);
    }

    #[test]
    fn derive_effective_signal_status_unparseable_expiry_stays_pending() {
        let signal = sample_signal_record("not-a-timestamp");
        let status = derive_effective_signal_status(SessionSignalStatus::Pending, &signal.signal);
        assert_eq!(status, SessionSignalStatus::Pending);
    }

    #[test]
    fn load_signals_reports_expired_for_past_pending() {
        let db = DaemonDb::open_in_memory().expect("open db");
        let project = sample_project();
        db.sync_project(&project).expect("sync project");
        let state = sample_session_state();
        db.sync_session(&project.project_id, &state)
            .expect("sync session");

        let record = sample_signal_record("2020-01-01T00:00:00Z");
        db.sync_signal_index(&state.session_id, std::slice::from_ref(&record))
            .expect("sync signals");

        let loaded = db.load_signals(&state.session_id).expect("load signals");
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].status, SessionSignalStatus::Expired);
    }
