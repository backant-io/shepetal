//! The Windows side of shepetal.exe: single instance, first-run onboarding (mic privacy and the
//! model download, then Google sign-in), start at login, and the wiring of the sibling crates.
//! Threads: input runs the hook, the 🤫 overlay and the tray on its own thread; this one runs the
//! gesture, `flow::Flow` and `account::Account`; one more loads the model and transcribes;
//! meetings poll on another; each account job (sign-in, license check, checkout) gets its own.

use crate::account::{self, text, Account, Command, Done};
use crate::dialog::{self, Card};
use crate::license::{self, Access, Client};
use crate::flow::{self, Flow, Kept};
use crate::meeting::{self, Show};
use crate::system::{self, MIC_CONSENT, MIC_CONSENT_DESKTOP, MIC_SETTINGS, MUTEX, RUN_KEY, RUN_VALUE};
use crate::winaccount::{self, CredTokens, WinHttp};
use shepetal_core::gesture::{Action, Gesture, HINT_MS};
use std::path::{Path, PathBuf};
use std::ptr::{null, null_mut};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use windows_sys::Win32::Foundation::{GetLastError, ERROR_ALREADY_EXISTS, ERROR_FILE_NOT_FOUND, ERROR_SUCCESS};
use windows_sys::Win32::System::Com::{CoInitializeEx, COINIT_APARTMENTTHREADED};
use windows_sys::Win32::System::Registry::{
    RegDeleteKeyValueW, RegGetValueW, RegSetKeyValueW, HKEY, HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, REG_SZ, RRF_RT_REG_SZ,
};
use windows_sys::Win32::System::Threading::CreateMutexW;
use windows_sys::Win32::UI::Shell::ShellExecuteW;
use windows_sys::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;

/// Audio kept from just before the hotkey went down, so the first syllable is never cut.
const PRE_ROLL: Duration = Duration::from_millis(300);
const HINT: Duration = Duration::from_millis(HINT_MS);
/// How often the account looks whether a license check is due (the check itself is daily).
const ACCOUNT_TICK: Duration = Duration::from_secs(60);

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain([0]).collect()
}

/// Takes the named mutex. The handle stays open until the process exits, which frees the name.
fn already_running() -> bool {
    let h = unsafe { CreateMutexW(null(), 0, wide(MUTEX).as_ptr()) };
    !h.is_null() && unsafe { GetLastError() } == ERROR_ALREADY_EXISTS
}

fn reg_string(root: HKEY, key: &str, value: &str) -> Option<String> {
    let (key, value) = (wide(key), wide(value));
    let mut buf = [0u16; 2048];
    let mut bytes = std::mem::size_of_val(&buf) as u32;
    let r = unsafe { RegGetValueW(root, key.as_ptr(), value.as_ptr(), RRF_RT_REG_SZ, null_mut(), buf.as_mut_ptr().cast(), &mut bytes) };
    // `bytes` counts the terminating NUL.
    (r == ERROR_SUCCESS).then(|| String::from_utf16_lossy(&buf[..(bytes as usize / 2).saturating_sub(1)]))
}

fn starts_at_login() -> bool {
    reg_string(HKEY_CURRENT_USER, RUN_KEY, RUN_VALUE).is_some()
}

fn set_start_at_login(on: bool) -> Result<(), String> {
    let (key, name) = (wide(RUN_KEY), wide(RUN_VALUE));
    let r = if on {
        let exe = std::env::current_exe().map_err(|e| e.to_string())?;
        let data = wide(&system::run_command(&exe));
        unsafe { RegSetKeyValueW(HKEY_CURRENT_USER, key.as_ptr(), name.as_ptr(), REG_SZ, data.as_ptr().cast(), (data.len() * 2) as u32) }
    } else {
        unsafe { RegDeleteKeyValueW(HKEY_CURRENT_USER, key.as_ptr(), name.as_ptr()) }
    };
    match r {
        ERROR_SUCCESS => Ok(()),
        ERROR_FILE_NOT_FOUND if !on => Ok(()),
        r => Err(format!("Could not change start at login (error {r}).")),
    }
}

fn mic_allowed() -> bool {
    let device = reg_string(HKEY_LOCAL_MACHINE, MIC_CONSENT, "Value");
    let apps = reg_string(HKEY_CURRENT_USER, MIC_CONSENT, "Value");
    let desktop = reg_string(HKEY_CURRENT_USER, MIC_CONSENT_DESKTOP, "Value");
    system::mic_allowed([device.as_deref(), apps.as_deref(), desktop.as_deref()])
}

fn message(text: &str) {
    dialog::ask(text, &["OK"]);
}

