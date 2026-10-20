//! Port of the Mac's Sources/ShepetalCore/TextRules.swift: fitting dictated text to the text around the
//! cursor, the paste-success check, and the deterministic cleanup. Same behavior, same tests.

const SENTENCE_END: [char; 3] = ['.', '!', '?'];
const OPENING: [char; 10] = ['(', '[', '{', '"', '\'', '“', '‘', '/', '@', '#'];
/// The space before a following word is non-breaking, so apps that trim trailing ASCII spaces keep it.
pub const NBSP: char = '\u{00A0}';

/// Fits dictated text to the text around the cursor (docs/re/insertion-context.md 2.2 and 2.5): spacing,
/// first-letter case and trailing punctuation. Only the cursor's line counts: the last line of `before` and
/// the first line of `after`. `selected` is the text the paste replaces.
pub fn fit(dictated: &str, before: &str, after: &str, selected: &str) -> String {
    let mut text = dictated.trim().to_string();
    if text.is_empty() {
        return text;
    }
    let before = before.rsplit(is_newline).next().unwrap_or("");
    let after = after.split(is_newline).next().unwrap_or("");
    let sel = selected.trim();
    let lead = &selected[..selected.len() - selected.trim_start().len()];
    let trail = if sel.is_empty() { "" } else { &selected[selected.trim_end().len()..] };

    // Case: the selection's first letter when it has one that says something (not "I" or an acronym),
    // else lowercase mid-sentence. Our own "I" and acronyms are never lowercased.
    match sel.chars().find(|c| c.is_alphabetic()) {
        Some(f) if keeps_lowercase(first_word(sel)) => {
            if f.is_uppercase() {
                text = with_first(&text, true);
            } else if keeps_lowercase(first_word(&text)) {
                text = with_first(&text, false);
            }
        }
        _ => {
            let mid_sentence = before.chars().rev().find(|c| !c.is_whitespace()).is_some_and(|c| !SENTENCE_END.contains(&c));
            if mid_sentence && keeps_lowercase(first_word(&text)) {
                text = with_first(&text, false);
            }
        }
    }

    // Sentence end: match the selection's, else drop ours when the text after continues the sentence.
    let continues = after.chars().find(|c| !c.is_whitespace()).is_some_and(|c| c.is_lowercase() || ",;:".contains(c));
    match sel.chars().last().filter(|c| SENTENCE_END.contains(c)) {
        Some(end) => {
            if text.chars().last().is_some_and(|c| !SENTENCE_END.contains(&c)) {
                text.push(end);
            }
        }
        None if !sel.is_empty() || continues => {
            while text.ends_with(SENTENCE_END) {
                text.pop();
            }
        }
        None => {}
    }

    if !lead.is_empty() {
        text.insert_str(0, lead);
    } else if before.chars().last().is_some_and(|c| !c.is_whitespace() && !OPENING.contains(&c)) {
        text.insert(0, ' ');
    }
    if !trail.is_empty() {
        text.push_str(trail);
    } else if after.chars().next().is_some_and(|c| c.is_alphabetic() || c.is_numeric()) {
        text.push(NBSP);
    }
    text
}

