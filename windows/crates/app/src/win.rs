//! The Windows side of shepetal.exe: single instance, first-run onboarding (mic privacy and the
//! model download), start at login, and the wiring of the sibling crates. Threads: input runs
//! the hook, the 🤫 overlay and the tray on its own thread; this one runs the gesture and
//! `flow::Flow`; one more loads the model and transcribes; meetings poll on another.

use crate::dialog::{self, Card};
use crate::flow::{self, Flow, Kept};
use crate::meeting::{self, Show};
use crate::system::{self, HOTKEY_VALUE, MIC_CONSENT, MIC_CONSENT_DESKTOP, MIC_SETTINGS, MUTEX, RETENTION_VALUE, RUN_KEY, RUN_VALUE, SETTINGS_KEY};
use shepetal_core::gesture::{Action, Gesture, HINT_MS};
use shepetal_core::retention::Retention;
use std::path::{Path, PathBuf};
use std::ptr::{null, null_mut};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use windows_sys::Win32::Foundation::{GetLastError, ERROR_ALREADY_EXISTS, ERROR_FILE_NOT_FOUND, ERROR_SUCCESS};
use windows_sys::Win32::System::Registry::{
    RegDeleteKeyValueW, RegGetValueW, RegSetKeyValueW, HKEY, HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, REG_SZ, RRF_RT_REG_SZ,
};
use windows_sys::Win32::System::Threading::{CreateMutexW, OpenMutexW, SYNCHRONIZATION_SYNCHRONIZE};
use windows_sys::Win32::UI::Shell::ShellExecuteW;
use windows_sys::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;

/// Audio kept from just before the hotkey went down, so the first syllable is never cut.
const PRE_ROLL: Duration = Duration::from_millis(300);
const HINT: Duration = Duration::from_millis(HINT_MS);

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain([0]).collect()
}

