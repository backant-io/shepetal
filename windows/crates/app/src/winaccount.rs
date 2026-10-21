//! The Win32 halves of the account: HTTPS through WinHTTP (the system's TLS and proxy settings),
//! the token in the Windows Credential Manager, and the system's secure random generator.

use crate::account::Tokens;
use crate::license::{split_url, Cancel, Http, Request};
use std::ffi::c_void;
use std::ptr::{null, null_mut};
use std::sync::{Arc, Mutex};
use windows_sys::Win32::Foundation::GetLastError;
use windows_sys::Win32::Networking::WinHttp::*;
use windows_sys::Win32::Security::Credentials::{CredDeleteW, CredFree, CredReadW, CredWriteW, CREDENTIALW, CRED_PERSIST_LOCAL_MACHINE, CRED_TYPE_GENERIC};
use windows_sys::Win32::Security::Cryptography::{BCryptGenRandom, BCRYPT_USE_SYSTEM_PREFERRED_RNG};
use windows_sys::Win32::System::Threading::GetCurrentProcessId;
use windows_sys::Win32::UI::WindowsAndMessaging::{FindWindowW, GetWindowThreadProcessId, PostMessageW, IDCANCEL, WM_COMMAND};

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain([0]).collect()
}

/// Fills `buf` from the system's preferred RNG.
pub fn random(buf: &mut [u8]) -> Result<(), String> {
    let status = unsafe { BCryptGenRandom(null_mut(), buf.as_mut_ptr(), buf.len() as u32, BCRYPT_USE_SYSTEM_PREFERRED_RNG) };
    if status == 0 { Ok(()) } else { Err(format!("the system random generator failed ({status:#x})")) }
}

/// Closes this process's open `dialog::ask` window, if there is one, as Esc would. From any
/// thread: the sign-in wait closes itself when the browser comes back.
pub fn dismiss_dialog() {
    unsafe {
        let hwnd = FindWindowW(wide("ShepetalDialog").as_ptr(), null());
        let mut pid = 0;
        if !hwnd.is_null() && GetWindowThreadProcessId(hwnd, &mut pid) != 0 && pid == GetCurrentProcessId() {
            PostMessageW(hwnd, WM_COMMAND, IDCANCEL as usize, 0);
        }
    }
}

/// The largest answer read; the service's are a few hundred bytes.
const MAX_BODY: usize = 1 << 20;

/// A WinHTTP handle, closed on drop.
struct Handle(*mut c_void);

impl Drop for Handle {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { WinHttpCloseHandle(self.0) };
        }
    }
}

/// The request handle, shared with the cancel hook: whoever takes it closes it. Closing it from
/// the cancelling thread makes the blocking WinHTTP call on the worker fail at once.
#[derive(Clone)]
struct Shared(Arc<Mutex<usize>>);

impl Shared {
    fn close(&self) {
        let h = std::mem::take(&mut *self.0.lock().unwrap());
        if h != 0 {
            unsafe { WinHttpCloseHandle(h as *mut c_void) };
        }
    }
}

pub struct WinHttp;

impl Http for WinHttp {
    /// The exchange runs on its own thread, so a cancel returns at once even where closing the
    /// handle does not break a blocking call; a late answer is dropped.
    fn send(&self, r: &Request, cancel: &Cancel) -> Result<(u16, String), String> {
        let (tx, rx) = std::sync::mpsc::channel();
        let (r, c) = (r.clone(), cancel.clone());
        std::thread::spawn(move || tx.send(blocking(&r, &c)));
        loop {
            match rx.recv_timeout(std::time::Duration::from_millis(50)) {
                Ok(result) => return result,
                Err(_) if cancel.is_cancelled() => return Err("Cancelled".into()),
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return Err("The request thread died".into()),
            }
        }
    }
}

