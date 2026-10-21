//! Which speech model this PC runs, and fetching it on first use into `%LOCALAPPDATA%\Shepetal\models`.
//!
//! docs/models.md has no Windows row yet, and this crate runs whisper.cpp only, so the tiers
//! are its whisper.cpp rows: with an NVIDIA GPU, large-v3-turbo q5_0 on CUDA (the table's
//! Linux CUDA and Vulkan rows); otherwise base.en q5_1 on the CPU (the table's whisper.cpp
//! fallback, measured at 3.6 % WER with 308 MB peak RAM).
//! `shepetal-core::model` picks sherpa-onnx Parakeet tiers this crate cannot run yet; until it can,
//! these tiers are a stopgap (issue #117).

use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::{fs, io};

#[derive(Debug, Clone, PartialEq)]
pub struct Hardware {
    pub ram_gb: u64,
    /// This build has CUDA (the `cuda` feature) and the NVIDIA driver is installed.
    pub cuda: bool,
}

/// One ggml file, pinned to a commit of the publisher's repo and checked by SHA-256.
#[derive(Debug, PartialEq)]
pub struct Model {
    pub file: &'static str,
    pub url: &'static str,
    pub sha256: &'static str,
    pub bytes: u64,
}

pub const CPU: Model = Model {
    file: "ggml-base.en-q5_1.bin",
    url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.en-q5_1.bin",
    sha256: "4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f",
    bytes: 59_721_011,
};

pub const GPU: Model = Model {
    file: "ggml-large-v3-turbo-q5_0.bin",
    url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin",
    sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
    bytes: 574_041_195,
};

pub fn choose(hw: &Hardware) -> &'static Model {
    // A GPU only helps if there is RAM to load the model next to the desktop (as on Linux).
    if hw.cuda && hw.ram_gb >= 8 {
        &GPU
    } else {
        &CPU
    }
}

/// Read this PC's hardware.
pub fn detect() -> Hardware {
    Hardware { ram_gb: ram_gb(), cuda: cfg!(feature = "cuda") && nvidia_driver() }
}

#[cfg(windows)]
fn ram_gb() -> u64 {
    use windows_sys::Win32::System::SystemInformation::{GlobalMemoryStatusEx, MEMORYSTATUSEX};
    let mut m = MEMORYSTATUSEX { dwLength: std::mem::size_of::<MEMORYSTATUSEX>() as u32, ..Default::default() };
    // Total physical memory is a bit under the installed size, so round up.
    if unsafe { GlobalMemoryStatusEx(&mut m) } == 0 {
        0
    } else {
        m.ullTotalPhys.div_ceil(1 << 30)
    }
}

#[cfg(not(windows))]
fn ram_gb() -> u64 {
    0
}

/// The NVIDIA driver installs nvcuda.dll into System32.
fn nvidia_driver() -> bool {
    std::env::var_os("SystemRoot").is_some_and(|r| Path::new(&r).join("System32").join("nvcuda.dll").exists())
}

/// The path of `m` in `dir`, downloading it first if it is missing. A download only replaces
/// the final name after its SHA-256 matches, so a cut or altered file is never loaded. While it
/// downloads, `progress` gets the percent done about every half second (see `percent`).
pub fn ensure(dir: &Path, m: &Model, mut progress: impl FnMut(u8)) -> Result<PathBuf, String> {
    let path = dir.join(m.file);
    if path.is_file() {
        return Ok(path);
    }
    fs::create_dir_all(dir).map_err(|e| format!("Could not create the models folder: {e}"))?;
    let part = dir.join(format!("{}.part", m.file));
    let fetched = curl().args(["-fsL", "--retry", "3", "-o"]).arg(&part).arg(m.url).spawn().and_then(|mut child| loop {
        if let Some(status) = child.try_wait()? {
            break Ok(status);
        }
        progress(percent(fs::metadata(&part).map_or(0, |md| md.len()), m.bytes));
        std::thread::sleep(std::time::Duration::from_millis(500));
    });
    let result = match fetched {
        Err(e) => Err(format!("Could not start the download: {e}")),
        Ok(s) if !s.success() => Err(format!("The speech model download failed ({s}). Check the connection and try again.")),
        Ok(_) => match sha256(&part) {
            Ok(h) if h == m.sha256 => fs::rename(&part, &path).map_err(|e| format!("Could not save the speech model: {e}")),
            Ok(_) => Err("The downloaded speech model is damaged. Try again.".into()),
            Err(e) => Err(format!("Could not read the downloaded speech model: {e}")),
        },
    };
    let _ = fs::remove_file(&part);
    result.map(|()| path)
}

/// How much of a download of `total` bytes is done, 0 to 99: 100 would claim the file is
/// checked and in place before it is.
pub fn percent(done: u64, total: u64) -> u8 {
    (done.saturating_mul(100) / total.max(1)).min(99) as u8
}

/// Windows 10 1803 and later ship curl.exe in System32. Absolute, so PATH cannot swap it, and
/// without a console window flashing up from the GUI app.
fn curl() -> Command {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let root = std::env::var_os("SystemRoot").unwrap_or_else(|| r"C:\Windows".into());
        let mut c = Command::new(Path::new(&root).join("System32").join("curl.exe"));
        c.creation_flags(windows_sys::Win32::System::Threading::CREATE_NO_WINDOW);
        c
    }
    #[cfg(not(windows))]
    Command::new("curl")
}

