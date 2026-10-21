//! Sign-in, the 30-day trial and the lifetime license in the running app, as on the Mac
//! (Sources/Shepetal/Account.swift). Pure and single-threaded: the clock comes in as `now` (Unix
//! seconds), the token store as the `Tokens` trait, and network work goes out as `Job`s that
//! `win.rs` runs on a worker thread (`run_job`) and feeds back as `Done`. The license is checked
//! at launch and then every 24 h, never while a dictation runs: a dictation that starts cancels a
//! check in flight. The last good answer is cached in account.json and holds for 7 days offline.

use crate::license::{self, Access, AccountError, Cancel, Client, Http, LicenseReply, Pkce, State, BUY, SIGN_IN};
use crate::loopback::{Loopback, SIGN_IN_TIMEOUT};
use std::path::PathBuf;

/// The account token's store: the Windows Credential Manager in the app (DPAPI-protected, per
/// user), memory in tests. Nothing else holds the token.
pub trait Tokens {
    fn read(&self) -> Option<String>;
    fn write(&self, token: &str) -> Result<(), String>;
    fn delete(&self);
}

/// Whether dictation needs a trial or a license. Off until the account service is live, because
/// before that nobody could sign in and dictation would be off for everyone. The release turns
/// it on with the `require-sign-in` cargo feature; SHEPETAL_REQUIRE_SIGNIN=1 or 0 overrides it
/// for a hand test (the Mac's ShepetalRequiresSignIn and the same variable).
pub fn sign_in_required(env: Option<&str>, built: bool) -> bool {
    env.map_or(built, |v| v == "1")
}

/// A click in the account part of the tray menu.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Command {
    SignIn = 1,
    CancelSignIn,
    Buy,
    CheckNow,
    SignOut,
}

impl Command {
    pub fn id(self) -> u16 {
        self as u16
    }
    pub fn from_id(id: u16) -> Option<Command> {
        [Command::SignIn, Command::CancelSignIn, Command::Buy, Command::CheckNow, Command::SignOut].into_iter().find(|c| c.id() == id)
    }
}

/// Network work for the worker thread.
pub enum Job {
    Check { run: u64, token: String, cancel: Cancel },
    SignIn { run: u64, cancel: Cancel },
    Checkout { token: String },
    Revoke { token: String },
}

#[derive(Debug, PartialEq)]
pub enum Done {
    Check { run: u64, result: Result<LicenseReply, AccountError> },
    /// The token and the email.
    SignIn { run: u64, result: Result<(String, String), AccountError> },
    /// The checkout page, already opened.
    Checkout(Result<String, AccountError>),
}

/// Runs one job, blocking. `open` shows a page in the default browser; `random` fills a buffer
/// from the system's secure generator.
pub fn run_job<H: Http>(client: &Client<H>, job: Job, open: &dyn Fn(&str), random: impl FnMut(&mut [u8]) -> Result<(), String>) -> Option<Done> {
    match job {
        Job::Check { run, token, cancel } => Some(Done::Check { run, result: client.license(&token, &cancel) }),
        Job::SignIn { run, cancel } => Some(Done::SignIn { run, result: sign_in(client, &cancel, open, random) }),
        Job::Checkout { token } => {
            let result = client.checkout(&token, &Cancel::default());
            if let Ok(url) = &result {
                open(url);
            }
            Some(Done::Checkout(result))
        }
        Job::Revoke { token } => {
            let _ = client.revoke(&token, &Cancel::default());
            None
        }
    }
}

/// Google sign-in with PKCE: the login page in the browser, the code from the loopback callback
/// (state checked), then the code and the verifier traded for the token.
fn sign_in<H: Http>(client: &Client<H>, cancel: &Cancel, open: &dyn Fn(&str), random: impl FnMut(&mut [u8]) -> Result<(), String>) -> Result<(String, String), AccountError> {
    let pkce = Pkce::generate(random)?;
    let loopback = Loopback::bind()?;
    let url = license::login_url(&client.base, &loopback.redirect_uri, &pkce);
    if !license::is_web_page(&url) {
        return Err(AccountError::new("Sign-in needs an https address for the account service"));
    }
    open(&url);
    let query = loopback.wait(cancel, SIGN_IN_TIMEOUT)?;
    let code = license::code_from(&query, &pkce.state)?;
    client.exchange(&code, &pkce.verifier, &loopback.redirect_uri, cancel)
}

