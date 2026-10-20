//! Product rule 4: the raw audio of every recording is kept, cancelled and too-short ones included. The user
//! picks keep (the default) or delete after 24 h. There is no "never store" option.

use std::time::{Duration, SystemTime};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Retention {
    #[default]
    Keep,
    Delete24h,
}

pub const MAX_AGE: Duration = Duration::from_secs(24 * 60 * 60);

impl Retention {
    /// The settings value, the same strings as the Mac (`AudioStore.swift`).
    pub fn as_str(self) -> &'static str {
        match self {
            Retention::Keep => "keep",
            Retention::Delete24h => "delete_after_24h",
        }
    }

    /// None for any other value, "never store" included; the app then uses `Retention::default()`, keep.
    pub fn parse(s: &str) -> Option<Retention> {
        match s {
            "keep" => Some(Retention::Keep),
            "delete_after_24h" => Some(Retention::Delete24h),
            _ => None,
        }
    }

    /// Whether a recording made at `recorded_at` is deleted at `now`. Keep never deletes. A recording dated
    /// after `now` (the clock was moved back) stays.
    pub fn deletes(self, recorded_at: SystemTime, now: SystemTime) -> bool {
        self == Retention::Delete24h && now.duration_since(recorded_at).is_ok_and(|age| age >= MAX_AGE)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOUR: Duration = Duration::from_secs(3600);

    fn at(secs: u64) -> SystemTime {
        SystemTime::UNIX_EPOCH + Duration::from_secs(secs)
    }

    #[test]
    fn keep_is_the_default_and_never_deletes() {
        assert_eq!(Retention::default(), Retention::Keep);
        let now = at(10 * 365 * 24 * 3600);
        assert!(!Retention::Keep.deletes(at(0), now), "ten years old and still kept");
    }

    #[test]
    fn delete_24h_deletes_at_24_hours_not_before() {
        let made = at(1_000_000);
        let r = Retention::Delete24h;
        assert!(!r.deletes(made, made + 24 * HOUR - Duration::from_secs(1)));
        assert!(r.deletes(made, made + 24 * HOUR));
        assert!(r.deletes(made, made + 72 * HOUR));
        assert!(!r.deletes(made + HOUR, made), "a recording from the future stays");
    }

    // There are two choices and no "never store" (rule 4). A third variant fails to compile here, because
    // this match has no wildcard arm.
    #[test]
    fn there_is_no_never_store() {
        for r in [Retention::Keep, Retention::Delete24h] {
            match r {
                Retention::Keep | Retention::Delete24h => {}
            }
            assert_eq!(Retention::parse(r.as_str()), Some(r));
        }
        assert_eq!(Retention::Delete24h.as_str(), "delete_after_24h", "the Mac's settings value");
        for s in ["never", "never_store", "off", "none", "0", ""] {
            assert_eq!(Retention::parse(s), None, "{s}");
        }
    }
}