/// Swift's `Character.isNewline`.
fn is_newline(c: char) -> bool {
    matches!(c, '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

fn with_first(s: &str, upper: bool) -> String {
    let mut chars = s.chars();
    match chars.next() {
        Some(f) if upper => f.to_uppercase().chain(chars).collect(),
        Some(f) => f.to_lowercase().chain(chars).collect(),
        None => String::new(),
    }
}

fn first_word(s: &str) -> &str {
    &s[..s.find(|c: char| !(c.is_alphabetic() || c == '\'' || c == '’')).unwrap_or(s.len())]
}

/// False for "I", "I'm" and acronyms like "API".
fn keeps_lowercase(word: &str) -> bool {
    if word == "I" || word.starts_with("I'") || word.starts_with("I’") {
        return false;
    }
    let letters: Vec<char> = word.chars().filter(|c| c.is_alphabetic()).collect();
    !(letters.len() > 1 && letters.iter().all(|c| c.is_uppercase()))
}

/// The pure part of the paste-success check. An app reading our clipboard data after Ctrl+V means the paste
/// landed; no read within `FAIL_AFTER_MS` means it failed. On Windows the read shows up with delayed rendering
/// (SetClipboardData with a null handle) as WM_RENDERFORMAT. Windows asks for a format only once, so the data
/// also needs ExcludeClipboardContentFromMonitorProcessing, or a clipboard manager may read it first.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    Waiting,
    Landed,
    Failed,
}

pub const FAIL_AFTER_MS: u64 = 1000;
pub const RESTORE_DELAY_MS: u64 = 500;

/// A read before Ctrl+V (a clipboard manager) does not count as the paste.
pub fn verdict(posted_at: u64, requested_at: Option<u64>, now: u64) -> Verdict {
    if requested_at.is_some_and(|r| r >= posted_at) {
        return Verdict::Landed;
    }
    if now.saturating_sub(posted_at) >= FAIL_AFTER_MS { Verdict::Failed } else { Verdict::Waiting }
}

/// When to put the user's clipboard back. Only after a paste that landed: one that did not leaves the text
/// on the clipboard for Ctrl+V (rule 8). The Mac returns a time for that case too and its caller skips it.
pub fn restore_at(posted_at: u64, requested_at: Option<u64>) -> Option<u64> {
    requested_at.filter(|&r| r >= posted_at).map(|r| r + RESTORE_DELAY_MS)
}

/// Deterministic cleanup that runs before insertion: drops fillers and stutters, tidies spaces.
/// Only words that are never doubled in correct English count as stutters ("the the"); "had had",
/// "that that" and "very very" are what the user said. The Mac does this with regexes that need lookbehind
/// and backreferences; this is the same rules by hand, so the crate has no dependency.
pub fn cleanup(raw: &str) -> String {
    let s = raw.trim();
    let starts_upper = s.chars().next().is_some_and(char::is_uppercase);
    let s = tidy_spaces(&drop_stutters(&drop_fillers(s)));
    let s = s.trim();
    if starts_upper && s.chars().next().is_some_and(char::is_lowercase) {
        with_first(s, true)
    } else {
        s.to_string()
    }
}

/// Regex `\w`.
fn is_word(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

/// The length of the run of chars at the start of `s` that pass `f`.
fn run(s: &str, f: fn(char) -> bool) -> usize {
    s.find(|c: char| !f(c)).unwrap_or(s.len())
}

/// um, uh, uhm, erm, hmm in any case and stretched ("ummm", "hmmm"), with a comma or period right after and
/// the spaces after that. Only whole words, hyphens included: "umbrella" and "uh-huh" stay.
fn drop_fillers(s: &str) -> String {
    let mut out = String::new();
    let mut rest = s;
    while let Some(c) = rest.chars().next() {
        let n = run(rest, |c| is_word(c) || c == '-');
        if n == 0 {
            out.push(c);
            rest = &rest[c.len_utf8()..];
            continue;
        }
        let (word, after) = rest.split_at(n);
        if is_filler(word) {
            rest = after.strip_prefix([',', '.']).unwrap_or(after).trim_start();
        } else {
            out.push_str(word);
            rest = after;
        }
    }
    out
}

/// `u+m+|u+h+|uhm|erm|hmm+`, case-insensitive, over the whole word.
fn is_filler(word: &str) -> bool {
    let w = word.to_lowercase();
    let only = |s: &str, c: char| !s.is_empty() && s.chars().all(|x| x == c);
    let after_u = w.trim_start_matches('u');
    w == "uhm"
        || w == "erm"
        || w.strip_prefix("hm").is_some_and(|t| only(t, 'm'))
        || (after_u.len() < w.len() && (only(after_u, 'm') || only(after_u, 'h')))
}

/// "the the" becomes "the", for the, a, an, and, I in any case; the first one's case stays.
fn drop_stutters(s: &str) -> String {
    const NEVER_DOUBLED: [&str; 5] = ["the", "a", "an", "and", "i"];
    let mut out = String::new();
    let mut rest = s;
    while let Some(c) = rest.chars().next() {
        let n = run(rest, is_word);
        if n == 0 {
            out.push(c);
            rest = &rest[c.len_utf8()..];
            continue;
        }
        let (word, mut after) = rest.split_at(n);
        out.push_str(word);
        if NEVER_DOUBLED.iter().any(|w| w.eq_ignore_ascii_case(word)) {
            loop {
                let next = after.trim_start();
                let m = run(next, is_word);
                if next.len() == after.len() || !next[..m].eq_ignore_ascii_case(word) {
                    break;
                }
                after = &next[m..];
            }
        }
        rest = after;
    }
    out
}

/// No space before , . ! ? ; : and a run of two or more spaces becomes one.
fn tidy_spaces(s: &str) -> String {
    let mut out = String::new();
    let mut rest = s;
    while let Some(c) = rest.chars().next() {
        let n = run(rest, char::is_whitespace);
        if n == 0 {
            out.push(c);
            rest = &rest[c.len_utf8()..];
            continue;
        }
        let (spaces, after) = rest.split_at(n);
        match after.chars().next() {
            Some(p) if ",.!?;:".contains(p) => {}
            _ if spaces.chars().count() >= 2 => out.push(' '),
            _ => out.push_str(spaces),
        }
        rest = after;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fit4(s: &str, before: &str, after: &str, selected: &str) -> String {
        fit(s, before, after, selected)
    }
    fn fit3(s: &str, before: &str, after: &str) -> String {
        fit(s, before, after, "")
    }
    const NB: &str = "\u{00A0}";

    // InsertionRulesTests

    #[test]
    fn empty_field_keeps_text_as_is() {
        assert_eq!(fit3("Hello there.", "", ""), "Hello there.");
    }

    #[test]
    fn mid_sentence_lowercases_and_adds_space() {
        assert_eq!(fit3("Send it today.", "Please", ""), " send it today.");
        assert_eq!(fit3("Send it today.", "Please ", ""), "send it today.");
    }

    #[test]
    fn after_sentence_end_keeps_capital() {
        assert_eq!(fit3("Thanks.", "Done.", ""), " Thanks.");
        assert_eq!(fit3("Thanks.", "Line one\n", ""), "Thanks.");
    }

    #[test]
    fn i_and_acronyms_stay_capitalized() {
        assert_eq!(fit3("I think so.", "and ", ""), "I think so.");
        assert_eq!(fit3("API keys rotate.", "the ", ""), "API keys rotate.");
    }

    #[test]
    fn following_text_drops_sentence_end_and_adds_space() {
        assert_eq!(fit3("The report.", "", "is due"), format!("The report{NB}"));
        assert_eq!(fit3("The report.", "", ", which"), "The report");
        assert_eq!(fit3("Done.", "", "Next sentence."), format!("Done.{NB}"));
    }

    // Apps that trim trailing ASCII spaces from a paste would glue our last word to the next one.
    #[test]
    fn trailing_boundary_space_is_nbsp() {
        let out = fit3("Hello.", "", "world");
        assert_eq!(out.chars().last(), Some('\u{00A0}'));
        assert!(!out.ends_with(' '));
    }

    #[test]
    fn no_trailing_space_when_nothing_follows() {
        assert_eq!(fit3("Hello there.", "Done.", ""), " Hello there.");
        assert_eq!(fit3("Hello there.", "", " Next one."), "Hello there.");
        assert_eq!(fit3("Hello there.", "", "\nnext line"), "Hello there.");
    }

    // Only the trailing space is non-breaking. A leading NBSP would stop the line from wrapping there.
    #[test]
    fn leading_space_stays_ascii() {
        assert_eq!(fit3("Send it.", "Please", ""), " send it.");
        assert_eq!(fit3("Send it", "Please", "now"), format!(" send it{NB}"));
    }

    // Replacing a selected word mid-sentence: the new words take its case.
    #[test]
    fn selection_lowercase_is_matched() {
        assert_eq!(fit4("Quick brown.", "The ", " fox", "slow"), "quick brown");
        assert_eq!(fit4("quick brown", "", "", "Slow"), "Quick brown");
    }

    #[test]
    fn selection_without_period_drops_ours() {
        assert_eq!(fit4("New text.", "", "", "Old text"), "New text");
    }

    #[test]
    fn selection_with_period_keeps_it() {
        assert_eq!(fit4("New text.", "", "", "Old text."), "New text.");
        assert_eq!(fit4("New text", "", "", "Old text!"), "New text!");
        assert_eq!(fit4("New text?", "", "", "Old text."), "New text?");
    }

    // The spaces around the selection are the user's; the paste replaces them, so they go back.
    #[test]
    fn selection_keeps_its_spaces() {
        assert_eq!(fit4("Bar baz.", "(", ")", " Foo "), " Bar baz ");
        assert_eq!(fit4("Bar baz.", "a", "b", " foo "), " bar baz ");
        assert_eq!(fit4("Bar baz.", "", "", "\tfoo\n"), "\tbar baz\n");
    }

    // "I" and acronyms keep their capital, and a selected "I" or acronym says nothing about sentence position.
    #[test]
    fn i_and_acronyms_ignore_selection_case() {
        assert_eq!(fit4("I agree.", "", "", "maybe"), "I agree");
        assert_eq!(fit4("API keys.", "", "", "the keys"), "API keys");
        assert_eq!(fit4("The endpoint", "Call ", "", "API"), "the endpoint");
        assert_eq!(fit4("Then", "", "", "I"), "Then");
    }

    // Text on earlier lines says nothing about the cursor's sentence.
    #[test]
    fn only_last_line_of_before_counts() {
        assert_eq!(fit3("Please send it.", "Hello.\nplease", ""), " please send it.");
        assert_eq!(fit3("Send it.", "and then\n", ""), "Send it.");
        assert_eq!(fit3("Send it.", "and then\r\n", ""), "Send it.");
    }

    #[test]
    fn only_first_line_of_after_counts() {
        assert_eq!(fit3("Done.", "", "\ncontinues below"), "Done.");
    }

    #[test]
    fn no_space_after_opening_bracket() {
        assert_eq!(fit3("Maybe.", "(", ")"), "maybe.");
    }

    // PasteCheckTests

    #[test]
    fn data_requested_after_ctrl_v_means_landed() {
        assert_eq!(verdict(10_000, Some(10_050), 10_060), Verdict::Landed);
        assert_eq!(restore_at(10_000, Some(10_050)), Some(10_550));
    }

    #[test]
    fn no_request_within_one_second_means_failed() {
        assert_eq!(verdict(10_000, None, 10_999), Verdict::Waiting);
        assert_eq!(verdict(10_000, None, 11_000), Verdict::Failed);
        assert_eq!(restore_at(10_000, None), None, "rule 8: a paste that did not land never restores the old clipboard");
    }

    // A clipboard manager reading before Ctrl+V is not the paste landing.
    #[test]
    fn read_before_ctrl_v_does_not_count() {
        assert_eq!(verdict(10_000, Some(9_900), 11_200), Verdict::Failed);
        assert_eq!(restore_at(10_000, Some(9_900)), None);
    }

    // CleanupTests

    #[test]
    fn drops_fillers_and_stutters() {
        assert_eq!(cleanup("Um, so the the build is, uh, green."), "So the build is, green.");
        assert_eq!(cleanup("  We ship   today .  "), "We ship today.");
    }

    #[test]
    fn keeps_words_that_contain_fillers() {
        assert_eq!(cleanup("Hummus and umbrellas."), "Hummus and umbrellas.");
    }

    // Some doubled words are correct English. Dropping one changes what the user said.
    #[test]
    fn keeps_grammatical_repeats() {
        assert_eq!(cleanup("I had had enough, and I think that that is fine."), "I had had enough, and I think that that is fine.");
        assert_eq!(cleanup("It is very very good, no no."), "It is very very good, no no.");
    }

    // Repeats that are never correct English are stutters and go.
    #[test]
    fn drops_stutters_on_words_that_never_repeat() {
        assert_eq!(cleanup("I I think a a test and and the the fix work."), "I think a test and the fix work.");
    }

    // "Uh-huh" and "mm-hmm" are answers, not fillers.
    #[test]
    fn keeps_hyphenated_answers() {
        assert_eq!(cleanup("Uh-huh, sounds good."), "Uh-huh, sounds good.");
        assert_eq!(cleanup("Mm-hmm, ship it."), "Mm-hmm, ship it.");
    }

    // Not in the Mac's tests, but what its regexes do; the hand port must match them.
    #[test]
    fn hand_port_matches_the_mac_regexes() {
        assert_eq!(cleanup("Ummm, hmm. Erm the The THE plan"), "The plan", "stretched fillers, any case");
        assert_eq!(cleanup("the theme and android"), "the theme and android", "a stutter is a whole word");
        assert_eq!(cleanup("Hm, ok"), "Hm, ok", "hmm+ needs two m's");
        assert_eq!(cleanup("one\ntwo  \n three"), "one\ntwo three", "a single newline stays, a run becomes one space");
    }
}
