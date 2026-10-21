//! Goal rule 4: the raw audio of every recording is kept, owner-only, as a 16 kHz mono WAV.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

/// Why a clip ended. Cancelled and too-short clips are kept too, flagged in the file name.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// `<stamp>.wav`
    Dictation,
    /// `<stamp>.cancelled.wav`
    Cancelled,
    /// `<stamp>.tooshort.wav`
    TooShort,
}

/// How long clips stay: keep (the default) or delete after 24 h. There is no "never store".
pub use shepetal_core::retention::Retention;

const DAY_MS: u64 = 24 * 60 * 60 * 1000;

/// `%LOCALAPPDATA%\Shepetal`. Audio goes in its `audio` folder, models in `models`.
pub fn data_dir() -> io::Result<PathBuf> {
    data_dir_from(std::env::var_os("LOCALAPPDATA").map(PathBuf::from))
}

/// A relative or empty LOCALAPPDATA is refused, so audio never lands under the working directory.
fn data_dir_from(local_app_data: Option<PathBuf>) -> io::Result<PathBuf> {
    match local_app_data {
        Some(d) if d.is_absolute() => Ok(d.join("Shepetal")),
        _ => Err(io::Error::other("LOCALAPPDATA is not set to an absolute folder")),
    }
}

/// The folder of kept clips.
#[derive(Clone)]
pub struct Store {
    dir: PathBuf,
}

impl Store {
    /// Open (or create) `dir` as an owner-only folder: on Windows a protected DACL with one
    /// full-control entry for the current user, inherited by every file in it; on Unix 0700.
    pub fn open(dir: impl Into<PathBuf>) -> io::Result<Store> {
        let dir = dir.into();
        create_owner_only(&dir)?;
        Ok(Store { dir })
    }

    /// Keep `samples` (16 kHz mono) as `<stamp_ms>[.<flag>].wav`, where `stamp_ms` is the Unix
    /// time in milliseconds the clip started (`prune` ages clips by it). A stamp is never reused:
    /// an existing file is an error, not overwritten.
    pub fn save(&self, stamp_ms: u64, kind: Kind, samples: &[f32]) -> io::Result<PathBuf> {
        let flag = match kind {
            Kind::Dictation => "",
            Kind::Cancelled => ".cancelled",
            Kind::TooShort => ".tooshort",
        };
        let path = self.dir.join(format!("{stamp_ms}{flag}.wav"));
        let mut opts = fs::OpenOptions::new();
        opts.write(true).create_new(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut opts, 0o600);
        let file = opts.open(&path)?;
        crate::wav::write(file, samples, crate::RATE)?;
        Ok(path)
    }

    /// Apply `retention` at `now_ms`: with `Delete24h`, remove the clips that are 24 hours old
    /// or older and return how many. Files this store did not write are left alone.
    pub fn prune(&self, retention: Retention, now_ms: u64) -> io::Result<usize> {
        if retention == Retention::Keep {
            return Ok(0);
        }
        let mut removed = 0;
        for entry in fs::read_dir(&self.dir)? {
            let entry = entry?;
            let stamp = entry.file_name().to_str().and_then(clip_stamp);
            if stamp.is_some_and(|s| now_ms.saturating_sub(s) >= DAY_MS) {
                fs::remove_file(entry.path())?;
                removed += 1;
            }
        }
        Ok(removed)
    }
}

/// The stamp of a file name `save` writes, or None for any other file.
fn clip_stamp(name: &str) -> Option<u64> {
    let base = name.strip_suffix(".wav")?;
    let digits = |s: &&str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
    ["", ".cancelled", ".tooshort"].iter().find_map(|f| base.strip_suffix(f).filter(digits))?.parse().ok()
}

#[cfg(unix)]
fn create_owner_only(dir: &Path) -> io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    // An existing folder others can read is refused, not used as is (same rule as on Linux).
    let md = fs::symlink_metadata(dir)?;
    if !md.is_dir() || md.permissions().mode() & 0o077 != 0 {
        return Err(io::Error::other("the audio folder must be a 0700 directory"));
    }
    Ok(())
}

#[cfg(windows)]
fn create_owner_only(dir: &Path) -> io::Result<()> {
    fs::create_dir_all(dir)?;
    // Set every time, so a folder that already existed with wider access is fixed.
    win::owner_only(dir)
}

/// Owner-only on Windows: the folder's DACL is replaced by one entry, full control for the user
/// this process runs as, inherited by everything inside, with nothing inherited from the parent.
#[cfg(windows)]
mod win {
    use std::io;
    use std::os::windows::ffi::OsStrExt;
    use std::path::Path;
    use std::ptr::{null, null_mut};
    use windows_sys::Win32::Foundation::{CloseHandle, LocalFree, HANDLE};
    use windows_sys::Win32::Security::Authorization::{
        SetEntriesInAclW, SetNamedSecurityInfoW, EXPLICIT_ACCESS_W, NO_MULTIPLE_TRUSTEE, SET_ACCESS, SE_FILE_OBJECT,
        TRUSTEE_IS_SID, TRUSTEE_IS_USER, TRUSTEE_W,
    };
    use windows_sys::Win32::Security::{
        GetTokenInformation, TokenUser, ACL, DACL_SECURITY_INFORMATION, PROTECTED_DACL_SECURITY_INFORMATION, PSID,
        SUB_CONTAINERS_AND_OBJECTS_INHERIT, TOKEN_QUERY, TOKEN_USER,
    };
    use windows_sys::Win32::Storage::FileSystem::FILE_ALL_ACCESS;
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

