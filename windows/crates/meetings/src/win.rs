//! Win32 side: who holds the mic (WASAPI audio sessions), window titles, the polling loop, and
//! the capture of the mic (Me.wav) plus the default render device's loopback (Others.wav).

use crate::wav::{Wav, RATE};
use crate::{gap_frames, owner_only_sddl, Config, Detector, Event, MicClient, Snapshot, Window};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};
use windows::core::{Interface, BOOL, HSTRING, PWSTR};
use windows::Win32::Foundation::{CloseHandle, LocalFree, HANDLE, HLOCAL, HWND, LPARAM};
use windows::Win32::Media::Audio::*;
use windows::Win32::Security::Authorization::{
    ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1,
};
use windows::Win32::Security::{
    GetTokenInformation, TokenUser, PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES, TOKEN_QUERY,
    TOKEN_USER,
};
use windows::Win32::Storage::FileSystem::CreateDirectoryW;
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoTaskMemFree, CLSCTX_ALL, COINIT_MULTITHREADED,
};
use windows::Win32::System::Performance::{QueryPerformanceCounter, QueryPerformanceFrequency};
use windows::Win32::System::SystemInformation::GetLocalTime;
use windows::Win32::System::Threading::{
    GetCurrentProcess, OpenProcess, OpenProcessToken, QueryFullProcessImageNameW,
    PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetForegroundWindow, GetWindowTextW, GetWindowThreadProcessId, IsWindowVisible,
};

/// What [`watch`] reports.
#[derive(Debug)]
pub enum Notice {
    /// A detector event. Show "Record?" on `OfferRecording` and hide it on `WithdrawOffer`;
    /// `StartRecording` is reported once the recording really runs.
    Event(Event),
    /// The recording stopped; Me.wav and Others.wav are in this dir.
    Saved(PathBuf),
    Failed(String),
}

/// Polls once a second forever: detects meetings, offers "Record?", and once the user clicks
/// it (a `()` on `record`) records the meeting into
/// `%LOCALAPPDATA%\Shepetal\meetings\<yyyyMMdd-HHmmss>\`. Run it on its own thread.
pub fn watch(cfg: Config, record: mpsc::Receiver<()>, mut on: impl FnMut(Notice)) -> ! {
    // An STA thread returns RPC_E_CHANGED_MODE here; these APIs work there too.
    let _ = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
    let mut detector = Detector::new(cfg);
    let t0 = Instant::now();
    let mut recording: Option<Recording> = None;
    let mut probe_ok = true;
    loop {
        let tick = Instant::now() + Duration::from_secs(1);
        match snapshot() {
            // Keep the last state; report once, not every second.
            Err(e) => {
                if probe_ok {
                    on(Notice::Failed(format!("meeting probe failed: {e}")));
                }
                probe_ok = false;
            }
            Ok(s) => {
                probe_ok = true;
                let events = detector.update(&s, t0.elapsed().as_secs_f64());
                handle(events, &mut recording, &mut on);
            }
        }
        // Wait out the second; a click on "Record?" starts the recording at once.
        loop {
            match record.recv_timeout(tick.saturating_duration_since(Instant::now())) {
                Ok(()) => handle(detector.accept(), &mut recording, &mut on),
                Err(mpsc::RecvTimeoutError::Timeout) => break,
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    thread::sleep(tick.saturating_duration_since(Instant::now()));
                    break;
                }
            }
        }
    }
}

/// Starts and stops the recording on the detector's word and reports everything else.
fn handle(events: Vec<Event>, recording: &mut Option<Recording>, on: &mut impl FnMut(Notice)) {
    for event in events {
        match event {
            Event::StartRecording => match Recording::start() {
                Ok(r) => {
                    *recording = Some(r);
                    on(Notice::Event(event));
                }
                Err(e) => on(Notice::Failed(format!(
                    "meeting recording did not start: {e}"
                ))),
            },
            Event::StopRecording => {
                if let Some(r) = recording.take() {
                    let dir = r.dir.clone();
                    match r.stop() {
                        Ok(()) => on(Notice::Saved(dir)),
                        Err(e) => on(Notice::Failed(format!(
                            "meeting recording in {} failed: {e}",
                            dir.display()
                        ))),
                    }
                }
            }
            _ => on(Notice::Event(event)),
        }
    }
}

/// One observation: active sessions on every active capture device, visible window titles,
/// the foreground window and the default device IDs. COM must be initialised on this thread.
pub fn snapshot() -> windows::core::Result<Snapshot> {
    unsafe {
        let en: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)?;
        let mut mic = vec![];
        // Every active mic, not only the default: a call app may use its own device.
        let devices = en.EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE)?;
        for i in 0..devices.GetCount()? {
            let manager: IAudioSessionManager2 = devices.Item(i)?.Activate(CLSCTX_ALL, None)?;
            let sessions = manager.GetSessionEnumerator()?;
            for j in 0..sessions.GetCount()? {
                let session = sessions.GetSession(j)?;
                if session.GetState()? != AudioSessionStateActive {
                    continue;
                }
                let pid = session.cast::<IAudioSessionControl2>()?.GetProcessId()?;
                if pid != 0 {
                    mic.push(MicClient {
                        exe: exe_name(pid),
                        pid,
                    });
                }
            }
        }
        let mut windows: Vec<Window> = vec![];
        EnumWindows(
            Some(collect_window),
            LPARAM(&mut windows as *mut Vec<Window> as isize),
        )?;
        let foreground = window(GetForegroundWindow());
        let devices = [eCapture, eRender]
            .map(|flow| default_device_id(&en, flow))
            .to_vec();
        Ok(Snapshot {
            mic,
            windows,
            foreground,
            devices,
        })
    }
}