pub struct Account<T> {
    /// False before the paid launch: sign-in, the trial line and Buy work, but Ctrl+Win always dictates.
    pub required: bool,
    tokens: T,
    token: Option<String>,
    pub state: State,
    /// account.json; None keeps the cache in memory (tests).
    cache: Option<PathBuf>,
    /// The last error or progress line ("" when there is nothing to say).
    pub message: String,
    check: Option<(u64, Cancel)>,
    sign_in: Option<(u64, Cancel)>,
    runs: u64,
    /// After checkout opens, re-check every minute for an hour so the purchase shows up.
    recheck_until: Option<i64>,
    /// Say the trial days or "Yours forever" next to 🤫 once the first check after sign-in answers.
    announce: bool,
    jobs: Vec<Job>,
    hints: Vec<String>,
}

impl<T: Tokens> Account<T> {
    pub fn new(tokens: T, cache: Option<PathBuf>, required: bool) -> Account<T> {
        let token = tokens.read();
        let state = cache.as_deref().map(State::load).unwrap_or_default();
        Account { required, tokens, token, state, cache, message: String::new(), check: None, sign_in: None, runs: 0, recheck_until: None, announce: false, jobs: vec![], hints: vec![] }
    }

    pub fn signed_in(&self) -> bool {
        self.token.is_some()
    }
    pub fn signing_in(&self) -> bool {
        self.sign_in.is_some()
    }
    pub fn email(&self) -> &str {
        self.state.license.as_ref().map_or("", |l| &l.email)
    }
    pub fn access(&self, now: i64) -> Access {
        license::access(self.signed_in(), &self.state, now)
    }

    /// What `win.rs` should run now, and what to show next to 🤫.
    pub fn take_jobs(&mut self) -> Vec<Job> {
        std::mem::take(&mut self.jobs)
    }
    pub fn take_hints(&mut self) -> Vec<String> {
        std::mem::take(&mut self.hints)
    }

    /// At launch: check the license if signed in, and say why dictation is off if it is.
    pub fn start(&mut self, now: i64) {
        self.check(false);
        let a = self.access(now);
        // A signed-in user whose cache is stale gets the answer of the check that just started instead.
        if let Some(h) = a.blocked_hint().filter(|_| self.required && (a != Access::Unchecked || !self.signed_in())) {
            self.hints.push(h.into());
        }
    }

    /// Every minute: a check when one is due, unless a dictation runs.
    pub fn tick(&mut self, now: i64, dictating: bool) {
        if !self.signed_in() {
            return;
        }
        let recheck = self.recheck_until.is_some_and(|t| now < t && self.access(now) != Access::Lifetime);
        if recheck || license::check_due(&self.state, now) {
            self.check(dictating);
        }
    }

    /// The Ctrl+Win gate, on each dictation start. False: dictation is off and the hint says why.
    /// True: the press goes on, and a check in flight is cancelled so no request runs while the
    /// user dictates.
    pub fn allow_hotkey(&mut self, now: i64) -> bool {
        if self.access(now).allows_dictation() || !self.required {
            if let Some((_, cancel)) = self.check.take() {
                cancel.cancel();
            }
            return true;
        }
        let hint = if self.signing_in() { "Finish signing in with Google first" } else { self.access(now).blocked_hint().unwrap_or("") };
        self.hints.push(hint.into());
        // Nothing is being dictated, so ask again: a purchase on the website or a network that came
        // back unlocks on the next press instead of the next day. At most once a minute.
        if self.signed_in() && now - self.state.last_attempt.unwrap_or(i64::MIN / 2) >= 60 {
            self.check(false);
        }
        false
    }

    pub fn command(&mut self, cmd: Command, dictating: bool) {
        match cmd {
            Command::SignIn => self.sign_in(),
            Command::CancelSignIn => self.cancel_sign_in(),
            Command::Buy => self.buy(),
            Command::CheckNow => self.check(dictating),
            Command::SignOut => self.sign_out(),
        }
    }

    /// One license check in the background, unless one runs or the user is dictating.
    fn check(&mut self, dictating: bool) {
        let Some(token) = self.token.clone().filter(|_| self.check.is_none() && !dictating) else { return };
        self.runs += 1;
        let cancel = Cancel::default();
        self.check = Some((self.runs, cancel.clone()));
        self.jobs.push(Job::Check { run: self.runs, token, cancel });
    }

