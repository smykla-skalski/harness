use bollard::errors::Error as BollardError;

use super::BollardContainerRuntime;
use crate::infra::blocks::BlockError;

#[test]
fn missing_local_image_detection_matches_engine_error() {
    let error = BlockError::new(
        "docker",
        "create_container example",
        BollardError::DockerResponseServerError {
            status_code: 404,
            message: "No such image: missing:latest".to_string(),
        },
    );

    assert!(BollardContainerRuntime::is_missing_local_image(&error));
}

#[test]
fn missing_local_image_detection_ignores_other_404s() {
    let error = BlockError::new(
        "docker",
        "create_container example",
        BollardError::DockerResponseServerError {
            status_code: 404,
            message: "network mesh-net not found".to_string(),
        },
    );

    assert!(!BollardContainerRuntime::is_missing_local_image(&error));
}

#[test]
fn removal_in_progress_detection_matches_engine_error() {
    let error = BlockError::new(
        "docker",
        "remove_container example",
        BollardError::DockerResponseServerError {
            status_code: 409,
            message: "removal of container example is already in progress".to_string(),
        },
    );

    assert!(BollardContainerRuntime::is_removal_in_progress(&error));
}

#[test]
fn removal_in_progress_detection_ignores_other_conflicts() {
    let error = BlockError::new(
        "docker",
        "remove_container example",
        BollardError::DockerResponseServerError {
            status_code: 409,
            message: "conflict: endpoint is in use".to_string(),
        },
    );

    assert!(!BollardContainerRuntime::is_removal_in_progress(&error));
}
