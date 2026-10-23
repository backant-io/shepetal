//! Google sign-in, the free trial and the lifetime license against the account service
//! (web/API.md on feat/web), as on the Mac (Sources/ShepetalCore/Account.swift). Pure: the HTTP
//! transport comes in as the `Http` trait and the clock as `now` (Unix seconds), so everything
//! here is tested on any OS. These calls are the app's only network use besides the one model
//! download: sign-in, the license check and checkout. Nothing here runs during a dictation, and
//! audio and text never go through it.

use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::fs;
use std::io;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

pub const DAY: i64 = 86_400;
/// A license stays valid this long without reaching the service.
pub const OFFLINE_GRACE: i64 = 7 * DAY;
pub const CHECK_EVERY: i64 = DAY;
/// After a failed check, try again this much later.
pub const RETRY_AFTER_FAILURE: i64 = 3_600;

/// The account service. Builds released before the move to shepetal.app called
/// https://shepetal.backant.io, which still answers /api/* for them.
pub const DEFAULT_BASE: &str = "https://shepetal.app";

/// SHEPETAL_ACCOUNT_URL overrides the service (tests and hand tests point it at a local copy).
pub fn base_url(env: Option<&str>) -> String {
    env.filter(|s| !s.is_empty()).unwrap_or(DEFAULT_BASE).trim_end_matches('/').to_string()
}

/// Only https pages are opened or called, plus http on this PC for a local copy of the service.
pub fn is_web_page(url: &str) -> bool {
    if url.starts_with("https://") {
        return true;
    }
    let Some(rest) = url.strip_prefix("http://") else { return false };
    let host = rest.split(['/', '?', '#']).next().unwrap_or("");
    let host = host.rsplit_once(':').map_or(host, |(h, port)| if port.bytes().all(|b| b.is_ascii_digit()) { h } else { host });
    host == "localhost" || host == "127.0.0.1"
}

/// "https://host:port/path?q" → (secure, host, port, "/path?q"), for the WinHTTP transport.
pub fn split_url(url: &str) -> Option<(bool, String, u16, String)> {
    let (secure, rest) = match url.split_once("://")? {
        ("https", rest) => (true, rest),
        ("http", rest) => (false, rest),
        _ => return None,
    };
    let (authority, path) = rest.find(['/', '?']).map_or((rest, "/"), |i| (&rest[..i], &rest[i..]));
    let path = if path.starts_with('?') { format!("/{path}") } else { path.to_string() };
    let (host, port) = match authority.rsplit_once(':') {
        Some((h, p)) => (h, p.parse().ok()?),
        None => (authority, if secure { 443 } else { 80 }),
    };
    (!host.is_empty() && !host.contains('@')).then(|| (secure, host.to_string(), port, path))
}

/// RFC 7636 4.1: the verifier's characters.
pub const UNRESERVED: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";

/// Google sign-in for a native app (RFC 8252) with PKCE (RFC 7636). The app opens
/// <base>/app/login?redirect_uri=http://127.0.0.1:<port>/callback&state=…&code_challenge=…&code_challenge_method=S256
/// in the default browser, its loopback listener (`loopback.rs`) gets /callback?code=…&state=…,
/// and the code and the verifier are traded at POST /api/app/token for {access_token, email}.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pkce {
    pub verifier: String,
    pub challenge: String,
    pub state: String,
}

impl Pkce {
    pub fn new(verifier: &str, state: &str) -> Pkce {
        Pkce { verifier: verifier.into(), challenge: challenge(verifier), state: state.into() }
    }

    /// A 64-character verifier and a 32-character state from `random`, which fills a buffer from
    /// the system's secure generator. Bytes at or above 198 (3 × 66) are dropped, so each of the
    /// 66 characters is equally likely.
    pub fn generate(mut random: impl FnMut(&mut [u8]) -> Result<(), String>) -> Result<Pkce, AccountError> {
        let mut pick = |n: usize| {
            let mut out = String::with_capacity(n);
            while out.len() < n {
                let mut buf = [0u8; 64];
                random(&mut buf).map_err(|e| AccountError::new(&format!("Could not start the sign-in: {e}")))?;
                let limit = (256 / UNRESERVED.len() * UNRESERVED.len()) as u8;
                for b in buf.into_iter().filter(|&b| b < limit) {
                    if out.len() < n {
                        out.push(UNRESERVED[b as usize % UNRESERVED.len()] as char);
                    }
                }
            }
            Ok(out)
        };
        let verifier = pick(64)?;
        let state = pick(32)?;
        Ok(Pkce::new(&verifier, &state))
    }
}