    pub fn sign_in(&mut self) {
        if self.signing_in() {
            return;
        }
        self.runs += 1;
        let cancel = Cancel::default();
        self.sign_in = Some((self.runs, cancel.clone()));
        self.jobs.push(Job::SignIn { run: self.runs, cancel });
        self.message = "Signing in with Google…".into();
    }

    /// Stops waiting for the browser (it may also never come back).
    pub fn cancel_sign_in(&mut self) {
        if let Some((_, cancel)) = self.sign_in.take() {
            cancel.cancel();
        }
        self.message.clear();
    }

    pub fn sign_out(&mut self) {
        self.cancel_sign_in();
        if let Some((_, cancel)) = self.check.take() {
            cancel.cancel();
        }
        if let Some(token) = self.token.take() {
            self.jobs.push(Job::Revoke { token });
        }
        self.tokens.delete();
        self.state = State { offered: self.state.offered, ..State::default() };
        self.save();
        self.recheck_until = None;
    }

    /// Opens Stripe Checkout for the lifetime license in the browser.
    pub fn buy(&mut self) {
        let Some(token) = self.token.clone() else { return self.sign_in() };
        self.message = "Opening checkout…".into();
        self.jobs.push(Job::Checkout { token });
    }

    pub fn mark_offered(&mut self) {
        self.state.offered = true;
        self.save();
    }

    pub fn finish(&mut self, done: Done, now: i64) {
        match done {
            Done::Check { run, result } => {
                if self.check.as_ref().map(|c| c.0) != Some(run) {
                    return; // cancelled by a dictation, or a sign-out: the next tick tries again
                }
                self.check = None;
                let (state, signed_out) = license::apply(&result, &self.state, now);
                self.state = state;
                self.save();
                if signed_out {
                    self.tokens.delete();
                    self.token = None;
                    self.message = "Signed out on the account service. Sign in again.".into();
                } else if let Err(e) = &result {
                    self.message = format!("Could not check the license: {e}");
                } else {
                    self.message.clear();
                    if std::mem::take(&mut self.announce) {
                        self.hints.push(self.summary_line(now));
                    }
                }
            }
            Done::SignIn { run, result } => {
                if self.sign_in.as_ref().map(|s| s.0) != Some(run) {
                    return; // cancelled
                }
                self.sign_in = None;
                match result {
                    Ok((token, _)) => match self.tokens.write(&token) {
                        Ok(()) => {
                            self.token = Some(token);
                            self.state = State { offered: true, ..State::default() };
                            self.save();
                            self.message.clear();
                            self.announce = true;
                            self.check(false);
                        }
                        Err(e) => self.fail(format!("Could not save the sign-in: {e}")),
                    },
                    Err(e) if e == AccountError::cancelled() => self.message.clear(),
                    Err(e) => self.fail(format!("Sign-in failed: {e}")),
                }
            }
            Done::Checkout(result) => match result {
                Ok(_) => {
                    self.message.clear();
                    self.recheck_until = Some(now + 3600);
                }
                // Bought already (another PC, or before the re-check ran): show "Yours forever".
                Err(e) if e.status == 409 => {
                    self.message.clear();
                    self.check(false);
                }
                Err(e) if e.status == 401 => {
                    self.sign_out();
                    self.message = "Signed out on the account service. Sign in again, then buy.".into();
                }
                Err(e) => self.fail(format!("Checkout failed: {e}")),
            },
        }
    }

    /// A failure the user started (sign-in, checkout): in the menu, and next to 🤫 now.
    fn fail(&mut self, message: String) {
        self.hints.push(message.clone());
        self.message = message;
    }

    /// One line for the tray menu.
    pub fn summary_line(&self, now: i64) -> String {
        let a = self.access(now);
        if self.signing_in() {
            "Signing in with Google…".into()
        } else if !self.email().is_empty() && a != Access::SignedOut {
            format!("{} · {}", a.summary(), self.email())
        } else {
            a.summary()
        }
    }

    /// The account part of the tray menu: plain lines (None) and clickable ones.
    pub fn menu(&self, now: i64) -> Vec<(String, Option<Command>)> {
        let mut items = vec![(self.summary_line(now), None)];
        let mut add = |label: &str, cmd| items.push((label.to_string(), Some(cmd)));
        match self.access(now) {
            Access::SignedOut if self.signing_in() => add("Cancel sign-in", Command::CancelSignIn),
            Access::SignedOut => add(&format!("{SIGN_IN}…"), Command::SignIn),
            Access::Trial { .. } => add(&format!("{BUY}…"), Command::Buy),
            Access::Expired => {
                add(&format!("{BUY}…"), Command::Buy);
                add("Check license now", Command::CheckNow); // bought on the website
            }
            Access::Unchecked => add("Check license now", Command::CheckNow),
            Access::Lifetime => {}
        }
        if self.signed_in() {
            add("Sign out", Command::SignOut);
        }
        if !self.message.is_empty() && !self.signing_in() {
            items.push((self.message.clone(), None));
        }
        items
    }