/// Takes the named mutex. The handle stays open until the process exits, which frees the name.
fn already_running() -> bool {
    let name = wide(MUTEX);
    let h = unsafe { CreateMutexW(null(), 0, name.as_ptr()) };
    let existed = unsafe { GetLastError() } == ERROR_ALREADY_EXISTS;
    system::already_running(!h.is_null(), existed, || {
        let other = unsafe { OpenMutexW(SYNCHRONIZATION_SYNCHRONIZE, 0, name.as_ptr()) };
        // Left open like ours: the process is about to exit anyway.
        !other.is_null()
    })
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

/// Writes a REG_SZ under HKCU, creating the key if needed.
fn set_reg_string(key: &str, value: &str, data: &str) -> u32 {
    let (key, name, data) = (wide(key), wide(value), wide(data));
    unsafe { RegSetKeyValueW(HKEY_CURRENT_USER, key.as_ptr(), name.as_ptr(), REG_SZ, data.as_ptr().cast(), (data.len() * 2) as u32) }
}

fn set_start_at_login(on: bool) -> Result<(), String> {
    let r = if on {
        let exe = std::env::current_exe().map_err(|e| e.to_string())?;
        set_reg_string(RUN_KEY, RUN_VALUE, &system::run_command(&exe))
    } else {
        let (key, name) = (wide(RUN_KEY), wide(RUN_VALUE));
        unsafe { RegDeleteKeyValueW(HKEY_CURRENT_USER, key.as_ptr(), name.as_ptr()) }
    };
    match r {
        ERROR_SUCCESS => Ok(()),
        ERROR_FILE_NOT_FOUND if !on => Ok(()),
        r => Err(format!("Could not change start at login (error {r}).")),
    }
}

fn retention() -> Retention {
    system::retention(reg_string(HKEY_CURRENT_USER, SETTINGS_KEY, RETENTION_VALUE).as_deref())
}

fn set_retention(r: Retention) -> Result<(), String> {
    match set_reg_string(SETTINGS_KEY, RETENTION_VALUE, r.as_str()) {
        ERROR_SUCCESS => Ok(()),
        e => Err(format!("Could not save the Recordings setting (error {e}).")),
    }
}

fn hotkey() -> String {
    system::hotkey(reg_string(HKEY_CURRENT_USER, SETTINGS_KEY, HOTKEY_VALUE).as_deref())
}

fn set_hotkey(name: &str) -> Result<(), String> {
    match set_reg_string(SETTINGS_KEY, HOTKEY_VALUE, name) {
        ERROR_SUCCESS => Ok(()),
        e => Err(format!("Could not save the hotkey (error {e}).")),
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

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)
}

/// What the other threads send to this one.
enum Msg {
    Input(input::Event),
    /// How far the first-run model download is, in percent.
    Progress(u8),
    /// The model loaded (None) or could not be fetched or loaded.
    Ready(Option<String>),
    Text(Result<String, String>),
    Meeting(meetings::Notice),
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

/// The store, and the stamp of the last dictation clip, which its transcript is saved under.
struct AppStore(audio::Store, Option<u64>);

impl flow::Store for AppStore {
    fn keep(&mut self, samples: &[f32], why: Kept) -> Result<(), String> {
        let kind = match why {
            Kept::Dictation => audio::Kind::Dictation,
            Kept::Cancelled => audio::Kind::Cancelled,
            Kept::TooShort => audio::Kind::TooShort,
        };
        let stamp = now_ms();
        self.1 = (why == Kept::Dictation).then_some(stamp);
        self.0.save(stamp, kind, samples).map(drop).map_err(|e| format!("Could not keep the recording: {e}"))
    }
    fn transcript(&mut self, text: &str) -> Result<(), String> {
        // Under the clip's stamp; one that failed to save still gets its text in the history.
        let stamp = self.1.take().unwrap_or_else(now_ms);
        self.0.save_transcript(stamp, text).map(drop).map_err(|e| format!("Could not save the text in the history: {e}"))
    }
}

/// The newest transcripts for the tray's Recent submenu. An unreadable folder lists nothing.
fn recent(store: &audio::Store) -> Vec<String> {
    store.recent(input::RECENT).unwrap_or_default().into_iter().map(|(_, text)| text).collect()
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
        let progress = tx.clone();
        let mut whisper = audio::model::ensure(&dir, model, |p| drop(progress.send(Msg::Progress(p))))
            .and_then(|path| audio::Whisper::load(&path));
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
    let hotkey = hotkey();
    let (ui, events) = match input::spawn(&hotkey) {
        Ok(x) => x,
        Err(e) => return message(&format!("Shepetal can't watch the keyboard or show its 🤫: {e}")),
    };
    ui.set_start_at_login(starts_at_login());
    let mut retention = retention();
    ui.set_delete_after_24h(retention == Retention::Delete24h);
    let mut history = recent(&store);
    ui.set_recent(history.clone());

    let (tx, rx) = mpsc::channel();
    let forward = tx.clone();
    thread::spawn(move || events.into_iter().try_for_each(|e| forward.send(Msg::Input(e))));
    // A meeting records only after a click on the card's Record.
    let (record, clicks) = mpsc::channel();
    let card = Card::spawn(record);
    let meeting = tx.clone();
    thread::spawn(move || meetings::watch(meetings::Config::default(), clicks, move |n| drop(meeting.send(Msg::Meeting(n)))));
    let stt = spawn_stt(data.join("models"), model, tx);

    let mut flow = Flow::new(
        AppMic(audio::Mic::open(PRE_ROLL).ok()),
        AppStore(store.clone(), None),
        AppInsert(None),
        ui,
        flow::rules,
    );
    flow.hotkey = hotkey;
    let mut gesture = Gesture::default();
    let t0 = Instant::now();
    let ms = |at: Instant| at.saturating_duration_since(t0).as_millis() as u64;
    let mut paused = false;
    // Goal rule 4: with delete after 24 h, clips go at launch and within a minute of turning 24 h old.
    let mut prune = system::Prune::default();
    let mut prune_failed = false;
    let card = card.map_err(|e| flow.error(&format!("Shepetal can't offer to record meetings: {e}"), 0)).ok();
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
            Ok(Msg::Input(input::Event::DeleteAfter24h(on))) => {
                if let Err(e) = set_retention(if on { Retention::Delete24h } else { Retention::Keep }) {
                    flow.error(&e, now);
                }
                retention = self::retention(); // the check mark shows what was saved
                flow.show.set_delete_after_24h(retention == Retention::Delete24h);
                prune.now();
                vec![]
            }
            // The tray, overlay and hook are already gone.
            Ok(Msg::Input(input::Event::Quit)) | Err(RecvTimeoutError::Disconnected) => break,
            Ok(Msg::Progress(p)) => {
                flow.downloading = Some(p);
                vec![]
            }
            Ok(Msg::Ready(err)) => {
                let downloaded = flow.downloading.take().is_some();
                match err {
                    Some(e) => flow.error(&e, now),
                    None if downloaded => flow.show.show_hint(&system::ready_hint(&flow.hotkey), HINT),
                    None => {}
                }
                vec![]
            }
            Ok(Msg::Text(text)) => {
                flow.transcribed(text, now);
                history = recent(&store);
                flow.show.set_recent(history.clone());
                vec![]
            }
            Ok(Msg::Input(input::Event::Hotkey(n))) => {
                let name = input::HOTKEYS[n];
                match set_hotkey(name).and_then(|()| flow.show.set_hotkey(name)) {
                    Ok(()) => {
                        flow.hotkey = name.into();
                        flow.show.show_hint(&format!("Hold {name} to talk"), HINT);
                    }
                    Err(e) => flow.error(&e, now),
                }
                vec![]
            }
            Ok(Msg::Input(input::Event::CopyRecent(n))) => {
                if let Some(text) = history.get(n) {
                    match insert::copy(text) {
                        Ok(()) => flow.show.show_hint("Copied. Press Ctrl+V to paste it.", HINT),
                        Err(e) => flow.error(&format!("Could not use the clipboard: {e}"), now),
                    }
                }
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
            if let Some(samples) = flow.action(action, now) {
                let _ = stt.send(samples);
            }
            // The mic did not open, or the model is still downloading: end the gesture too, so its
            // release stops nothing.
            if action == Action::Start && !flow.busy() {
                gesture.reset();
            }
        }
        flow.tick(now);
        if retention == Retention::Delete24h && prune.due(now) {
            match store.prune(retention, now_ms()) {
                Ok(_) => prune_failed = false,
                // Once, not every minute while it keeps failing.
                Err(e) if !prune_failed => {
                    prune_failed = true;
                    flow.error(&format!("Could not delete recordings older than 24 hours: {e}"), now);
                }
                Err(_) => {}
            }
        }
    }
    flow.show.quit();
}