fn ask(text: &str) -> bool {
    dialog::ask(text, &["Yes", "No"]) == Some(0)
}

/// Opens a folder, a URL or an ms-settings: page with its default handler.
fn open(target: &str) {
    unsafe { ShellExecuteW(null_mut(), wide("open").as_ptr(), wide(target).as_ptr(), null(), null(), SW_SHOWNORMAL) };
}

fn unix_now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs() as i64)
}

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok()
}

fn account_client() -> Client<WinHttp> {
    Client { base: license::base_url(env("SHEPETAL_ACCOUNT_URL").as_deref()), http: WinHttp }
}

/// The login page or Stripe Checkout in the default browser, from a job's thread.
fn open_page(url: &str) {
    if license::is_web_page(url) {
        unsafe { CoInitializeEx(null(), COINIT_APARTMENTTHREADED as u32) }; // ShellExecute wants COM
        open(url);
    }
}

/// Runs one account job on this thread.
fn run_account_job(job: account::Job) -> Option<Done> {
    account::run_job(&account_client(), job, &open_page, winaccount::random)
}

/// Each waiting account job on its own thread; its answer comes back as `Msg::Account`.
fn spawn_account_jobs(account: &mut Account<CredTokens>, tx: &Sender<Msg>) {
    for job in account.take_jobs() {
        let tx = tx.clone();
        thread::spawn(move || run_account_job(job).map(|done| tx.send(Msg::Account(done))));
    }
}

/// The first-run dialog: sign in for the free trial (every start when sign-in is required,
/// else once), and after it the days left or "Yours forever". When the trial has ended, the
/// offer to buy. Before the 🤫 and the hook exist, so it may wait for the network.
fn account_onboarding(account: &mut Account<CredTokens>) {
    let now = unix_now();
    match account.access(now) {
        Access::SignedOut if account.required || !account.state.offered => {
            account.mark_offered();
            if dialog::ask(text::INTRO, &text::INTRO_BUTTONS) != Some(0) {
                return;
            }
            account.sign_in();
            let Some(job) = account.take_jobs().pop() else { return };
            let (tx, rx) = mpsc::channel();
            let waiting = Arc::new(AtomicBool::new(true));
            let w = waiting.clone();
            let worker = thread::spawn(move || {
                let _ = tx.send(run_account_job(job));
                // The wait dialog may not be up yet: close it until this thread is past it.
                while w.load(Ordering::SeqCst) {
                    winaccount::dismiss_dialog();
                    thread::sleep(Duration::from_millis(100));
                }
            });
            dialog::ask(text::WAITING, &["Cancel"]);
            waiting.store(false, Ordering::SeqCst);
            let done = rx.try_recv();
            if done.is_err() {
                account.cancel_sign_in(); // Cancel: the job stops waiting for the browser
            }
            // Joined before the next dialog, so its dismiss can never close that one.
            let _ = worker.join();
            match done {
                Ok(Some(done)) => account.finish(done, unix_now()),
                _ => return,
            }
            if !account.signed_in() {
                return message(&account.message);
            }
            // The first license check, so the dialog can say the days left.
            for job in account.take_jobs() {
                if let Some(done) = run_account_job(job) {
                    account.finish(done, unix_now());
                }
            }
            account.take_hints(); // the dialog says it
            message(&text::signed_in(account.email(), account.access(unix_now())));
        }
        Access::Expired if account.required && dialog::ask(text::ENDED, &text::ENDED_BUTTONS) == Some(0) => {
            account.buy();
            for job in account.take_jobs() {
                if let Some(done) = run_account_job(job) {
                    account.finish(done, unix_now());
                }
            }
        }
        _ => {}
    }
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)
}

/// What the other threads send to this one.
enum Msg {
    Input(input::Event),
    /// The model loaded (None) or could not be fetched or loaded.
    Ready(Option<String>),
    Text(Result<String, String>),
    Meeting(meetings::Notice),
    Account(Done),
}

struct AppMic(Option<audio::Mic>);

impl flow::Mic for AppMic {
    fn start(&mut self) -> Result<(), String> {
        // Opened at launch; retried here if there was no mic then.
        if self.0.is_none() {
            self.0 = Some(audio::Mic::open(PRE_ROLL)?);
        }
        if let Some(mic) = &self.0 {
            mic.start();
        }
        Ok(())
    }
    fn stop(&mut self) -> Vec<f32> {
        self.0.as_ref().map(audio::Mic::stop).unwrap_or_default()
    }
}

struct AppStore(audio::Store);