    fn save(&mut self) {
        if let Some(path) = &self.cache {
            if let Err(e) = self.state.save(path) {
                self.message = format!("Could not save the license: {e}");
            }
        }
    }
}

/// The first-run dialog's texts (`win.rs` shows them with `dialog::ask`).
pub mod text {
    use crate::license::Access;

    pub const INTRO: &str = "Sign in with Google to start your free 30-day trial. No card needed.\n\n\
        After the trial, Shepetal is $4.99 once: yours forever, with future updates.";
    pub const INTRO_BUTTONS: [&str; 2] = ["Sign in", "Not now"];
    pub const WAITING: &str = "Finish signing in with Google in your browser.\n\nThis closes by itself when you are done.";
    pub const ENDED: &str = "Your free trial has ended.\n\nGet Shepetal for $4.99 once: yours forever, with future updates.";
    pub const ENDED_BUTTONS: [&str; 2] = ["Get Shepetal", "Not now"];

    /// After sign-in: who, and the days left or "Yours forever".
    pub fn signed_in(email: &str, access: Access) -> String {
        let who = if email.is_empty() { "Signed in.".to_string() } else { format!("Signed in as {email}.") };
        match access {
            Access::Trial { .. } | Access::Lifetime => format!("{who}\n\n{}.", access.summary()),
            Access::Expired => format!("{who}\n\n{ENDED}"),
            Access::Unchecked | Access::SignedOut => format!("{who}\n\nShepetal could not check your license yet. It tries again in the background."),
        }
    }
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use crate::license::{License, Request, Status, DAY, OFFLINE_GRACE};
    use std::cell::RefCell;
    use std::rc::Rc;

    const T0: i64 = 1_792_000_000;

    /// Shared, so a test can look at the store the account owns.
    #[derive(Clone, Default)]
    pub struct MemoryTokens {
        pub token: Rc<RefCell<Option<String>>>,
        pub fail: bool,
    }
    impl Tokens for MemoryTokens {
        fn read(&self) -> Option<String> {
            self.token.borrow().clone()
        }
        fn write(&self, token: &str) -> Result<(), String> {
            if self.fail {
                return Err("Credential Manager is locked".into());
            }
            *self.token.borrow_mut() = Some(token.into());
            Ok(())
        }
        fn delete(&self) {
            *self.token.borrow_mut() = None;
        }
    }

    fn trial(days: i64, now: i64) -> Result<LicenseReply, AccountError> {
        Ok(LicenseReply::License(License { status: Status::Trial, trial_ends_at: Some(now + days * DAY), email: "a@b.c".into() }))
    }
    fn active() -> Result<LicenseReply, AccountError> {
        Ok(LicenseReply::License(License { status: Status::Active, trial_ends_at: None, email: "a@b.c".into() }))
    }

    fn account(token: Option<&str>, required: bool) -> (Account<MemoryTokens>, MemoryTokens) {
        let tokens = MemoryTokens::default();
        *tokens.token.borrow_mut() = token.map(String::from);
        (Account::new(tokens.clone(), None, required), tokens)
    }

    /// The run of the one check job waiting, panicking if there is not exactly one.
    fn check_run(a: &mut Account<MemoryTokens>) -> u64 {
        let jobs = a.take_jobs();
        assert_eq!(jobs.len(), 1, "one job");
        match &jobs[0] {
            Job::Check { run, token, .. } => {
                assert_eq!(token, "tok");
                *run
            }
            _ => panic!("not a check"),
        }
    }

    #[test]
    fn the_build_flag_and_the_variable_decide_whether_sign_in_is_required() {
        assert!(!sign_in_required(None, false), "off until the service is live");
        assert!(sign_in_required(None, true), "the require-sign-in build");
        assert!(!sign_in_required(Some("0"), true));
        assert!(sign_in_required(Some("1"), false));
        assert!(!sign_in_required(Some("yes"), false));
    }