fn blocking(r: &Request, cancel: &Cancel) -> Result<(u16, String), String> {
    let (secure, host, port, path) = split_url(&r.url).ok_or_else(|| format!("Not a web address: {}", r.url))?;
    let fail = |what: &str| {
        let code = unsafe { GetLastError() };
        if cancel.is_cancelled() { "Cancelled".to_string() } else { format!("Could not reach the account service ({what}, error {code})") }
    };
    unsafe {
        let session = Handle(WinHttpOpen(wide("Shepetal").as_ptr(), WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, null(), null(), 0));
        if session.0.is_null() {
            return Err(fail("open"));
        }
        WinHttpSetTimeouts(session.0, 10_000, 10_000, 20_000, 20_000);
        let connect = Handle(WinHttpConnect(session.0, wide(&host).as_ptr(), port, 0));
        if connect.0.is_null() {
            return Err(fail("connect"));
        }
        let flags = if secure { WINHTTP_FLAG_SECURE } else { 0 };
        let request = WinHttpOpenRequest(connect.0, wide(r.method).as_ptr(), wide(&path).as_ptr(), null(), null(), null(), flags);
        if request.is_null() {
            return Err(fail("request"));
        }
        let shared = Shared(Arc::new(Mutex::new(request as usize)));
        let hook = shared.clone();
        cancel.on_cancel(Box::new(move || hook.close()));
        let result = exchange(request, r, &fail);
        cancel.clear();
        shared.close();
        result
    }
}

unsafe fn exchange(request: *mut c_void, r: &Request, fail: &dyn Fn(&str) -> String) -> Result<(u16, String), String> {
    let mut headers = String::from("Accept: application/json\r\n");
    if let Some(token) = &r.bearer {
        headers += &format!("Authorization: Bearer {token}\r\n");
    }
    if r.json.is_some() {
        headers += "Content-Type: application/json\r\n";
    }
    let headers = wide(&headers);
    let body = r.json.as_deref().unwrap_or("").as_bytes();
    let len = body.len() as u32;
    let body_ptr = if body.is_empty() { null() } else { body.as_ptr().cast() };
    if WinHttpSendRequest(request, headers.as_ptr(), u32::MAX, body_ptr, len, len, 0) == 0 {
        return Err(fail("send"));
    }
    if WinHttpReceiveResponse(request, null_mut()) == 0 {
        return Err(fail("receive"));
    }
    let mut status = 0u32;
    let mut size = 4u32;
    let query = WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER;
    if WinHttpQueryHeaders(request, query, null(), (&raw mut status).cast(), &mut size, null_mut()) == 0 {
        return Err(fail("status"));
    }
    let mut out = Vec::new();
    let mut buf = [0u8; 4096];
    loop {
        let mut read = 0u32;
        if WinHttpReadData(request, buf.as_mut_ptr().cast(), buf.len() as u32, &mut read) == 0 {
            return Err(fail("read"));
        }
        if read == 0 || out.len() > MAX_BODY {
            break;
        }
        out.extend_from_slice(&buf[..read as usize]);
    }
    Ok((status as u16, String::from_utf8_lossy(&out).into_owned()))
}

/// The account token as a generic credential in the Windows Credential Manager, which keeps it
/// encrypted with DPAPI for the signed-in user. Control Panel > Credential Manager > Windows
/// Credentials shows it as `Shepetal/account`.
pub struct CredTokens {
    target: Vec<u16>,
}

impl CredTokens {
    /// SHEPETAL_CREDENTIAL_TARGET overrides the name, so a hand test or a CI run never reads or
    /// replaces the real sign-in.
    pub fn new(target: Option<&str>) -> CredTokens {
        CredTokens { target: wide(target.filter(|t| !t.is_empty()).unwrap_or("Shepetal/account")) }
    }
}

impl Tokens for CredTokens {
    fn read(&self) -> Option<String> {
        unsafe {
            let mut cred: *mut CREDENTIALW = null_mut();
            if CredReadW(self.target.as_ptr(), CRED_TYPE_GENERIC, 0, &mut cred) == 0 {
                return None;
            }
            let c = &*cred;
            let blob = std::slice::from_raw_parts(c.CredentialBlob, c.CredentialBlobSize as usize);
            let token = String::from_utf8(blob.to_vec()).ok().filter(|t| !t.is_empty());
            CredFree(cred.cast());
            token
        }
    }

    fn write(&self, token: &str) -> Result<(), String> {
        let mut target = self.target.clone();
        let mut user = wide("shepetal");
        let mut blob = token.as_bytes().to_vec();
        let cred = CREDENTIALW {
            Type: CRED_TYPE_GENERIC,
            TargetName: target.as_mut_ptr(),
            CredentialBlobSize: blob.len() as u32,
            CredentialBlob: blob.as_mut_ptr(),
            Persist: CRED_PERSIST_LOCAL_MACHINE,
            UserName: user.as_mut_ptr(),
            ..Default::default()
        };
        if unsafe { CredWriteW(&cred, 0) } == 0 {
            return Err(format!("Credential Manager refused it (error {})", unsafe { GetLastError() }));
        }
        Ok(())
    }