/// S256: base64url(SHA-256(ASCII(verifier))) without padding.
pub fn challenge(verifier: &str) -> String {
    base64url(&Sha256::digest(verifier.as_bytes()))
}

fn base64url(bytes: &[u8]) -> String {
    const A: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let n = chunk.iter().enumerate().fold(0u32, |n, (i, &b)| n | (b as u32) << (16 - 8 * i));
        for i in 0..=chunk.len() {
            out.push(A[(n >> (18 - 6 * i) & 63) as usize] as char);
        }
    }
    out
}

/// The loopback redirect the account service accepts for the desktop apps (API.md): exactly
/// 127.0.0.1, a port, and /callback.
pub fn redirect_uri(port: u16) -> String {
    format!("http://127.0.0.1:{port}/callback")
}

pub fn login_url(base: &str, redirect_uri: &str, pkce: &Pkce) -> String {
    format!(
        "{base}/app/login?redirect_uri={}&state={}&code_challenge={}&code_challenge_method=S256",
        encode(redirect_uri),
        encode(&pkce.state),
        encode(&pkce.challenge)
    )
}

fn encode(s: &str) -> String {
    s.bytes()
        .map(|b| if UNRESERVED.contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") })
        .collect()
}

fn decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        let hex = |c: u8| (c as char).to_digit(16);
        match b[i] {
            b'%' if i + 2 < b.len() => match (hex(b[i + 1]), hex(b[i + 2])) {
                (Some(h), Some(l)) => {
                    out.push((h * 16 + l) as u8);
                    i += 3;
                    continue;
                }
                _ => out.push(b'%'),
            },
            b'+' => out.push(b' '),
            c => out.push(c),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// The code from the callback's query (code=…&state=…), only when the state is the one this
/// sign-in sent: anything else is dropped before the token call (API.md).
pub fn code_from(query: &str, state: &str) -> Result<String, AccountError> {
    let value = |name: &str| {
        query.split('&').find_map(|kv| {
            let (k, v) = kv.split_once('=').unwrap_or((kv, ""));
            (decode(k) == name).then(|| decode(v))
        })
    };
    if value("state").as_deref() != Some(state) {
        return Err(AccountError::new("Sign-in answer did not match this sign-in. Try again."));
    }
    if let Some(e) = value("error") {
        return Err(AccountError::new(&format!("Sign-in was refused ({e})")));
    }
    match value("code") {
        Some(c) if !c.is_empty() => Ok(c),
        _ => Err(AccountError::new("Sign-in came back without a code")),
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountError {
    pub message: String,
    /// The HTTP status behind it, 0 when there is none.
    pub status: u16,
}

impl AccountError {
    pub fn new(message: &str) -> AccountError {
        AccountError { message: message.into(), status: 0 }
    }
    fn unexpected(status: u16) -> AccountError {
        AccountError { message: format!("The account service answered {status}"), status }
    }
    /// The job was cancelled (a dictation started, or Cancel sign-in / Sign out).
    pub fn cancelled() -> AccountError {
        AccountError { message: "Cancelled".into(), status: 0 }
    }
}

impl std::fmt::Display for AccountError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

/// A cancel flag the HTTP transport and the loopback listener watch. `on_cancel` lets the
/// transport abort a blocking call (WinHTTP: close the request handle).
#[derive(Clone, Default)]
pub struct Cancel(Arc<CancelInner>);

#[derive(Default)]
struct CancelInner {
    flag: AtomicBool,
    hook: Mutex<Option<Box<dyn FnOnce() + Send>>>,
}

impl Cancel {
    pub fn cancel(&self) {
        self.0.flag.store(true, Ordering::SeqCst);
        if let Some(f) = self.0.hook.lock().unwrap().take() {
            f();
        }
    }
    pub fn is_cancelled(&self) -> bool {
        self.0.flag.load(Ordering::SeqCst)
    }
    /// Runs `f` on cancel, or now if already cancelled. One hook at a time; a new one replaces it.
    pub fn on_cancel(&self, f: Box<dyn FnOnce() + Send>) {
        let mut hook = self.0.hook.lock().unwrap();
        if self.is_cancelled() {
            drop(hook);
            f();
        } else {
            *hook = Some(f);
        }
    }
    /// Drops the hook without running it (the call it guarded is over).
    pub fn clear(&self) -> bool {
        self.0.hook.lock().unwrap().take().is_some()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Request {
    pub method: &'static str,
    pub url: String,
    pub bearer: Option<String>,
    /// A JSON body, sent with Content-Type: application/json.
    pub json: Option<String>,
}

/// One HTTP exchange: the status and the body. Err: no answer (offline, timeout, cancelled).
pub trait Http {
    fn send(&self, request: &Request, cancel: &Cancel) -> Result<(u16, String), String>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Trial,
    Active,
    Expired,
}

impl Status {
    fn parse(s: &str) -> Option<Status> {
        match s {
            "trial" => Some(Status::Trial),
            "active" => Some(Status::Active),
            "expired" => Some(Status::Expired),
            _ => None,
        }
    }
    fn name(self) -> &'static str {
        match self {
            Status::Trial => "trial",
            Status::Active => "active",
            Status::Expired => "expired",
        }
    }
}

/// GET /api/license
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct License {
    pub status: Status,
    /// Unix seconds.
    pub trial_ends_at: Option<i64>,
    pub email: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LicenseReply {
    License(License),
    /// 401: the token is gone or revoked, so the user is signed out.
    Unauthorized,
}

/// The account service's endpoints over an `Http` transport.
pub struct Client<H> {
    pub base: String,
    pub http: H,
}

impl<H: Http> Client<H> {
    fn call(&self, method: &'static str, path: &str, bearer: Option<&str>, body: Option<Value>, cancel: &Cancel) -> Result<(u16, Value), AccountError> {
        let request = Request {
            method,
            url: format!("{}{path}", self.base),
            bearer: bearer.map(String::from),
            json: body.map(|b| b.to_string()),
        };
        if cancel.is_cancelled() {
            return Err(AccountError::cancelled());
        }
        let (status, text) = self.http.send(&request, cancel).map_err(|e| {
            if cancel.is_cancelled() { AccountError::cancelled() } else { AccountError::new(&e) }
        })?;
        Ok((status, serde_json::from_str(&text).unwrap_or(Value::Null)))
    }

    /// POST /api/app/token: the callback's code and the PKCE verifier for the account token.
    pub fn exchange(&self, code: &str, verifier: &str, redirect_uri: &str, cancel: &Cancel) -> Result<(String, String), AccountError> {
        let body = json!({"code": code, "code_verifier": verifier, "redirect_uri": redirect_uri});
        let (status, v) = self.call("POST", "/api/app/token", None, Some(body), cancel)?;
        match v["access_token"].as_str() {
            Some(t) if status == 200 && !t.is_empty() => Ok((t.into(), v["email"].as_str().unwrap_or("").into())),
            _ => match v["error"].as_str() {
                Some(e) => Err(AccountError { message: format!("Sign-in failed on the account service ({e})"), status }),
                None => Err(AccountError::unexpected(status)),
            },
        }
    }

    pub fn license(&self, token: &str, cancel: &Cancel) -> Result<LicenseReply, AccountError> {
        let (status, v) = self.call("GET", "/api/license", Some(token), None, cancel)?;
        if status == 401 {
            return Ok(LicenseReply::Unauthorized);
        }
        let status_value = v["status"].as_str().and_then(Status::parse);
        let Some(s) = status_value.filter(|_| status == 200) else { return Err(AccountError::unexpected(status)) };
        let ends = v["trial_ends_at"].as_str().and_then(parse_date);
        if s == Status::Trial && ends.is_none() {
            return Err(AccountError::new("The account service sent a trial without an end date"));
        }
        Ok(LicenseReply::License(License { status: s, trial_ends_at: ends, email: v["email"].as_str().unwrap_or("").into() }))
    }

    /// The Stripe Checkout page for the lifetime license.
    pub fn checkout(&self, token: &str, cancel: &Cancel) -> Result<String, AccountError> {
        let (status, v) = self.call("POST", "/api/checkout", Some(token), Some(json!({})), cancel)?;
        match (status, v["url"].as_str()) {
            (401, _) => Err(AccountError { message: "Signed out: sign in again to buy".into(), status }),
            (409, _) => Err(AccountError { message: "You already own Shepetal".into(), status }),
            (200, Some(url)) if is_web_page(url) => Ok(url.into()),
            _ => Err(AccountError::unexpected(status)),
        }
    }

    /// POST /api/app/revoke on Sign out, so the token stops working on the service too.
    pub fn revoke(&self, token: &str, cancel: &Cancel) -> Result<(), AccountError> {
        self.call("POST", "/api/app/revoke", Some(token), Some(json!({})), cancel).map(drop)
    }
}

/// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's days_from_civil).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// ISO 8601 date-time with a Z or ±HH:MM offset, with or without fractional seconds
/// (JavaScript's toISOString has them), as Unix seconds.
pub fn parse_date(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    let num = |r: std::ops::Range<usize>| -> Option<i64> {
        let t = s.get(r)?;
        t.bytes().all(|c| c.is_ascii_digit()).then(|| t.parse().ok())?
    };
    if b.len() < 20 || b[4] != b'-' || b[7] != b'-' || !matches!(b[10], b'T' | b't') || b[13] != b':' || b[16] != b':' {
        return None;
    }
    let (y, mo, d, h, mi, sec) = (num(0..4)?, num(5..7)?, num(8..10)?, num(11..13)?, num(14..16)?, num(17..19)?);
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) || h > 23 || mi > 59 || sec > 60 {
        return None;
    }
    let mut i = 19;
    if b[i] == b'.' {
        i += 1;
        let start = i;
        while i < b.len() && b[i].is_ascii_digit() {
            i += 1;
        }
        if i == start {
            return None;
        }
    }
    let offset = match s.get(i..)? {
        "Z" | "z" => 0,
        o if o.len() == 6 && matches!(&o[..1], "+" | "-") && &o[3..4] == ":" => {
            let v = num(i + 1..i + 3)? * 3600 + num(i + 4..i + 6)? * 60;
            if &o[..1] == "-" { -v } else { v }
        }
        _ => return None,
    };
    Some(days_from_civil(y, mo, d) * DAY + h * 3600 + mi * 60 + sec - offset)
}

/// What the user may do right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Access {
    SignedOut,
    Trial { days_left: i64 },
    Lifetime,
    Expired,
    /// Signed in, but no good license check in the last 7 days (or none yet).
    Unchecked,
}

pub const SIGN_IN: &str = "Sign in with Google to start your free 30-day trial";
pub const TRIAL_ENDED: &str = "Trial ended: get Shepetal for $4.99";
pub const BUY: &str = "Get Shepetal for $4.99 (lifetime, updates included)";

impl Access {
    pub fn allows_dictation(self) -> bool {
        matches!(self, Access::Trial { .. } | Access::Lifetime)
    }

    /// One line for the tray menu and the first-run dialog.
    pub fn summary(self) -> String {
        match self {
            Access::SignedOut => "Not signed in".into(),
            Access::Trial { days_left: 1 } => "Free trial: 1 day left".into(),
            Access::Trial { days_left } => format!("Free trial: {days_left} days left"),
            Access::Lifetime => "Yours forever".into(),
            Access::Expired => "Trial ended".into(),
            Access::Unchecked => "License not checked".into(),
        }
    }

    /// The text next to 🤫 when Ctrl+Win is pressed while dictation is off.
    pub fn blocked_hint(self) -> Option<&'static str> {
        match self {
            Access::Trial { .. } | Access::Lifetime => None,
            Access::SignedOut => Some(SIGN_IN),
            Access::Expired => Some(TRIAL_ENDED),
            Access::Unchecked => Some("Connect to the internet so Shepetal can check your license"),
        }
    }
}

/// What is cached between launches (account.json in the data dir). The token itself is in the
/// Windows Credential Manager, never here.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct State {
    pub license: Option<License>,
    /// When the service last answered a license check (Unix seconds).
    pub last_good_check: Option<i64>,
    /// When a check was last tried, answered or not.
    pub last_attempt: Option<i64>,
    /// The first-run dialog has offered sign-in once.
    pub offered: bool,
}

impl State {
    pub fn to_json(&self) -> String {
        let license = self.license.as_ref().map(|l| json!({"status": l.status.name(), "trial_ends_at": l.trial_ends_at, "email": l.email}));
        json!({"license": license, "last_good_check": self.last_good_check, "last_attempt": self.last_attempt, "offered": self.offered}).to_string()
    }

    /// A missing or unreadable cache is an empty one: the next check fills it.
    pub fn from_json(s: &str) -> State {
        let Ok(v) = serde_json::from_str::<Value>(s) else { return State::default() };
        let l = &v["license"];
        let license = l["status"].as_str().and_then(Status::parse).map(|status| License {
            status,
            trial_ends_at: l["trial_ends_at"].as_i64(),
            email: l["email"].as_str().unwrap_or("").into(),
        });
        State {
            license,
            last_good_check: v["last_good_check"].as_i64(),
            last_attempt: v["last_attempt"].as_i64(),
            offered: v["offered"].as_bool().unwrap_or(false),
        }
    }

    pub fn load(path: &Path) -> State {
        fs::read_to_string(path).map(|s| State::from_json(&s)).unwrap_or_default()
    }

    /// Written to a temp file, then renamed over, so a crash never leaves half a cache.
    pub fn save(&self, path: &Path) -> io::Result<()> {
        let tmp = path.with_extension("json.tmp");
        fs::write(&tmp, self.to_json())?;
        fs::rename(&tmp, path).inspect_err(|_| drop(fs::remove_file(&tmp)))
    }
}

pub fn access(signed_in: bool, state: &State, now: i64) -> Access {
    if !signed_in {
        return Access::SignedOut;
    }
    let (Some(license), Some(checked)) = (&state.license, state.last_good_check) else { return Access::Unchecked };
    if now - checked > OFFLINE_GRACE {
        return Access::Unchecked;
    }
    match license.status {
        Status::Active => Access::Lifetime,
        Status::Expired => Access::Expired,
        // The cached end date counts even offline: a trial does not outlive its end by staying offline.
        Status::Trial => match license.trial_ends_at {
            Some(end) if end > now => Access::Trial { days_left: (end - now + DAY - 1) / DAY },
            _ => Access::Expired,
        },
    }
}

/// A check is due at launch (no attempt yet), 24 h after the last good one, or an hour after a
/// failed one.
pub fn check_due(state: &State, now: i64) -> bool {
    let Some(attempt) = state.last_attempt else { return true };
    let good = state.last_good_check.unwrap_or(i64::MIN);
    if attempt > good {
        return now - attempt >= RETRY_AFTER_FAILURE;
    }
    now - good >= CHECK_EVERY
}

/// Folds a check result into the cache. A 401 signs out (the caller drops the token); a failed
/// check keeps the cached license, so the 7-day grace counts from the last good check.
pub fn apply(result: &Result<LicenseReply, AccountError>, state: &State, now: i64) -> (State, bool) {
    let mut s = state.clone();
    s.last_attempt = Some(now);
    match result {
        Ok(LicenseReply::License(l)) => {
            s.license = Some(l.clone());
            s.last_good_check = Some(now);
            (s, false)
        }
        Ok(LicenseReply::Unauthorized) => (State { offered: state.offered, ..State::default() }, true),
        Err(_) => (s, false),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    const NOW: i64 = 1_792_000_000; // 2026-10-15

    #[test]
    fn s256_matches_rfc_7636_appendix_b() {
        assert_eq!(challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
    }

    #[test]
    fn base64url_has_no_padding_and_the_url_alphabet() {
        assert_eq!(base64url(b""), "");
        assert_eq!(base64url(b"f"), "Zg");
        assert_eq!(base64url(b"fo"), "Zm8");
        assert_eq!(base64url(b"foo"), "Zm9v");
        assert_eq!(base64url(&[0xfb, 0xff]), "-_8");
        assert_eq!(challenge("x").len(), 43, "the service wants exactly 43 characters");
    }

    #[test]
    fn generated_verifier_and_state_are_unreserved_and_fresh() {
        let mut seed = 7u32;
        let rng = |buf: &mut [u8]| {
            for b in buf {
                seed = seed.wrapping_mul(1_103_515_245).wrapping_add(12_345);
                *b = (seed >> 16) as u8;
            }
            Ok(())
        };
        let p = Pkce::generate(rng).unwrap();
        assert_eq!(p.verifier.len(), 64, "RFC 7636: 43 to 128");
        assert_eq!(p.state.len(), 32);
        assert!(p.verifier.bytes().chain(p.state.bytes()).all(|b| UNRESERVED.contains(&b)));
        assert_eq!(p.challenge, challenge(&p.verifier));
        assert_ne!(p.verifier[..32], p.state, "state is not a prefix of the verifier");
        // Only bytes below 198 are used: an all-255 source must not stall forever on one value.
        let mut n = 0u8;
        let q = Pkce::generate(|buf: &mut [u8]| {
            for b in buf {
                n = n.wrapping_add(53);
                *b = n;
            }
            Ok(())
        })
        .unwrap();
        assert!(q.verifier.bytes().all(|b| UNRESERVED.contains(&b)));
        assert!(Pkce::generate(|_: &mut [u8]| Err("no RNG".into())).is_err(), "a failed RNG stops the sign-in");
    }

    #[test]
    fn login_url_names_the_loopback_redirect_and_s256() {
        let p = Pkce::new("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", "st~ate.1");
        let url = login_url("https://shepetal.app", &redirect_uri(50123), &p);
        assert_eq!(
            url,
            "https://shepetal.app/app/login?redirect_uri=http%3A%2F%2F127.0.0.1%3A50123%2Fcallback\
             &state=st~ate.1&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256"
        );
    }

    #[test]
    fn the_callback_gives_the_code_only_for_this_sign_in() {
        assert_eq!(code_from("code=abc&state=s1", "s1"), Ok("abc".into()));
        assert_eq!(code_from("state=s%201&code=a%2Bb", "s 1"), Ok("a+b".into()), "state comes back percent-encoded");
        assert!(code_from("code=abc&state=other", "s1").is_err(), "another sign-in's answer");
        assert!(code_from("code=abc", "s1").is_err(), "no state");
        assert!(code_from("state=s1", "s1").is_err(), "no code");
        assert!(code_from("state=s1&code=", "s1").is_err());
        let refused = code_from("state=s1&error=access_denied", "s1").unwrap_err();
        assert!(refused.message.contains("access_denied"));
        assert!(code_from("error=x&code=abc", "s1").unwrap_err().message.contains("did not match"), "the state is checked first");
    }

    #[test]
    fn only_https_or_this_pc_is_called() {
        assert!(is_web_page("https://checkout.stripe.com/c/pay/x"));
        assert!(is_web_page("http://localhost:3000/x"));
        assert!(is_web_page("http://127.0.0.1"));
        assert!(!is_web_page("http://evil.example/"));
        assert!(!is_web_page("http://localhost.evil.example/"));
        assert!(!is_web_page("file:///C:/x"));
        assert!(!is_web_page("javascript:alert(1)"));
        assert_eq!(base_url(None), DEFAULT_BASE);
        assert_eq!(DEFAULT_BASE, "https://shepetal.app");
        assert_eq!(base_url(Some("http://localhost:3000/")), "http://localhost:3000");
        assert_eq!(base_url(Some("")), DEFAULT_BASE);
    }

    #[test]
    fn urls_split_for_winhttp() {
        assert_eq!(split_url("https://shepetal.app/api/license"), Some((true, "shepetal.app".into(), 443, "/api/license".into())));
        assert_eq!(split_url("http://127.0.0.1:3000/api/app/token"), Some((false, "127.0.0.1".into(), 3000, "/api/app/token".into())));
        assert_eq!(split_url("https://h"), Some((true, "h".into(), 443, "/".into())));
        assert_eq!(split_url("https://h?x=1"), Some((true, "h".into(), 443, "/?x=1".into())));
        assert_eq!(split_url("ftp://h/x"), None);
        assert_eq!(split_url("https://user@h/x"), None);
        assert_eq!(split_url("https://h:99999/x"), None);
    }

    #[test]
    fn iso_dates_parse_with_and_without_fractions() {
        assert_eq!(parse_date("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(parse_date("2026-11-20T12:00:00.000Z"), Some(1_795_176_000));
        assert_eq!(parse_date("2026-11-20T12:00:00Z"), Some(1_795_176_000));
        assert_eq!(parse_date("2026-11-20T14:00:00+02:00"), Some(1_795_176_000));
        assert_eq!(parse_date("2000-02-29T00:00:00Z"), Some(951_782_400), "leap day");
        for bad in ["", "2026-11-20", "2026-13-01T00:00:00Z", "2026-11-20T12:00:00", "2026-11-20T12:00:00.Z", "abcd-11-20T12:00:00Z"] {
            assert_eq!(parse_date(bad), None, "{bad}");
        }
    }

    fn trial(ends: i64) -> State {
        State {
            license: Some(License { status: Status::Trial, trial_ends_at: Some(ends), email: "a@b.c".into() }),
            last_good_check: Some(NOW),
            last_attempt: Some(NOW),
            offered: true,
        }
    }

    #[test]
    fn access_follows_the_license_and_the_clock() {
        assert_eq!(access(false, &trial(NOW + 30 * DAY), NOW), Access::SignedOut);
        assert_eq!(access(true, &State::default(), NOW), Access::Unchecked, "signed in, never checked");
        assert_eq!(access(true, &trial(NOW + 30 * DAY), NOW), Access::Trial { days_left: 30 });
        assert_eq!(access(true, &trial(NOW + 29 * DAY + 1), NOW), Access::Trial { days_left: 30 }, "a started day counts");
        assert_eq!(access(true, &trial(NOW + 1), NOW), Access::Trial { days_left: 1 });
        assert_eq!(access(true, &trial(NOW), NOW), Access::Expired, "the trial ends at its end date");
        let mut s = trial(0);
        s.license.as_mut().unwrap().status = Status::Active;
        assert_eq!(access(true, &s, NOW), Access::Lifetime);
        s.license.as_mut().unwrap().status = Status::Expired;
        assert_eq!(access(true, &s, NOW), Access::Expired);
    }

    #[test]
    fn the_cache_holds_for_7_days_offline() {
        let mut s = trial(NOW + 30 * DAY);
        s.license.as_mut().unwrap().status = Status::Active;
        assert_eq!(access(true, &s, NOW + OFFLINE_GRACE), Access::Lifetime, "day 7 still counts");
        assert_eq!(access(true, &s, NOW + OFFLINE_GRACE + 1), Access::Unchecked, "after 7 days offline");
        // A trial does not outlive its end by staying offline.
        let t = trial(NOW + 2 * DAY);
        assert_eq!(access(true, &t, NOW + 3 * DAY), Access::Expired);
    }

    #[test]
    fn checks_run_at_launch_daily_and_an_hour_after_a_failure() {
        assert!(check_due(&State::default(), NOW), "at launch");
        let s = trial(NOW + 30 * DAY);
        assert!(!check_due(&s, NOW + CHECK_EVERY - 1));
        assert!(check_due(&s, NOW + CHECK_EVERY));
        let (failed, out) = apply(&Err(AccountError::new("offline")), &s, NOW + 100);
        assert!(!out);
        assert_eq!(failed.license, s.license, "a failed check keeps the cached license");
        assert_eq!(failed.last_good_check, Some(NOW));
        assert!(!check_due(&failed, NOW + 100 + RETRY_AFTER_FAILURE - 1));
        assert!(check_due(&failed, NOW + 100 + RETRY_AFTER_FAILURE));
    }

    #[test]
    fn a_401_signs_out_and_a_good_answer_refreshes_the_cache() {
        let s = trial(NOW + 30 * DAY);
        let (out, signed_out) = apply(&Ok(LicenseReply::Unauthorized), &s, NOW + 5);
        assert!(signed_out);
        assert_eq!(out, State { offered: true, ..State::default() });
        let l = License { status: Status::Active, trial_ends_at: None, email: "a@b.c".into() };
        let (good, signed_out) = apply(&Ok(LicenseReply::License(l.clone())), &State::default(), NOW + 9);
        assert!(!signed_out);
        assert_eq!((good.license, good.last_good_check, good.last_attempt), (Some(l), Some(NOW + 9), Some(NOW + 9)));
    }

    #[test]
    fn the_cache_round_trips_through_its_file_and_never_holds_the_token() {
        let dir = std::env::temp_dir().join(format!("shepetal-license-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("account.json");
        assert_eq!(State::load(&path), State::default(), "no file yet");
        let s = trial(NOW + 30 * DAY);
        s.save(&path).unwrap();
        assert_eq!(State::load(&path), s);
        assert!(!dir.join("account.json.tmp").exists());
        let text = fs::read_to_string(&path).unwrap();
        assert!(!text.contains("token"), "{text}");
        fs::write(&path, "{not json").unwrap();
        assert_eq!(State::load(&path), State::default(), "a broken cache is an empty one");
        fs::remove_dir_all(&dir).unwrap();
    }

    /// Answers each request from a script and records what it was sent.
    struct Fake(RefCell<Vec<Request>>, RefCell<Vec<Result<(u16, String), String>>>);
    impl Http for Fake {
        fn send(&self, r: &Request, _: &Cancel) -> Result<(u16, String), String> {
            self.0.borrow_mut().push(r.clone());
            self.1.borrow_mut().remove(0)
        }
    }
    fn client(answers: Vec<Result<(u16, &str), &str>>) -> Client<Fake> {
        let answers = answers.into_iter().map(|a| a.map(|(s, b)| (s, b.to_string())).map_err(String::from)).collect();
        Client { base: "https://svc".into(), http: Fake(RefCell::default(), RefCell::new(answers)) }
    }

    #[test]
    fn the_token_call_sends_the_code_the_verifier_and_the_same_redirect() {
        let c = client(vec![Ok((200, r#"{"access_token":"tok","email":"a@b.c"}"#))]);
        let r = c.exchange("code1", "ver1", &redirect_uri(5000), &Cancel::default());
        assert_eq!(r, Ok(("tok".into(), "a@b.c".into())));
        let sent = &c.http.0.borrow()[0];
        assert_eq!((sent.method, sent.url.as_str(), sent.bearer.as_deref()), ("POST", "https://svc/api/app/token", None));
        let body: Value = serde_json::from_str(sent.json.as_deref().unwrap()).unwrap();
        assert_eq!(body, json!({"code": "code1", "code_verifier": "ver1", "redirect_uri": "http://127.0.0.1:5000/callback"}));

        let c = client(vec![Ok((400, r#"{"error":"invalid_grant"}"#)), Ok((200, "{}")), Err("offline")]);
        assert!(c.exchange("c", "v", "r", &Cancel::default()).unwrap_err().message.contains("invalid_grant"));
        assert_eq!(c.exchange("c", "v", "r", &Cancel::default()).unwrap_err().status, 200, "no token in a 200");
        assert_eq!(c.exchange("c", "v", "r", &Cancel::default()).unwrap_err().message, "offline");
    }

    #[test]
    fn the_license_call_reads_trial_active_expired_and_401() {
        let c = client(vec![
            Ok((200, r#"{"status":"trial","trial_ends_at":"2026-11-20T12:00:00.000Z","email":"a@b.c"}"#)),
            Ok((200, r#"{"status":"active","trial_ends_at":null,"email":"a@b.c"}"#)),
            Ok((401, r#"{"error":"invalid_token"}"#)),
            Ok((200, r#"{"status":"trial","trial_ends_at":null}"#)),
            Ok((500, "oops")),
            Ok((200, r#"{"status":"gold"}"#)),
        ]);
        let none = Cancel::default();
        assert_eq!(
            c.license("tok", &none),
            Ok(LicenseReply::License(License { status: Status::Trial, trial_ends_at: Some(1_795_176_000), email: "a@b.c".into() }))
        );
        assert_eq!(c.http.0.borrow()[0].bearer.as_deref(), Some("tok"));
        assert_eq!(c.http.0.borrow()[0].url, "https://svc/api/license");
        assert!(matches!(c.license("tok", &none), Ok(LicenseReply::License(License { status: Status::Active, trial_ends_at: None, .. }))));
        assert_eq!(c.license("tok", &none), Ok(LicenseReply::Unauthorized));
        assert!(c.license("tok", &none).is_err(), "a trial without an end date");
        assert_eq!(c.license("tok", &none).unwrap_err().status, 500);
        assert!(c.license("tok", &none).is_err(), "an unknown status");
    }

    #[test]
    fn checkout_opens_only_a_web_page_and_knows_401_and_409() {
        let c = client(vec![
            Ok((200, r#"{"url":"https://checkout.stripe.com/c/pay/cs_test_1"}"#)),
            Ok((200, r#"{"url":"file:///C:/Windows/evil.exe"}"#)),
            Ok((401, "{}")),
            Ok((409, r#"{"error":"already_active"}"#)),
        ]);
        let none = Cancel::default();
        assert_eq!(c.checkout("tok", &none), Ok("https://checkout.stripe.com/c/pay/cs_test_1".into()));
        assert_eq!(c.http.0.borrow()[0].method, "POST");
        assert!(c.checkout("tok", &none).is_err(), "never opens a non-web URL");
        assert_eq!(c.checkout("tok", &none).unwrap_err().status, 401);
        assert_eq!(c.checkout("tok", &none).unwrap_err().status, 409);
    }

    #[test]
    fn a_cancelled_job_sends_nothing() {
        let c = client(vec![]);
        let cancel = Cancel::default();
        cancel.cancel();
        assert_eq!(c.license("tok", &cancel), Err(AccountError::cancelled()));
        assert!(c.http.0.borrow().is_empty());
    }

    #[test]
    fn cancel_runs_the_abort_hook_once() {
        let hits = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let c = Cancel::default();
        let h = hits.clone();
        c.on_cancel(Box::new(move || {
            h.fetch_add(1, Ordering::SeqCst);
        }));
        c.cancel();
        c.cancel();
        assert_eq!(hits.load(Ordering::SeqCst), 1);
        let h = hits.clone();
        c.on_cancel(Box::new(move || {
            h.fetch_add(1, Ordering::SeqCst);
        }));
        assert_eq!(hits.load(Ordering::SeqCst), 2, "a hook set after the cancel runs at once");
    }

    #[test]
    fn no_text_names_a_model() {
        let texts = [SIGN_IN, TRIAL_ENDED, BUY, Access::Unchecked.blocked_hint().unwrap()];
        for t in texts {
            for name in ["whisper", "ggml", "parakeet", "model"] {
                assert!(!t.to_lowercase().contains(name), "{t}");
            }
        }
    }
}
