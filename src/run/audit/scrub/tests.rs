use super::*;

#[test]
fn scrubs_pem_certificate() {
    let input =
        "before\n-----BEGIN CERTIFICATE-----\nMIIBxTCCAWugAwI...\n-----END CERTIFICATE-----\nafter";
    let result = scrub(input);
    assert!(result.contains("[REDACTED:PEM]"));
    assert!(!result.contains("MIIBxTCCAWugAwI"));
    assert!(result.contains("before"));
    assert!(result.contains("after"));
}

#[test]
fn scrubs_pem_private_key() {
    let input = "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQ...\n-----END RSA PRIVATE KEY-----";
    let result = scrub(input);
    assert!(result.contains("[REDACTED:PEM]"));
    assert!(!result.contains("MIIEpAIBAAKCAQ"));
}

#[test]
fn scrubs_jwt_token() {
    let input = "token: eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiYWRtaW4iOnRydWV9.POstGetfAytaZS82wHcjoTyoqhMyxXiWdR7Nn7A29DNSl0EiXLdwJ6xC6AfgZWF1bOsS_TuYI3OG85AmiExREkrS6tDfTQ2B3WXlrr-wp5AokiRbz3_oB4OxG-W9KcEEbDRcZc0nH3L7LzYptiy1PtAylQGxHTWZXtGz4ht0bAecBgmpdgXMguEIcoqPJ1n3pIWk_dUZegpqx0Lka21H6XxUTxiy8OcaarA8zdnPUnV6AmNP3ecFawIFYdvJB_cm-GvpCSbr8G8y_Mllj8f4x9nBH8pQux89_6gUY618iYv7tuPWBFfEbLxtF2pZS6YC1aSfRwBnBpP0EqZ37PfmA";
    let result = scrub(input);
    assert!(result.contains("[REDACTED:JWT]"));
    assert!(!result.contains("eyJhbGciOiJSUzI1NiI"));
}

#[test]
fn scrubs_kubeconfig_certificate_data() {
    let input = "certificate-authority-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUJkekNDQVIyZ0F3SUJBZ0lCQURBS0Jn";
    let result = scrub(input);
    assert!(result.contains("[REDACTED:KUBECONFIG_DATA]"));
    assert!(!result.contains("LS0tLS1CRUdJTiBDRVJU"));
}

#[test]
fn scrubs_bearer_token() {
    let input = "Authorization: Bearer abc123secrettoken456";
    let result = scrub(input);
    assert!(result.contains("[REDACTED:BEARER]"));
    assert!(!result.contains("abc123secrettoken456"));
}

#[test]
fn scrubs_env_secret_assignments() {
    let input = "ADMIN_TOKEN=supersecret123 KUMA_CP_TOKEN=anothersecret";
    let result = scrub(input);
    assert!(result.contains("[REDACTED:ENV_SECRET]"));
    assert!(!result.contains("supersecret123"));
    assert!(!result.contains("anothersecret"));
}

#[test]
fn preserves_non_secret_text() {
    let input = "kubectl get pods -n kuma-system\nNAME          READY   STATUS\nkuma-cp-abc   1/1     Running";
    let result = scrub(input);
    assert_eq!(result, input);
}

#[test]
fn scrubs_multiple_patterns_in_one_pass() {
    let input = "token: eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIn0.Signature1234567890abcdef\n\
                 -----BEGIN CERTIFICATE-----\nMIIBxTCC\n-----END CERTIFICATE-----";
    let result = scrub(input);
    assert!(result.contains("[REDACTED:JWT]"));
    assert!(result.contains("[REDACTED:PEM]"));
}