fn sha256(path: &Path) -> io::Result<String> {
    let mut h = Sha256::new();
    io::copy(&mut fs::File::open(path)?, &mut h)?;
    Ok(h.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nvidia_gpu_runs_turbo_and_cpu_runs_base_en() {
        assert_eq!(choose(&Hardware { ram_gb: 16, cuda: true }).file, "ggml-large-v3-turbo-q5_0.bin");
        assert_eq!(choose(&Hardware { ram_gb: 8, cuda: true }).file, "ggml-large-v3-turbo-q5_0.bin");
        for hw in [Hardware { ram_gb: 7, cuda: true }, Hardware { ram_gb: 64, cuda: false }, Hardware { ram_gb: 0, cuda: false }] {
            assert_eq!(choose(&hw).file, "ggml-base.en-q5_1.bin", "{hw:?}");
        }
    }

    #[test]
    fn a_cpu_build_never_picks_the_gpu_model() {
        if !cfg!(feature = "cuda") {
            assert!(!detect().cuda);
        }
    }

    #[test]
    fn urls_are_pinned_https_to_the_file_they_name() {
        for m in [&CPU, &GPU] {
            assert!(m.url.starts_with("https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c"), "{}", m.url);
            assert!(m.url.ends_with(&format!("/{}", m.file)));
            assert_eq!(m.sha256.len(), 64);
        }
    }

    fn fixture(name: &str, body: &[u8]) -> (PathBuf, Model) {
        let d = std::env::temp_dir().join(format!("shepetal-model-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        let src = d.join("published.bin");
        fs::write(&src, body).unwrap();
        let url: &'static str = Box::leak(format!("file://{}", src.display()).into_boxed_str());
        let hash: &'static str = Box::leak(sha256(&src).unwrap().into_boxed_str());
        (d.join("models"), Model { file: "m.bin", url, sha256: hash, bytes: body.len() as u64 })
    }

    #[test]
    fn progress_counts_up_and_never_says_100_before_the_check() {
        assert_eq!(percent(0, GPU.bytes), 0);
        assert_eq!(percent(GPU.bytes / 2, GPU.bytes), 49, "574 MB, half: 49, rounded down");
        assert_eq!(percent(GPU.bytes - 1, GPU.bytes), 99);
        assert_eq!(percent(GPU.bytes, GPU.bytes), 99, "done is said once the hash matched");
        assert_eq!(percent(2 * GPU.bytes, GPU.bytes), 99, "a server sending more");
        assert_eq!(percent(5, 0), 99, "no division by zero");
    }

    #[test]
    fn first_use_downloads_and_verifies() {
        let (dir, m) = fixture("ok", b"weights");
        let mut seen = Vec::new();
        let p = ensure(&dir, &m, |pct| seen.push(pct)).unwrap();
        assert!(seen.windows(2).all(|w| w[0] <= w[1]) && seen.iter().all(|&p| p <= 99), "{seen:?}");
        assert_eq!((p.clone(), fs::read(&p).unwrap()), (dir.join("m.bin"), b"weights".to_vec()));
        assert!(!dir.join("m.bin.part").exists());
    }

    #[test]
    fn a_damaged_download_is_never_put_in_place() {
        let (dir, m) = fixture("bad", b"weights");
        let m = Model { sha256: "0000000000000000000000000000000000000000000000000000000000000000", ..m };
        let err = ensure(&dir, &m, |_| {}).unwrap_err();
        assert!(err.contains("damaged"), "{err}");
        assert!(!dir.join("m.bin").exists() && !dir.join("m.bin.part").exists());
    }

    #[test]
    fn a_failed_download_leaves_nothing() {
        let (dir, m) = fixture("gone", b"weights");
        let m = Model { url: "file:///nonexistent/shepetal/m.bin", ..m };
        assert!(ensure(&dir, &m, |_| {}).unwrap_err().contains("download failed"));
        assert!(!dir.join("m.bin").exists() && !dir.join("m.bin.part").exists());
    }

    #[test]
    fn a_model_on_disk_is_used_without_any_download() {
        let (dir, m) = fixture("there", b"weights");
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("m.bin"), b"local").unwrap();
        let m = Model { url: "file:///nonexistent/shepetal/m.bin", ..m };
        assert_eq!(fs::read(ensure(&dir, &m, |_| {}).unwrap()).unwrap(), b"local");
    }

    #[test]
    fn user_facing_errors_never_name_a_model() {
        let (dir, m) = fixture("names", b"weights");
        for m in [Model { url: "file:///nonexistent/x", ..m }, Model { sha256: "00", url: m.url, file: m.file, bytes: 0 }] {
            let err = ensure(&dir, &m, |_| {}).unwrap_err().to_lowercase();
            for name in ["whisper", "ggml", "turbo", "base.en", "m.bin"] {
                assert!(!err.contains(name), "{err}");
            }
        }
    }
}