unsafe fn default_device_id(en: &IMMDeviceEnumerator, flow: EDataFlow) -> String {
    let Ok(id) = en
        .GetDefaultAudioEndpoint(flow, eConsole)
        .and_then(|d| d.GetId())
    else {
        return String::new(); // no such device
    };
    let s = id.to_string().unwrap_or_default();
    CoTaskMemFree(Some(id.0 as _));
    s
}

/// Lowercase file name of a process's executable, or "" when it cannot be read.
fn exe_name(pid: u32) -> String {
    unsafe {
        let Ok(process) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else {
            return String::new();
        };
        let mut buf = [0u16; 1024];
        let mut len = buf.len() as u32;
        let read = QueryFullProcessImageNameW(
            process,
            PROCESS_NAME_WIN32,
            PWSTR(buf.as_mut_ptr()),
            &mut len,
        );
        let _ = CloseHandle(process);
        if read.is_err() {
            return String::new();
        }
        let path = String::from_utf16_lossy(&buf[..len as usize]);
        path.rsplit('\\').next().unwrap_or_default().to_lowercase()
    }
}

unsafe extern "system" fn collect_window(hwnd: HWND, out: LPARAM) -> BOOL {
    if IsWindowVisible(hwnd).as_bool() {
        if let Some(w) = window(hwnd) {
            (*(out.0 as *mut Vec<Window>)).push(w);
        }
    }
    true.into()
}

unsafe fn window(hwnd: HWND) -> Option<Window> {
    let mut buf = [0u16; 512];
    let len = GetWindowTextW(hwnd, &mut buf);
    if hwnd.is_invalid() || len <= 0 {
        return None;
    }
    let mut pid = 0;
    GetWindowThreadProcessId(hwnd, Some(&mut pid));
    Some(Window {
        exe: exe_name(pid),
        title: String::from_utf16_lossy(&buf[..len as usize]),
    })
}

/// A running meeting recording: two capture threads writing Me.wav and Others.wav.
pub struct Recording {
    pub dir: PathBuf,
    stop: Arc<AtomicBool>,
    threads: Vec<JoinHandle<io::Result<()>>>,
}

impl Recording {
    /// Opens the default mic and the default render device's loopback, converted to 16 kHz
    /// mono 16-bit, in a new owner-only dir. Both must open, or nothing records.
    pub fn start() -> io::Result<Recording> {
        let dir = new_meeting_dir()?;
        let stop = Arc::new(AtomicBool::new(false));
        let t0 = qpc_100ns(); // shared clock: both files start at the same moment
        let (ready, opened) = mpsc::channel();
        let threads = [(eCapture, "Me.wav"), (eRender, "Others.wav")]
            .into_iter()
            .map(|(flow, name)| {
                let (path, stop, ready) = (dir.join(name), stop.clone(), ready.clone());
                thread::spawn(move || capture(flow, &path, t0, &stop, ready))
            })
            .collect();
        drop(ready);
        let recording = Recording { dir, stop, threads };
        for _ in 0..2 {
            let result = opened
                .recv()
                .unwrap_or_else(|_| Err(io::Error::other("capture thread died")));
            if let Err(e) = result {
                let _ = recording.stop();
                return Err(e);
            }
        }
        Ok(recording)
    }

    /// Stops both streams and finishes the files. Returns the first capture error.
    pub fn stop(self) -> io::Result<()> {
        self.stop.store(true, Ordering::Relaxed);
        let mut first = Ok(());
        for t in self.threads {
            let r = t
                .join()
                .unwrap_or_else(|_| Err(io::Error::other("capture thread panicked")));
            if first.is_ok() {
                first = r;
            }
        }
        first
    }
}

const FORMAT: WAVEFORMATEX = WAVEFORMATEX {
    wFormatTag: WAVE_FORMAT_PCM as u16,
    nChannels: 1,
    nSamplesPerSec: RATE,
    nAvgBytesPerSec: RATE * 2,
    nBlockAlign: 2,
    wBitsPerSample: 16,
    cbSize: 0,
};