    #[test]
    fn signed_out_ctrl_win_only_shows_the_sign_in_hint() {
        let (mut a, _) = account(None, true);
        a.start(T0);
        assert!(a.take_jobs().is_empty(), "nothing to check without a token");
        assert_eq!(a.take_hints(), [SIGN_IN], "at launch");
        assert!(!a.allow_hotkey(T0));
        assert_eq!(a.take_hints(), [SIGN_IN]);
        assert_eq!(a.menu(T0), [("Not signed in".to_string(), None), (format!("{SIGN_IN}…"), Some(Command::SignIn))]);
        // Not required (before the paid launch): Ctrl+Win dictates.
        let (mut free, _) = account(None, false);
        free.start(T0);
        assert!(free.take_hints().is_empty());
        assert!(free.allow_hotkey(T0));
    }

    #[test]
    fn sign_in_stores_the_token_checks_and_says_the_days_left() {
        let (mut a, tokens) = account(None, true);
        a.command(Command::SignIn, false);
        let run = match a.take_jobs().as_slice() {
            [Job::SignIn { run, .. }] => *run,
            _ => panic!("a sign-in job"),
        };
        assert_eq!(a.menu(T0)[0].0, "Signing in with Google…");
        assert_eq!(a.menu(T0)[1], ("Cancel sign-in".to_string(), Some(Command::CancelSignIn)));
        assert!(!a.allow_hotkey(T0));
        assert_eq!(a.take_hints(), ["Finish signing in with Google first"]);

        a.finish(Done::SignIn { run, result: Ok(("tok".into(), "a@b.c".into())) }, T0 + 30);
        assert_eq!(tokens.read().as_deref(), Some("tok"), "the token is in the store");
        let check = check_run(&mut a);
        assert_eq!(a.access(T0 + 31), Access::Unchecked);
        a.finish(Done::Check { run: check, result: trial(30, T0 + 31) }, T0 + 31);
        assert_eq!(a.access(T0 + 31), Access::Trial { days_left: 30 });
        assert_eq!(a.take_hints(), ["Free trial: 30 days left · a@b.c"]);
        assert!(a.allow_hotkey(T0 + 40));
        let menu = a.menu(T0 + 40);
        assert_eq!(menu[0].0, "Free trial: 30 days left · a@b.c");
        assert_eq!(menu[1], (format!("{BUY}…"), Some(Command::Buy)));
        assert_eq!(menu[2], ("Sign out".to_string(), Some(Command::SignOut)));
        // Days go down with the clock, even with no new check.
        assert_eq!(a.access(T0 + 31 + 5 * DAY), Access::Trial { days_left: 25 });
    }

    #[test]
    fn a_token_that_cannot_be_stored_is_not_kept() {
        let (mut a, tokens) = account(None, true);
        let tokens_fail = MemoryTokens { fail: true, ..tokens };
        a.tokens = tokens_fail;
        a.sign_in();
        let run = match a.take_jobs().as_slice() {
            [Job::SignIn { run, .. }] => *run,
            _ => panic!(),
        };
        a.finish(Done::SignIn { run, result: Ok(("tok".into(), "a@b.c".into())) }, T0);
        assert!(!a.signed_in());
        assert!(a.message.contains("Credential Manager is locked"), "{}", a.message);
        assert!(a.take_jobs().is_empty());
    }

    #[test]
    fn a_cancelled_sign_in_ignores_a_late_answer() {
        let (mut a, tokens) = account(None, true);
        a.sign_in();
        let (run, cancel) = match a.take_jobs().pop() {
            Some(Job::SignIn { run, cancel }) => (run, cancel),
            _ => panic!(),
        };
        a.command(Command::CancelSignIn, false);
        assert!(cancel.is_cancelled(), "the worker stops waiting for the browser");
        a.finish(Done::SignIn { run, result: Ok(("tok".into(), "a@b.c".into())) }, T0);
        assert!(!a.signed_in());
        assert_eq!(tokens.read(), None);
        a.sign_in();
        let run = match a.take_jobs().pop() {
            Some(Job::SignIn { run, .. }) => run,
            _ => panic!(),
        };
        a.finish(Done::SignIn { run, result: Err(AccountError::new("access_denied")) }, T0);
        assert_eq!(a.take_hints(), ["Sign-in failed: access_denied"]);
    }