impl flow::Store for AppStore {
    fn keep(&mut self, samples: &[f32], why: Kept) -> Result<(), String> {
        let kind = match why {
            Kept::Dictation => audio::Kind::Dictation,
            Kept::Cancelled => audio::Kind::Cancelled,
            Kept::TooShort => audio::Kind::TooShort,
        };
        self.0.save(now_ms(), kind, samples).map(drop).map_err(|e| format!("Could not keep the recording: {e}"))
    }
}

struct AppInsert(Option<insert::Focus>);

impl flow::Insert for AppInsert {
    fn remember_focus(&mut self) {
        self.0 = insert::foreground();
    }
    fn insert(&mut self, text: &str) -> Result<Option<String>, String> {
        match insert::insert(text, self.0.take()) {
            Ok(insert::Outcome::Pasted { .. }) => Ok(None),
            Ok(insert::Outcome::OnClipboard(hint)) => Ok(Some(hint.message().into())),
            Err(e) => Err(format!("Could not use the clipboard: {e}")),
        }
    }
}

impl flow::Show for input::Ui {
    fn mode(&mut self, mode: input::Mode) {
        self.set_mode(mode);
    }
    fn hint(&mut self, text: &str) {
        self.show_hint(text, HINT);
    }
}

/// Fetches the model if needed and loads it, then transcribes each clip it is sent.
fn spawn_stt(dir: PathBuf, model: &'static audio::model::Model, tx: Sender<Msg>) -> Sender<Vec<f32>> {
    let (clips, rx) = mpsc::channel::<Vec<f32>>();
    thread::spawn(move || {
        let mut whisper = audio::model::ensure(&dir, model).and_then(|path| audio::Whisper::load(&path));
        let _ = tx.send(Msg::Ready(whisper.as_ref().err().cloned()));
        for samples in rx {
            let text = match &mut whisper {
                Ok(w) => audio::transcribe(w, &samples).map_err(|e| match e {
                    audio::SttError::NoAudio => "The mic recorded only silence. Check that it is on and not muted.".into(),
                    audio::SttError::Engine(e) => e,
                }),
                Err(e) => Err(e.clone()),
            };
            if tx.send(Msg::Text(text)).is_err() {
                break;
            }
        }
    });
    clips
}

/// First run, and every run until it is done: the mic switches, then the model download (the one
/// network step, only on a yes). False if the user declined the model.
fn onboarding(models: &Path, model: &audio::model::Model) -> bool {
    if !mic_allowed()
        && ask("Windows is keeping desktop apps away from the microphone, so Shepetal can't hear you.\n\n\
                Open the microphone settings now? Turn on \"Microphone access\", \"Let apps access your microphone\" \
                and \"Let desktop apps access your microphone\".")
    {
        open(MIC_SETTINGS);
    }
    if models.join(model.file).is_file() {
        return true;
    }
    if ask(&system::download_question(model.bytes)) {
        return true;
    }
    message("Shepetal can't transcribe without the speech model, so it is closing. It asks again the next time it starts.");
    false
}

