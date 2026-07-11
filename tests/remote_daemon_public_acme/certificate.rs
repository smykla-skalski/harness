use x509_parser::extensions::GeneralName;
use x509_parser::parse_x509_certificate;

pub fn validate_verified_leaf_metadata(domain: &str, der: &[u8]) -> Result<(), String> {
    let (_, certificate) = parse_x509_certificate(der)
        .map_err(|error| format!("parse public ACME leaf certificate: {error}"))?;
    if certificate.subject() == certificate.issuer() {
        return Err("public ACME leaf certificate is self-signed".to_string());
    }
    if !certificate.validity().is_valid() {
        return Err("public ACME leaf certificate is not currently valid".to_string());
    }
    let alternative_names = certificate
        .subject_alternative_name()
        .map_err(|error| format!("parse public ACME subject alternative name: {error}"))?
        .ok_or_else(|| {
            "public ACME leaf certificate omitted a subject alternative name".to_string()
        })?;
    let expected = domain.trim_end_matches('.');
    let matches = alternative_names.value.general_names.iter().any(
        |name| matches!(name, GeneralName::DNSName(value) if value.eq_ignore_ascii_case(expected)),
    );
    if matches {
        Ok(())
    } else {
        Err(format!(
            "public ACME leaf certificate subject alternative name did not include {expected}"
        ))
    }
}

#[cfg(test)]
mod tests {
    use rcgen::{
        BasicConstraints, CertificateParams, CertifiedIssuer, DistinguishedName, DnType, IsCa,
        KeyPair, KeyUsagePurpose,
    };

    use super::*;

    #[test]
    fn issued_certificate_accepts_exact_ca_signed_hostname() {
        let certificate = signed_certificate("tls.remote.example.com");

        validate_verified_leaf_metadata("tls.remote.example.com", &certificate)
            .expect("valid issued certificate");
    }

    #[test]
    fn issued_certificate_rejects_wrong_hostname() {
        let certificate = signed_certificate("other.remote.example.com");

        let error = validate_verified_leaf_metadata("tls.remote.example.com", &certificate)
            .expect_err("wrong hostname must be rejected");

        assert!(error.contains("subject alternative name"));
    }

    #[test]
    fn issued_certificate_rejects_self_signed_material() {
        let key = KeyPair::generate().expect("self-signed key");
        let certificate = CertificateParams::new(["tls.remote.example.com".to_string()])
            .expect("self-signed params")
            .self_signed(&key)
            .expect("self-sign certificate");

        let error =
            validate_verified_leaf_metadata("tls.remote.example.com", certificate.der().as_ref())
                .expect_err("self-signed certificate must be rejected");

        assert!(error.contains("self-signed"));
    }

    fn signed_certificate(domain: &str) -> Vec<u8> {
        let mut issuer_params = CertificateParams::default();
        issuer_params.distinguished_name = DistinguishedName::new();
        issuer_params
            .distinguished_name
            .push(DnType::CommonName, "Harness Public ACME Test CA");
        issuer_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
        issuer_params.key_usages = vec![
            KeyUsagePurpose::DigitalSignature,
            KeyUsagePurpose::KeyCertSign,
            KeyUsagePurpose::CrlSign,
        ];
        let issuer =
            CertifiedIssuer::self_signed(issuer_params, KeyPair::generate().expect("issuer key"))
                .expect("test issuer");
        let key = KeyPair::generate().expect("leaf key");
        CertificateParams::new([domain.to_string()])
            .expect("leaf params")
            .signed_by(&key, &issuer)
            .expect("sign leaf")
            .der()
            .to_vec()
    }
}