    #[test]
    fn the_license_is_checked_at_launch_then_every_24_h() {
        let (mut a, _) = account(Some("tok"), true);
        a.start(T0);
        let run = check_run(&mut a);
        assert!(a.take_hints().is_empty(), "a stale cache waits for the check's answer");
        a.tick(T0 + 1, false);
        assert!(a.take_jobs().is_empty(), "one check at a time");
        a.finish(Done::Check { run, result: active() }, T0 + 2);
        assert_eq!(a.access(T0 + 2), Access::Lifetime);
        assert_eq!(a.menu(T0 + 2), [("Yours forever · a@b.c".to_string(), None), ("Sign out".to_string(), Some(Command::SignOut))]);
        a.tick(T0 + DAY + 1, false);
        assert!(a.take_jobs().is_empty(), "not before 24 h");
        a.tick(T0 + DAY + 2, false);
        check_run(&mut a);
    }

    #[test]
    fn no_check_runs_during_a_dictation() {
        let (mut a, _) = account(Some("tok"), true);
        a.start(T0);
        let run = check_run(&mut a);
        a.finish(Done::Check { run, result: trial(30, T0) }, T0);
        // Due, but the user is dictating: nothing goes out.
        a.tick(T0 + DAY, true);
        assert!(a.take_jobs().is_empty());
        a.command(Command::CheckNow, true);
        assert!(a.take_jobs().is_empty(), "not from the tray either");
        // A check in flight is cancelled when a dictation starts, and its answer is dropped.
        a.tick(T0 + DAY, false);
        let (run, cancel) = match a.take_jobs().pop() {
            Some(Job::Check { run, cancel, .. }) => (run, cancel),
            _ => panic!(),
        };
        assert!(a.allow_hotkey(T0 + DAY + 1));
        assert!(cancel.is_cancelled(), "the request is aborted");
        a.finish(Done::Check { run, result: Ok(LicenseReply::Unauthorized) }, T0 + DAY + 2);
        assert!(a.signed_in(), "a cancelled check's answer changes nothing");
        a.tick(T0 + DAY + 60, false);
        check_run(&mut a);
    }

    #[test]
    fn offline_the_cached_answer_holds_for_7_days() {
        let (mut a, _) = account(Some("tok"), true);
        a.start(T0);
        let run = check_run(&mut a);
        a.finish(Done::Check { run, result: active() }, T0);
        let offline = || Err(AccountError::new("The server name could not be resolved"));
        let mut now = T0 + DAY;
        while now <= T0 + OFFLINE_GRACE {
            a.tick(now, false);
            let run = check_run(&mut a);
            a.finish(Done::Check { run, result: offline() }, now);
            assert_eq!(a.access(now), Access::Lifetime, "day {}", (now - T0) / DAY);
            assert!(a.allow_hotkey(now));
            now += 3600 * 6;
        }
        assert!(a.message.starts_with("Could not check the license"));
        let late = T0 + OFFLINE_GRACE + 120;
        assert_eq!(a.access(late), Access::Unchecked);
        assert!(!a.allow_hotkey(late));
        assert_eq!(a.take_hints(), ["Connect to the internet so Shepetal can check your license"]);
        // The network is back: the press asked again, and its answer unlocks.
        let run = check_run(&mut a);
        a.finish(Done::Check { run, result: active() }, late + 5);
        assert!(a.allow_hotkey(late + 6));
    }

    #[test]
    fn a_401_signs_out_and_deletes_the_token() {
        let (mut a, tokens) = account(Some("tok"), true);
        a.start(T0);
        let run = check_run(&mut a);
        a.finish(Done::Check { run, result: Ok(LicenseReply::Unauthorized) }, T0);
        assert!(!a.signed_in());
        assert_eq!(tokens.read(), None);
        assert_eq!(a.access(T0), Access::SignedOut);
    }