pub fn run() {
    if already_running() {
        message("Shepetal is already running. Its 🤫 is in the bottom-left corner, and its menu is in the tray.");
        return;
    }
    // Never a fallback dir: recordings must stay in the user's own profile (goal rule 4).
    let data = match audio::data_dir() {
        Ok(d) => d,
        Err(e) => return message(&format!("Shepetal can't start: {e}, so there is nowhere private to keep your recordings.")),
    };
    let store = match audio::Store::open(data.join("audio")) {
        Ok(s) => s,
        Err(e) => return message(&format!("Shepetal can't start: it could not create {}: {e}", data.join("audio").display())),
    };
    let model = audio::model::choose(&audio::model::detect());
    if !onboarding(&data.join("models"), model) {
        return;
    }
    let required = account::sign_in_required(env("SHEPETAL_REQUIRE_SIGNIN").as_deref(), cfg!(feature = "require-sign-in"));
    let tokens = CredTokens::new(env("SHEPETAL_CREDENTIAL_TARGET").as_deref());
    let mut account = Account::new(tokens, Some(data.join("account.json")), required);
    account_onboarding(&mut account);
    let (ui, events) = match input::spawn(input::Hotkey::parse(flow::HOTKEY).unwrap_or_default()) {
        Ok(x) => x,
        Err(e) => return message(&format!("Shepetal can't watch the keyboard or show its 🤫: {e}")),
    };
    ui.set_start_at_login(starts_at_login());

    let (tx, rx) = mpsc::channel();
    let forward = tx.clone();
    thread::spawn(move || events.into_iter().try_for_each(|e| forward.send(Msg::Input(e))));
    // A meeting records only after a click on the card's Record.
    let (record, clicks) = mpsc::channel();
    let card = Card::spawn(record);
    let meeting = tx.clone();
    thread::spawn(move || meetings::watch(meetings::Config::default(), clicks, move |n| drop(meeting.send(Msg::Meeting(n)))));
    let account_tx = tx.clone();
    let stt = spawn_stt(data.join("models"), model, tx);

    let mut flow = Flow::new(
        AppMic(audio::Mic::open(PRE_ROLL).ok()),
        AppStore(store),
        AppInsert(None),
        ui,
        flow::rules,
    );
    let mut gesture = Gesture::default();
    let t0 = Instant::now();
    let ms = |at: Instant| at.saturating_duration_since(t0).as_millis() as u64;
    let mut paused = false;
    let card = card.map_err(|e| flow.error(&format!("Shepetal can't offer to record meetings: {e}"), 0)).ok();
    account.start(unix_now());
    let mut account_tick = Instant::now();
    let mut account_menu = Vec::new();
    loop {
        let msg = rx.recv_timeout(Duration::from_millis(50));
        let now = ms(Instant::now());
        let actions = match msg {
            Ok(Msg::Input(input::Event::Key(key, at))) if !paused => flow::feed(&mut gesture, key, ms(at)),
            Ok(Msg::Input(input::Event::Key(..))) => vec![],
            Ok(Msg::Input(input::Event::Pause(p))) => {
                paused = p;
                gesture.reset();
                // A recording running when Pause is clicked ends as cancelled, and is kept.
                if p { vec![Action::Cancel] } else { vec![] }
            }
            Ok(Msg::Input(input::Event::Open)) => {
                open(&data.to_string_lossy());
                vec![]
            }
            Ok(Msg::Input(input::Event::StartAtLogin)) => {
                if let Err(e) = set_start_at_login(!starts_at_login()) {
                    flow.error(&e, now);
                }
                flow.show.set_start_at_login(starts_at_login());
                vec![]
            }
            Ok(Msg::Input(input::Event::Account(id))) => {
                if let Some(cmd) = Command::from_id(id) {
                    account.command(cmd, flow.busy());
                }
                vec![]
            }
            Ok(Msg::Account(done)) => {
                account.finish(done, unix_now());
                vec![]
            }
            // The tray, overlay and hook are already gone.
            Ok(Msg::Input(input::Event::Quit)) | Err(RecvTimeoutError::Disconnected) => break,
            Ok(Msg::Ready(err)) => {
                if let Some(e) = err {
                    flow.error(&e, now);
                }
                vec![]
            }
            Ok(Msg::Text(text)) => {
                flow.transcribed(text, now);
                vec![]
            }
            Ok(Msg::Meeting(notice)) => {
                match notice {
                    meetings::Notice::Event(e) => match (meeting::show(&e), &card) {
                        (Show::Offer(label), Some(card)) => card.offer(&label),
                        (Show::Withdraw, Some(card)) => card.hide(),
                        (Show::Hint(text), _) => flow.show.show_hint(text, HINT),
                        _ => {}
                    },
                    meetings::Notice::Saved(dir) => flow.show.show_hint(&format!("Meeting saved in {}", dir.display()), HINT),
                    meetings::Notice::Failed(e) => flow.error(&e, now),
                }
                vec![]
            }
            Err(RecvTimeoutError::Timeout) => vec![],
        };
        for action in actions.into_iter().chain(gesture.tick(now)) {
            // Signed out or after the trial, Ctrl+Win only shows why (when sign-in is required).
            if action == Action::Start && !flow.busy() && !account.allow_hotkey(unix_now()) {
                gesture.reset();
                continue;
            }
            if let Some(samples) = flow.action(action, now) {
                let _ = stt.send(samples);
            }
            // The mic did not open: end the gesture too, so its release stops nothing.
            if action == Action::Start && !flow.busy() {
                gesture.reset();
            }
        }
        flow.tick(now);
        if account_tick.elapsed() >= ACCOUNT_TICK {
            account_tick = Instant::now();
            account.tick(unix_now(), flow.busy());
        }
        spawn_account_jobs(&mut account, &account_tx);
        for hint in account.take_hints() {
            flow.show.show_hint(&hint, HINT);
        }
        let menu: Vec<input::MenuLine> =
            account.menu(unix_now()).into_iter().map(|(label, cmd)| input::MenuLine { label, id: cmd.map(Command::id) }).collect();
        if menu != account_menu {
            flow.show.set_account(menu.clone());
            account_menu = menu;
        }
    }
    flow.show.quit();
}