    fn win32(e: u32) -> io::Result<()> {
        if e == 0 {
            Ok(())
        } else {
            Err(io::Error::from_raw_os_error(e as i32))
        }
    }

    pub(super) fn wide(p: &Path) -> Vec<u16> {
        p.as_os_str().encode_wide().chain(Some(0)).collect()
    }

    /// This process's TOKEN_USER, in u64 words so the struct (it holds a pointer) is aligned.
    pub(super) fn token_user() -> io::Result<Vec<u64>> {
        unsafe {
            let mut token: HANDLE = null_mut();
            if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
                return Err(io::Error::last_os_error());
            }
            let mut len = 0u32;
            GetTokenInformation(token, TokenUser, null_mut(), 0, &mut len);
            let mut buf = vec![0u64; (len as usize).div_ceil(8)];
            let ok = GetTokenInformation(token, TokenUser, buf.as_mut_ptr().cast(), len, &mut len);
            let err = io::Error::last_os_error();
            CloseHandle(token);
            if ok == 0 {
                return Err(err);
            }
            Ok(buf)
        }
    }

    /// The user SID inside a `token_user` buffer; valid while the buffer lives.
    pub(super) fn sid(token_user: &[u64]) -> PSID {
        unsafe { (*token_user.as_ptr().cast::<TOKEN_USER>()).User.Sid }
    }

    pub(super) fn owner_only(path: &Path) -> io::Result<()> {
        let user = token_user()?;
        let entry = EXPLICIT_ACCESS_W {
            grfAccessPermissions: FILE_ALL_ACCESS,
            grfAccessMode: SET_ACCESS,
            grfInheritance: SUB_CONTAINERS_AND_OBJECTS_INHERIT,
            Trustee: TRUSTEE_W {
                pMultipleTrustee: null_mut(),
                MultipleTrusteeOperation: NO_MULTIPLE_TRUSTEE,
                TrusteeForm: TRUSTEE_IS_SID,
                TrusteeType: TRUSTEE_IS_USER,
                ptstrName: sid(&user).cast(),
            },
        };
        unsafe {
            let mut acl: *mut ACL = null_mut();
            win32(SetEntriesInAclW(1, &entry, null(), &mut acl))?;
            let set = SetNamedSecurityInfoW(
                wide(path).as_ptr(),
                SE_FILE_OBJECT,
                DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                null_mut(),
                null_mut(),
                acl,
                null(),
            );
            LocalFree(acl.cast());
            win32(set)
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use windows_sys::Win32::Security::Authorization::GetNamedSecurityInfoW;
        use windows_sys::Win32::Security::{
            EqualSid, GetAce, GetSecurityDescriptorControl, ACCESS_ALLOWED_ACE, INHERITED_ACE, PSECURITY_DESCRIPTOR,
            SE_DACL_PROTECTED,
        };

        /// (protected, entries as (allowed, mask, inherited, is this user)).
        fn dacl(path: &Path) -> (bool, Vec<(bool, u32, bool, bool)>) {
            let user = token_user().unwrap();
            unsafe {
                let (mut acl, mut sd): (*mut ACL, PSECURITY_DESCRIPTOR) = (null_mut(), null_mut());
                let e = GetNamedSecurityInfoW(wide(path).as_ptr(), SE_FILE_OBJECT, DACL_SECURITY_INFORMATION, null_mut(), null_mut(), &mut acl, null_mut(), &mut sd);
                win32(e).unwrap();
                let (mut control, mut rev) = (0u16, 0u32);
                assert_ne!(GetSecurityDescriptorControl(sd, &mut control, &mut rev), 0);
                let entries = (0..(*acl).AceCount as u32)
                    .map(|i| {
                        let mut ace = null_mut();
                        assert_ne!(GetAce(acl, i, &mut ace), 0);
                        let ace = &*ace.cast::<ACCESS_ALLOWED_ACE>();
                        let this_user = EqualSid((&ace.SidStart as *const u32).cast_mut().cast(), sid(&user)) != 0;
                        (ace.Header.AceType == 0, ace.Mask, ace.Header.AceFlags as u32 & INHERITED_ACE != 0, this_user)
                    })
                    .collect();
                LocalFree(sd);
                (control & SE_DACL_PROTECTED != 0, entries)
            }
        }

        #[test]
        fn only_this_user_can_open_the_audio_folder_and_its_clips() {
            let dir = std::env::temp_dir().join(format!("shepetal-acl-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&dir);
            let store = super::super::Store::open(&dir).unwrap();
            assert_eq!(dacl(&dir), (true, vec![(true, FILE_ALL_ACCESS, false, true)]), "folder: protected, one entry");
            let clip = store.save(1, super::super::Kind::Dictation, &[0.1]).unwrap();
            assert_eq!(dacl(&clip).1, [(true, FILE_ALL_ACCESS, true, true)], "clip: only the inherited entry");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fresh(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("shepetal-store-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        d.join("Shepetal").join("audio")
    }

    fn names(dir: &Path) -> Vec<String> {
        let mut v: Vec<String> = fs::read_dir(dir).unwrap().map(|e| e.unwrap().file_name().into_string().unwrap()).collect();
        v.sort();
        v
    }

    #[test]
    fn every_kind_of_clip_is_kept_as_16k_mono_and_flagged() {
        // Goal rule 4: cancelled and too-short clips are kept too, marked as such.
        let store = Store::open(fresh("kinds")).unwrap();
        let clip = [0.25f32, -0.5, 0.0];
        for (stamp, kind, name) in [(1, Kind::Dictation, "1.wav"), (2, Kind::Cancelled, "2.cancelled.wav"), (3, Kind::TooShort, "3.tooshort.wav")] {
            let p = store.save(stamp, kind, &clip).unwrap();
            assert_eq!(p.file_name().unwrap(), name);
            assert_eq!(crate::wav::read(&p).unwrap(), (clip.to_vec(), 16_000));
        }
    }

    #[test]
    fn a_stamp_is_never_reused_so_no_clip_is_overwritten() {
        let store = Store::open(fresh("reuse")).unwrap();
        let p = store.save(7, Kind::Dictation, &[0.5]).unwrap();
        assert_eq!(store.save(7, Kind::Dictation, &[0.1]).unwrap_err().kind(), io::ErrorKind::AlreadyExists);
        assert_eq!(crate::wav::read(&p).unwrap().0, [0.5], "the first clip is intact");
    }

    #[cfg(unix)]
    #[test]
    fn clips_are_owner_only() {
        use std::os::unix::fs::PermissionsExt;
        let dir = fresh("perms");
        let p = Store::open(&dir).unwrap().save(1, Kind::Dictation, &[0.1]).unwrap();
        let mode = |p: &Path| fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!((mode(&dir), mode(&p)), (0o700, 0o600));
    }

    #[cfg(unix)]
    #[test]
    fn an_audio_folder_open_to_others_is_refused() {
        use std::os::unix::fs::PermissionsExt;
        let dir = fresh("open");
        fs::create_dir_all(&dir).unwrap();
        for mode in [0o755, 0o750, 0o705] {
            fs::set_permissions(&dir, fs::Permissions::from_mode(mode)).unwrap();
            assert!(Store::open(&dir).is_err(), "{mode:o}");
        }
    }

    #[test]
    fn keep_retention_never_deletes() {
        // Goal rule 4: keep is the default, and it keeps clips of any age.
        assert_eq!(Retention::default(), Retention::Keep);
        let dir = fresh("keep");
        let store = Store::open(&dir).unwrap();
        store.save(0, Kind::Dictation, &[0.1]).unwrap();
        assert_eq!(store.prune(Retention::Keep, 100 * DAY_MS).unwrap(), 0);
        assert_eq!(names(&dir), ["0.wav"]);
    }

    #[test]
    fn delete_24h_removes_day_old_clips_of_every_kind_and_nothing_else() {
        let dir = fresh("24h");
        let store = Store::open(&dir).unwrap();
        let now = 10 * DAY_MS;
        store.save(now - DAY_MS, Kind::Dictation, &[0.1]).unwrap();
        store.save(now - DAY_MS - 5, Kind::Cancelled, &[0.1]).unwrap();
        store.save(now - 2 * DAY_MS, Kind::TooShort, &[0.1]).unwrap();
        store.save(now - DAY_MS + 1, Kind::Dictation, &[0.1]).unwrap();
        store.save(now, Kind::Cancelled, &[0.1]).unwrap();
        for other in ["notes.txt", "1.wav.bak", "1.other.wav", "x1.wav", ".wav"] {
            fs::write(dir.join(other), b"x").unwrap();
        }
        assert_eq!(store.prune(Retention::Delete24h, now).unwrap(), 3);
        let young = [format!("{}.wav", now - DAY_MS + 1), format!("{now}.cancelled.wav")];
        let mut want: Vec<String> = [".wav", "1.other.wav", "1.wav.bak", "notes.txt", "x1.wav"].map(String::from).into();
        want.extend(young);
        want.sort();
        assert_eq!(names(&dir), want);
    }

    #[test]
    fn local_app_data_must_be_absolute() {
        let abs = std::env::temp_dir();
        assert_eq!(data_dir_from(Some(abs.clone())).unwrap(), abs.join("Shepetal"));
        assert!(data_dir_from(Some("relative".into())).is_err());
        assert!(data_dir_from(Some("".into())).is_err());
        assert!(data_dir_from(None).is_err());
    }
}