    #[test]
    fn after_the_trial_buy_opens_checkout_then_rechecks_for_an_hour() {
        let (mut a, _) = account(Some("tok"), true);
        a.start(T0);
        let run = check_run(&mut a);
        a.finish(Done::Check { run, result: trial(1, T0) }, T0);
        let ended = T0 + DAY;
        assert_eq!(a.access(ended), Access::Expired);
        assert!(!a.allow_hotkey(ended));
        assert_eq!(a.take_hints(), [license::TRIAL_ENDED]);
        a.take_jobs(); // the press asked again
        a.check = None;
        let menu = a.menu(ended);
        assert_eq!(menu[0].0, "Trial ended · a@b.c");
        assert_eq!(menu[1], (format!("{BUY}…"), Some(Command::Buy)));
        assert_eq!(menu[2], ("Check license now".to_string(), Some(Command::CheckNow)));
        a.command(Command::Buy, false);
        assert!(matches!(a.take_jobs().as_slice(), [Job::Checkout { token }] if token == "tok"));
        a.finish(Done::Checkout(Ok("https://checkout.stripe.com/c/pay/cs_test".into())), ended);
        a.tick(ended + 60, false);
        let run = check_run(&mut a);
        a.finish(Done::Check { run, result: trial(-1, ended) }, ended + 61);
        a.tick(ended + 120, false);
        let run = check_run(&mut a);
        a.finish(Done::Check { run, result: active() }, ended + 121);
        assert_eq!(a.access(ended + 121), Access::Lifetime, "the purchase shows up within minutes");
        a.tick(ended + 180, false);
        assert!(a.take_jobs().is_empty(), "no more rechecks once it is bought");
    }

    #[test]
    fn checkout_409_checks_and_401_signs_out() {
        let (mut a, tokens) = account(Some("tok"), true);
        a.finish(Done::Checkout(Err(AccountError { message: "You already own Shepetal".into(), status: 409 })), T0);
        check_run(&mut a);
        a.check = None;
        a.finish(Done::Checkout(Err(AccountError { message: "x".into(), status: 401 })), T0);
        assert_eq!(tokens.read(), None);
        assert!(a.message.contains("Sign in again, then buy"));
    }

    #[test]
    fn sign_out_revokes_and_forgets_everything_but_the_first_run_offer() {
        let (mut a, tokens) = account(Some("tok"), true);
        a.mark_offered();
        a.start(T0);
        let run = check_run(&mut a);
        a.finish(Done::Check { run, result: active() }, T0);
        a.command(Command::SignOut, false);
        assert!(matches!(a.take_jobs().as_slice(), [Job::Revoke { token }] if token == "tok"));
        assert_eq!(tokens.read(), None);
        assert_eq!(a.state, State { offered: true, ..State::default() });
        assert_eq!(a.access(T0), Access::SignedOut);
    }

