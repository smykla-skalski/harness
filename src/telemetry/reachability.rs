use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
use std::time::Duration;

#[must_use]
pub(crate) fn endpoint_reachable(url: &str, timeout: Duration) -> bool {
    endpoint_socket_addrs(url).is_some_and(|addrs| {
        addrs
            .into_iter()
            .any(|addr| TcpStream::connect_timeout(&addr, timeout).is_ok())
    })
}

fn endpoint_socket_addrs(url: &str) -> Option<Vec<SocketAddr>> {
    let parsed = reqwest::Url::parse(url).ok()?;
    let host = parsed.host_str()?;
    let port = parsed.port_or_known_default()?;
    (host, port).to_socket_addrs().ok().map(Iterator::collect)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn endpoint_socket_addrs_accepts_urls_with_paths() {
        let addrs = endpoint_socket_addrs("http://127.0.0.1:4040/v1/traces").expect("addrs");

        assert!(addrs.contains(&"127.0.0.1:4040".parse().expect("socket addr")));
    }

    #[test]
    fn endpoint_socket_addrs_defaults_standard_ports_from_scheme() {
        let http = endpoint_socket_addrs("http://127.0.0.1").expect("http addrs");
        let https = endpoint_socket_addrs("https://127.0.0.1").expect("https addrs");

        assert!(http.contains(&"127.0.0.1:80".parse().expect("http addr")));
        assert!(https.contains(&"127.0.0.1:443".parse().expect("https addr")));
    }

    #[test]
    fn endpoint_socket_addrs_rejects_invalid_urls() {
        assert_eq!(endpoint_socket_addrs("127.0.0.1:4317"), None);
    }

    #[test]
    fn endpoint_reachable_reports_open_listener() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let url = format!("http://{}", listener.local_addr().expect("addr"));

        assert!(endpoint_reachable(&url, Duration::from_millis(50)));
    }

    #[test]
    fn endpoint_reachable_reports_closed_listener() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        drop(listener);

        assert!(!endpoint_reachable(
            &format!("http://{addr}"),
            Duration::from_millis(50)
        ));
    }
}