    fn delete(&self) {
        unsafe { CredDeleteW(self.target.as_ptr(), CRED_TYPE_GENERIC, 0) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::license::Client;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::time::{Duration, Instant};

    #[test]
    fn the_token_round_trips_through_credential_manager() {
        let t = CredTokens::new(Some(&format!("Shepetal/test-{}", std::process::id())));
        t.delete();
        assert_eq!(t.read(), None);
        t.write("tok-1").unwrap();
        assert_eq!(t.read().as_deref(), Some("tok-1"));
        t.write("tok-2").unwrap();
        assert_eq!(t.read().as_deref(), Some("tok-2"), "a new sign-in replaces the old token");
        t.delete();
        assert_eq!(t.read(), None);
    }

    #[test]
    fn random_fills_the_buffer() {
        let (mut a, mut b) = ([0u8; 32], [0u8; 32]);
        random(&mut a).unwrap();
        random(&mut b).unwrap();
        assert_ne!(a, b);
    }

    /// A one-request HTTP server on 127.0.0.1: answers `reply` and hands back what it got.
    fn serve(status: &str, body: &str) -> (String, std::thread::JoinHandle<String>) {
        let reply = format!("HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", l.local_addr().unwrap());
        let t = std::thread::spawn(move || {
            let (mut s, _) = l.accept().unwrap();
            s.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            let mut got = Vec::new();
            let mut buf = [0u8; 4096];
            while let Ok(n) = s.read(&mut buf) {
                got.extend_from_slice(&buf[..n]);
                let text = String::from_utf8_lossy(&got);
                if let Some(i) = text.find("\r\n\r\n") {
                    let len = text.lines().find_map(|l| l.to_ascii_lowercase().strip_prefix("content-length: ").map(|v| v.trim().parse::<usize>().unwrap())).unwrap_or(0);
                    if got.len() >= i + 4 + len {
                        break;
                    }
                }
                if n == 0 {
                    break;
                }
            }
            s.write_all(reply.as_bytes()).unwrap();
            String::from_utf8_lossy(&got).into_owned()
        });
        (base, t)
    }

    #[test]
    fn winhttp_sends_the_bearer_and_json_and_reads_the_answer() {
        let (base, server) = serve("200 OK", r#"{"status":"active","trial_ends_at":null}"#);
        let r = Request { method: "POST", url: format!("{base}/api/checkout"), bearer: Some("tok".into()), json: Some("{\"a\":1}".into()) };
        let (status, body) = WinHttp.send(&r, &Cancel::default()).unwrap();
        assert_eq!(status, 200);
        assert!(body.contains("\"active\""), "{body}");
        let got = server.join().unwrap();
        assert!(got.starts_with("POST /api/checkout HTTP/1.1"), "{got}");
        assert!(got.contains("Authorization: Bearer tok"), "{got}");
        assert!(got.contains("Content-Type: application/json"), "{got}");
        assert!(got.ends_with("{\"a\":1}"), "{got}");
    }

    #[test]
    fn winhttp_reads_a_401_as_signed_out() {
        let (base, server) = serve("401 Unauthorized", "{}");
        let client = Client { base, http: WinHttp };
        assert_eq!(client.license("tok", &Cancel::default()), Ok(crate::license::LicenseReply::Unauthorized));
        assert!(server.join().unwrap().starts_with("GET /api/license HTTP/1.1"));
    }

    #[test]
    fn cancel_aborts_a_request_that_hangs() {
        // A server that accepts and never answers, like a dead network mid-request.
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", l.local_addr().unwrap());
        let _hold = std::thread::spawn(move || {
            let conn = l.accept();
            std::thread::sleep(Duration::from_secs(30));
            drop(conn);
        });
        let cancel = Cancel::default();
        let c = cancel.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(300));
            c.cancel();
        });
        let t = Instant::now();
        let r = Request { method: "GET", url: format!("{base}/api/license"), bearer: Some("tok".into()), json: None };
        assert!(WinHttp.send(&r, &cancel).is_err());
        assert!(t.elapsed() < Duration::from_secs(5), "took {:?}", t.elapsed());
    }
}