    #[test]
    fn the_cache_survives_a_restart() {
        let dir = std::env::temp_dir().join(format!("shepetal-account-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("account.json");
        let tokens = MemoryTokens::default();
        *tokens.token.borrow_mut() = Some("tok".into());
        let mut a = Account::new(tokens.clone(), Some(path.clone()), true);
        a.start(T0);
        let run = check_run(&mut a);
        a.finish(Done::Check { run, result: trial(30, T0) }, T0);
        drop(a);
        let b = Account::new(tokens, Some(path), true);
        assert_eq!(b.access(T0 + DAY), Access::Trial { days_left: 29 }, "offline at the next launch");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn the_first_run_dialog_shows_the_days_left_or_yours_forever() {
        assert_eq!(text::signed_in("a@b.c", Access::Trial { days_left: 30 }), "Signed in as a@b.c.\n\nFree trial: 30 days left.");
        assert_eq!(text::signed_in("a@b.c", Access::Lifetime), "Signed in as a@b.c.\n\nYours forever.");
        assert!(text::signed_in("", Access::Expired).contains("$4.99"));
        assert!(text::INTRO.contains("30-day") && text::INTRO.contains("$4.99"));
        let all = [text::INTRO, text::WAITING, text::ENDED, &text::signed_in("", Access::Unchecked)].join(" ").to_lowercase();
        for name in ["whisper", "ggml", "model"] {
            assert!(!all.contains(name), "{name}");
        }
    }

    #[test]
    fn command_ids_round_trip() {
        for c in [Command::SignIn, Command::CancelSignIn, Command::Buy, Command::CheckNow, Command::SignOut] {
            assert_eq!(Command::from_id(c.id()), Some(c));
        }
        assert_eq!(Command::from_id(0), None);
    }

    /// The account service: /api/app/token checks the verifier against the challenge the login
    /// URL carried, as the real one does.
    struct Service {
        challenge: std::sync::Mutex<String>,
        sent: std::sync::Mutex<Vec<Request>>,
    }
    impl Http for &Service {
        fn send(&self, r: &Request, _: &Cancel) -> Result<(u16, String), String> {
            self.sent.lock().unwrap().push(r.clone());
            let body: serde_json::Value = serde_json::from_str(r.json.as_deref().unwrap_or("{}")).unwrap();
            let verifier = body["code_verifier"].as_str().unwrap_or("");
            if license::challenge(verifier) == *self.challenge.lock().unwrap() && body["code"] == "the-code" {
                Ok((200, r#"{"access_token":"tok","email":"a@b.c"}"#.into()))
            } else {
                Ok((400, r#"{"error":"invalid_grant"}"#.into()))
            }
        }
    }

    fn query_value(url: &str, name: &str) -> String {
        let q = url.split_once('?').unwrap().1;
        let v = q.split('&').find_map(|kv| kv.strip_prefix(&format!("{name}="))).unwrap();
        v.replace("%3A", ":").replace("%2F", "/")
    }

    #[test]
    fn sign_in_end_to_end_through_the_loopback() {
        let service = Service { challenge: Default::default(), sent: Default::default() };
        let client = Client { base: "https://svc".into(), http: &service };
        // The "browser": signs in and follows the redirect to the loopback with the state it got.
        let browser = |url: &str| {
            assert!(url.starts_with("https://svc/app/login?redirect_uri=http%3A%2F%2F127.0.0.1%3A"), "{url}");
            assert!(url.ends_with("&code_challenge_method=S256"));
            *service.challenge.lock().unwrap() = query_value(url, "code_challenge");
            let redirect = query_value(url, "redirect_uri");
            let state = query_value(url, "state");
            let addr = redirect.trim_start_matches("http://").trim_end_matches("/callback").to_string();
            std::thread::spawn(move || {
                use std::io::{Read, Write};
                let mut s = std::net::TcpStream::connect(addr).unwrap();
                write!(s, "GET /callback?code=the-code&state={state} HTTP/1.1\r\nHost: x\r\n\r\n").unwrap();
                let mut page = String::new();
                s.read_to_string(&mut page).unwrap();
                assert!(page.contains("You can close this tab"));
            });
        };
        let mut n = 0u8;
        let random = |b: &mut [u8]| {
            b.iter_mut().for_each(|b| (*b, n) = (n % 198, n.wrapping_add(31)));
            Ok(())
        };
        let done = run_job(&client, Job::SignIn { run: 4, cancel: Cancel::default() }, &browser, random);
        assert_eq!(done, Some(Done::SignIn { run: 4, result: Ok(("tok".into(), "a@b.c".into())) }));
        let sent = service.sent.lock().unwrap();
        let body: serde_json::Value = serde_json::from_str(sent[0].json.as_deref().unwrap()).unwrap();
        assert!(body["redirect_uri"].as_str().unwrap().starts_with("http://127.0.0.1:"), "the same redirect as the login URL");
    }

    #[test]
    fn a_callback_from_another_sign_in_never_reaches_the_token_call() {
        let service = Service { challenge: Default::default(), sent: Default::default() };
        let client = Client { base: "https://svc".into(), http: &service };
        let browser = |url: &str| {
            let addr = query_value(url, "redirect_uri").trim_start_matches("http://").trim_end_matches("/callback").to_string();
            std::thread::spawn(move || {
                use std::io::{Read, Write};
                let mut s = std::net::TcpStream::connect(addr).unwrap();
                write!(s, "GET /callback?code=the-code&state=forged HTTP/1.1\r\n\r\n").unwrap();
                s.read_to_string(&mut String::new()).unwrap();
            });
        };
        let done = run_job(&client, Job::SignIn { run: 1, cancel: Cancel::default() }, &browser, |b: &mut [u8]| {
            b.fill(7);
            Ok(())
        });
        assert!(matches!(done, Some(Done::SignIn { result: Err(_), .. })));
        assert!(service.sent.lock().unwrap().is_empty());
    }

    #[test]
    fn checkout_opens_the_page_in_the_browser() {
        struct Stripe;
        impl Http for Stripe {
            fn send(&self, _: &Request, _: &Cancel) -> Result<(u16, String), String> {
                Ok((200, r#"{"url":"https://checkout.stripe.com/c/pay/cs_test_1"}"#.into()))
            }
        }
        let opened = RefCell::new(vec![]);
        let client = Client { base: "https://svc".into(), http: Stripe };
        let done = run_job(&client, Job::Checkout { token: "tok".into() }, &|u: &str| opened.borrow_mut().push(u.to_string()), |_: &mut [u8]| Ok(()));
        assert_eq!(done, Some(Done::Checkout(Ok("https://checkout.stripe.com/c/pay/cs_test_1".into()))));
        assert_eq!(*opened.borrow(), ["https://checkout.stripe.com/c/pay/cs_test_1"]);
    }
}
