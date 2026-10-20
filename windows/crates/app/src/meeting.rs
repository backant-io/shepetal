//! What shepetal.exe shows for the meetings crate's events. Pavel's rule: a detected meeting is
//! never recorded on its own, only after one click on Record in the card above the 🤫, as on the
//! Mac ("Meeting detected · <app>", Record, Not now).

use input::{overlay_rect, scale, Rect, GAP};
use meetings::Event;

#[derive(Debug, PartialEq)]
pub enum Show {
    /// Show the card with this label, and its Record and Not now.
    Offer(String),
    /// Hide the card: the meeting ended before Record was clicked.
    Withdraw,
    /// Text next to the 🤫.
    Hint(&'static str),
    Nothing,
}

/// `app` keeps the meeting app that started last, for the card's label: the detector reports
/// `Started` right before the `OfferRecording` it causes.
pub fn show(event: &Event, app: &mut String) -> Show {
    match event {
        Event::Started(a) => {
            a.clone_into(app);
            Show::Nothing
        }
        Event::OfferRecording => Show::Offer(format!("Meeting detected · {app}")),
        Event::WithdrawOffer => Show::Withdraw,
        Event::StartRecording => Show::Hint("Recording the meeting"),
        Event::Ended(_) | Event::StopRecording => Show::Nothing,
    }
}

/// The card, `w` by `h` pixels: left-aligned with the 🤫, just above it.
pub fn card_rect(work: Rect, dpi: u32, w: i32, h: i32) -> Rect {
    let icon = overlay_rect(work, dpi, 0);
    let bottom = icon.top - scale(GAP, dpi);
    Rect { left: icon.left, top: bottom - h, right: icon.left + w, bottom }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nothing_says_recording_before_the_record_click() {
        let mut app = String::new();
        assert_eq!(show(&Event::Started("Zoom".into()), &mut app), Show::Nothing);
        assert_eq!(show(&Event::OfferRecording, &mut app), Show::Offer("Meeting detected · Zoom".into()));
        assert_eq!(show(&Event::WithdrawOffer, &mut app), Show::Withdraw, "an unanswered offer goes away");
        // Only the recording that really started (after the click) says so.
        assert_eq!(show(&Event::StartRecording, &mut app), Show::Hint("Recording the meeting"));
        assert_eq!(show(&Event::Ended("Zoom".into()), &mut app), Show::Nothing);
    }

    #[test]
    fn the_card_names_the_app_that_started_last() {
        let mut app = String::new();
        show(&Event::Started("Zoom".into()), &mut app);
        show(&Event::WithdrawOffer, &mut app);
        show(&Event::Started("Microsoft Teams".into()), &mut app);
        assert_eq!(show(&Event::OfferRecording, &mut app), Show::Offer("Meeting detected · Microsoft Teams".into()));
    }

    #[test]
    fn the_card_sits_just_above_the_icon_and_never_covers_it() {
        let work = Rect { left: 0, top: 0, right: 1920, bottom: 1032 };
        for dpi in [96, 144, 192] {
            let icon = overlay_rect(work, dpi, 0);
            let card = card_rect(work, dpi, 300, 30);
            assert_eq!(card.left, icon.left, "left-aligned with the icon");
            assert_eq!(card.bottom, icon.top - scale(GAP, dpi), "one gap above it");
            assert_eq!((card.right - card.left, card.bottom - card.top), (300, 30));
            assert!(card.top >= work.top && card.right <= work.right, "inside the work area");
        }
    }
}
