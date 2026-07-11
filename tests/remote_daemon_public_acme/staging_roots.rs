use rustls::pki_types::CertificateDer;
use rustls::pki_types::pem::PemObject as _;

// Test-only roots published at https://letsencrypt.org/docs/staging-environment/.
pub const LETS_ENCRYPT_STAGING_ROOTS_PEM: &str = include_str!("staging_roots.pem");

#[cfg(test)]
mod tests {
    use sha2::{Digest as _, Sha256};
    use x509_parser::parse_x509_certificate;

    use super::*;

    #[test]
    fn staging_root_bundle_matches_official_root_fingerprints() {
        let expected = [
            (
                "(STAGING) Pretend Pear X1",
                "e70570a989f8565aabdf7cae27abd1621872d6a3f811e3fef27e3dba02912198",
            ),
            (
                "(STAGING) Bogus Broccoli X2",
                "9b2a339fe6a3e85585c4cd75536cb8c1cf7cd603b9a64bec2521858ae48da85d",
            ),
            (
                "(STAGING) Yearning Yucca Root YE",
                "b59bfc0ba52daf849853b7324a91e82f031db3397f35644157352cde6384b56c",
            ),
            (
                "(STAGING) Yonder Yam Root YR",
                "ef115fb59e040ff39d15fd8f3ef54063c704321d83cb081213272f77d3091672",
            ),
        ];
        let roots = CertificateDer::pem_slice_iter(LETS_ENCRYPT_STAGING_ROOTS_PEM.as_bytes())
            .collect::<Result<Vec<_>, _>>()
            .expect("parse Let's Encrypt staging roots");

        assert_eq!(roots.len(), expected.len());
        for (root, (expected_common_name, expected_fingerprint)) in roots.iter().zip(expected) {
            let (_, certificate) =
                parse_x509_certificate(root.as_ref()).expect("parse staging root certificate");
            assert_eq!(certificate.subject(), certificate.issuer());
            let common_name = certificate
                .subject()
                .iter_common_name()
                .next()
                .expect("staging root common name")
                .as_str()
                .expect("UTF-8 staging root common name");
            assert_eq!(common_name, expected_common_name);
            assert_eq!(
                hex::encode(Sha256::digest(root.as_ref())),
                expected_fingerprint
            );
        }
    }
}