/// One stream into one WAV. Reports on `ready` once it runs (or why it could not open), then
/// polls every 50 ms until `stop`, padding gaps so the file follows the shared clock `t0`.
fn capture(
    flow: EDataFlow,
    path: &Path,
    t0: u64,
    stop: &AtomicBool,
    ready: mpsc::Sender<io::Result<()>>,
) -> io::Result<()> {
    let open = || -> io::Result<_> {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            let en: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)?;
            let client: IAudioClient = en
                .GetDefaultAudioEndpoint(flow, eConsole)?
                .Activate(CLSCTX_ALL, None)?;
            let loopback = if flow == eRender {
                AUDCLNT_STREAMFLAGS_LOOPBACK
            } else {
                0
            };
            let flags = AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM
                | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY
                | loopback;
            client.Initialize(
                AUDCLNT_SHAREMODE_SHARED,
                flags,
                10_000_000,
                0,
                &FORMAT,
                None,
            )?;
            let reader: IAudioCaptureClient = client.GetService()?;
            let wav = Wav::create(path)?;
            client.Start()?;
            Ok((client, reader, wav))
        }
    };
    let (client, reader, mut wav) = match open() {
        Ok(opened) => {
            let _ = ready.send(Ok(()));
            opened
        }
        Err(e) => {
            let _ = ready.send(Err(e));
            return Ok(()); // already reported to `start`
        }
    };
    let mut run = || -> io::Result<()> {
        // ponytail: a device unplugged mid-meeting ends this stream with an error at stop;
        // reopen on the new default device if that turns out to matter.
        while !stop.load(Ordering::Relaxed) {
            thread::sleep(Duration::from_millis(50));
            unsafe {
                while reader.GetNextPacketSize()? > 0 {
                    let (mut data, mut frames, mut flags, mut qpc) =
                        (std::ptr::null_mut(), 0u32, 0u32, 0u64);
                    reader.GetBuffer(&mut data, &mut frames, &mut flags, None, Some(&mut qpc))?;
                    wav.silence(gap_frames(wav.frames(), qpc.saturating_sub(t0)))?;
                    if flags & AUDCLNT_BUFFERFLAGS_SILENT.0 as u32 != 0 {
                        wav.silence(frames as u64)?;
                    } else {
                        wav.write(std::slice::from_raw_parts(data, frames as usize * 2))?;
                    }
                    reader.ReleaseBuffer(frames)?;
                }
            }
            wav.sync()?;
        }
        // End both files at the stop time, even if the loopback went quiet long before.
        wav.silence(gap_frames(wav.frames(), qpc_100ns().saturating_sub(t0)))?;
        wav.sync()
    };
    let result = run();
    unsafe {
        let _ = client.Stop();
    }
    result
}

/// The performance counter in 100 ns units, the clock WASAPI stamps packets with.
fn qpc_100ns() -> u64 {
    let (mut count, mut freq) = (0i64, 1i64);
    unsafe {
        let _ = QueryPerformanceCounter(&mut count);
        let _ = QueryPerformanceFrequency(&mut freq);
    }
    (count as u128 * 10_000_000 / freq.max(1) as u128) as u64
}

/// `%LOCALAPPDATA%\Shepetal\meetings\<yyyyMMdd-HHmmss>`, created new and owner-only.
fn new_meeting_dir() -> io::Result<PathBuf> {
    let base = std::env::var_os("LOCALAPPDATA")
        .ok_or_else(|| io::Error::other("LOCALAPPDATA is not set"))?;
    let parent = Path::new(&base).join("Shepetal").join("meetings");
    std::fs::create_dir_all(&parent)?;
    let t = unsafe { GetLocalTime() };
    let dir = parent.join(format!(
        "{:04}{:02}{:02}-{:02}{:02}{:02}",
        t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond
    ));
    create_owner_only_dir(&dir)?;
    Ok(dir)
}

/// Creates `dir` (failing if it exists) with a DACL that grants only the current user.
fn create_owner_only_dir(dir: &Path) -> io::Result<()> {
    unsafe {
        let mut token = HANDLE::default();
        OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token)?;
        let mut len = 0;
        let _ = GetTokenInformation(token, TokenUser, None, 0, &mut len); // sizes the buffer
        let mut buf = vec![0u64; (len as usize).div_ceil(8)]; // u64: TOKEN_USER is pointer-aligned
        let got = GetTokenInformation(
            token,
            TokenUser,
            Some(buf.as_mut_ptr().cast()),
            len,
            &mut len,
        );
        let _ = CloseHandle(token);
        got?;
        let user = &*(buf.as_ptr() as *const TOKEN_USER);
        let mut sid = PWSTR::null();
        ConvertSidToStringSidW(user.User.Sid, &mut sid)?;
        let sddl = owner_only_sddl(&sid.to_string().unwrap_or_default());
        LocalFree(Some(HLOCAL(sid.0.cast())));

        let mut sd = PSECURITY_DESCRIPTOR::default();
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            &HSTRING::from(sddl),
            SDDL_REVISION_1,
            &mut sd,
            None,
        )?;
        let attrs = SECURITY_ATTRIBUTES {
            nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: sd.0,
            bInheritHandle: false.into(),
        };
        let made = CreateDirectoryW(&HSTRING::from(dir.as_os_str()), Some(&attrs));
        LocalFree(Some(HLOCAL(sd.0)));
        Ok(made?)
    }
}
