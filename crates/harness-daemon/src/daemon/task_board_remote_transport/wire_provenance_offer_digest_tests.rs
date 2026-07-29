use super::super::wire::RemoteWireError;

pub(super) fn assert_request_offer_digest<Request: Clone>(
    request: &Request,
    validate: impl Fn(&Request) -> Result<(), RemoteWireError>,
    replace_offer_digest: impl Fn(&mut Request, String),
) {
    validate(request).expect("valid lifecycle request");
    for invalid in [
        String::new(),
        "D".repeat(64),
        format!("sha256:{}", "d".repeat(64)),
    ] {
        let mut noncanonical = request.clone();
        replace_offer_digest(&mut noncanonical, invalid);
        assert_eq!(
            validate(&noncanonical).expect_err("noncanonical offer digest denied"),
            RemoteWireError::InvalidDigest("offer_request_sha256")
        );
    }
    let mut tampered = request.clone();
    replace_offer_digest(&mut tampered, "d".repeat(64));
    assert_eq!(
        validate(&tampered).expect_err("changed offer digest denied"),
        RemoteWireError::DigestMismatch("request_sha256")
    );
}

pub(super) fn assert_response_offer_digest<Response: Clone, Request, Validated>(
    response: &Response,
    request: &Request,
    validate: impl Fn(&Response, &Request) -> Result<Validated, RemoteWireError>,
    replace_offer_digest: impl Fn(&mut Response, String),
) {
    validate(response, request).expect("valid lifecycle response");
    for invalid in [
        String::new(),
        "D".repeat(64),
        format!("sha256:{}", "d".repeat(64)),
    ] {
        let mut noncanonical = response.clone();
        replace_offer_digest(&mut noncanonical, invalid);
        assert_eq!(
            validate(&noncanonical, request)
                .err()
                .expect("noncanonical echo denied"),
            RemoteWireError::InvalidDigest("offer_request_sha256")
        );
    }
    let mut replay = response.clone();
    replace_offer_digest(&mut replay, "d".repeat(64));
    assert_eq!(
        validate(&replay, request)
            .err()
            .expect("different offer echo denied"),
        RemoteWireError::ResultBindingMismatch
    );
}
