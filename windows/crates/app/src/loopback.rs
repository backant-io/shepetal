//! The RFC 8252 loopback redirect: a listener on 127.0.0.1 and a free port, which takes the
//! browser's GET /callback?code=…&state=… after Google sign-in and answers with a short page.
//! Plain std, so it is tested with a real socket on any OS.

use crate::license::{redirect_uri, AccountError, Cancel};
use std::io::{ErrorKind, Read, Write};
use std::net::{Ipv4Addr, TcpListener, TcpStream};
use std::time::{Duration, Instant};

/// How long a sign-in waits for the browser.
pub const SIGN_IN_TIMEOUT: Duration = Duration::from_secs(10 * 60);

const PAGE: &str = "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>Shepetal</title></head>\
<body style=\"font-family:system-ui,sans-serif;max-width:32rem;margin:6rem auto;padding:0 1rem;line-height:1.5\">\
<h1 style=\"font-size:1.5rem\">You can close this tab</h1><p>Shepetal is finishing the sign-in.</p></body></html>";

pub struct Loopback {
    listener: TcpListener,
    /// http://127.0.0.1:<port>/callback, exactly as the account service matches it.
    pub redirect_uri: String,
}

impl Loopback {
    /// Binds 127.0.0.1 only (never all interfaces) on a port the system picks.
    pub fn bind() -> Result<Loopback, AccountError> {
        let fail = |e: std::io::Error| AccountError::new(&format!("Could not wait for the sign-in: {e}"));
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).map_err(fail)?;
        let port = listener.local_addr().map_err(fail)?.port();
        listener.set_nonblocking(true).map_err(fail)?;
        Ok(Loopback { listener, redirect_uri: redirect_uri(port) })
    }

    /// Waits for GET /callback and returns its query. Other paths (a favicon) get a 404 and the
    /// wait goes on. Ends early on `cancel`, or after `timeout`.
    pub fn wait(&self, cancel: &Cancel, timeout: Duration) -> Result<String, AccountError> {
        let deadline = Instant::now() + timeout;
        loop {
            if cancel.is_cancelled() {
                return Err(AccountError::cancelled());
            }
            if Instant::now() >= deadline {
                return Err(AccountError::new("Sign-in timed out. Try again."));
            }
            match self.listener.accept() {
                Ok((stream, _)) => {
                    if let Some(query) = answer(stream) {
                        return Ok(query);
                    }
                }
                Err(e) if e.kind() == ErrorKind::WouldBlock => std::thread::sleep(Duration::from_millis(50)),
                Err(e) => return Err(AccountError::new(&format!("Could not wait for the sign-in: {e}"))),
            }
        }
    }
}

/// Reads one request; answers it. The query of a GET /callback, or None for anything else.
fn answer(mut stream: TcpStream) -> Option<String> {
    let _ = stream.set_nonblocking(false);
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let mut buf = Vec::new();
    let mut chunk = [0u8; 1024];
    while !buf.windows(4).any(|w| w == b"\r\n\r\n") && buf.len() < 16 * 1024 {
        match stream.read(&mut chunk) {
            Ok(0) | Err(_) => break,
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
        }
    }
    let head = String::from_utf8_lossy(&buf);
    let query = callback_query(head.lines().next().unwrap_or(""));
    let reply = match &query {
        Some(_) => format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{PAGE}",
            PAGE.len()
        ),
        None => "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".into(),
    };
    let _ = stream.write_all(reply.as_bytes());
    let _ = stream.flush();
    query
}

/// "GET /callback?code=…&state=… HTTP/1.1" → "code=…&state=…".
pub fn callback_query(request_line: &str) -> Option<String> {
    let mut parts = request_line.split(' ');
    let (method, target) = (parts.next()?, parts.next()?);
    if method != "GET" {
        return None;
    }
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    (path == "/callback").then(|| query.split('#').next().unwrap_or("").to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn get(port: u16, target: &str) -> String {
        let mut s = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).unwrap();
        write!(s, "GET {target} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\n").unwrap();
        let mut out = String::new();
        s.read_to_string(&mut out).unwrap();
        out
    }

    fn port(l: &Loopback) -> u16 {
        l.redirect_uri.trim_start_matches("http://127.0.0.1:").trim_end_matches("/callback").parse().unwrap()
    }

    #[test]
    fn the_request_line_must_be_a_get_of_callback() {
        assert_eq!(callback_query("GET /callback?code=a&state=b HTTP/1.1"), Some("code=a&state=b".into()));
        assert_eq!(callback_query("GET /callback HTTP/1.1"), Some(String::new()));
        assert_eq!(callback_query("GET /favicon.ico HTTP/1.1"), None);
        assert_eq!(callback_query("GET /callbackx?code=a HTTP/1.1"), None);
        assert_eq!(callback_query("POST /callback?code=a HTTP/1.1"), None);
        assert_eq!(callback_query(""), None);
    }

    #[test]
    fn the_listener_takes_the_browsers_callback_and_says_close_the_tab() {
        let l = Loopback::bind().unwrap();
        assert!(l.redirect_uri.starts_with("http://127.0.0.1:") && l.redirect_uri.ends_with("/callback"));
        let p = port(&l);
        let browser = std::thread::spawn(move || (get(p, "/favicon.ico"), get(p, "/callback?code=abc&state=xyz")));
        let query = l.wait(&Cancel::default(), Duration::from_secs(10)).unwrap();
        assert_eq!(query, "code=abc&state=xyz");
        let (favicon, page) = browser.join().unwrap();
        assert!(favicon.starts_with("HTTP/1.1 404"), "{favicon}");
        assert!(page.starts_with("HTTP/1.1 200") && page.contains("You can close this tab"), "{page}");
        for name in ["whisper", "ggml", "model"] {
            assert!(!page.to_lowercase().contains(name));
        }
    }

    #[test]
    fn cancel_and_timeout_end_the_wait() {
        let l = Loopback::bind().unwrap();
        let cancel = Cancel::default();
        let c = cancel.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(100));
            c.cancel();
        });
        let t = Instant::now();
        assert_eq!(l.wait(&cancel, Duration::from_secs(30)), Err(AccountError::cancelled()));
        assert!(t.elapsed() < Duration::from_secs(5));
        assert!(l.wait(&Cancel::default(), Duration::from_millis(100)).unwrap_err().message.contains("timed out"));
    }
}
