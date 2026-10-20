//! The text rules the Mac applies before inserting (`Sources/ShepetalCore/TextRules.swift`):
//! `cleanup` drops fillers and stutters, `fit` fits the text to what is around the cursor.
//! The Swift uses ICU regexes with lookbehind and backreferences, which std has no engine for,
//! so the same rules are written out as scans over words.

const SENTENCE_END: [char; 3] = ['.', '!', '?'];
const OPENING: [char; 10] = ['(', '[', '{', '"', '\'', '“', '‘', '/', '@', '#'];
/// The space before a following word is non-breaking, so apps that trim trailing ASCII spaces keep it.
pub const NBSP: char = '\u{a0}';

/// Fits dictated text to the text around the cursor (docs/re/insertion-context.md 2.2 and 2.5):
/// spacing, first-letter case and trailing punctuation. Only the cursor's line counts: the last line
/// of `before` and the first line of `after`. `selected` is the text the insert replaces.
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
                text = upper_first(&text);
            } else if keeps_lowercase(first_word(&text)) {
                text = lower_first(&text);
            }
        }
        _ => {
            let mid = before.chars().rev().find(|c| !c.is_whitespace()).is_some_and(|c| !SENTENCE_END.contains(&c));
            if mid && keeps_lowercase(first_word(&text)) {
                text = lower_first(&text);
            }
        }
    }

    // Sentence end: match the selection's, else drop ours when the text after continues the sentence.
    let continues = after.chars().find(|c| !c.is_whitespace()).is_some_and(|c| c.is_lowercase() || ",;:".contains(c));
    match sel.chars().last() {
        Some(end) if SENTENCE_END.contains(&end) => {
            if text.chars().last().is_some_and(|l| !SENTENCE_END.contains(&l)) {
                text.push(end);
            }
        }
        _ if !sel.is_empty() || continues => text.truncate(text.trim_end_matches(&SENTENCE_END[..]).len()),
        _ => {}
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

/// Swift's Character.isNewline; "\r\n" splits into "\r" and "\n" here, which leaves the same first and last line.
fn is_newline(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{0b}' | '\u{0c}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

fn first_word(s: &str) -> &str {
    let end = s.find(|c: char| !(c.is_alphabetic() || c == '\'' || c == '’')).unwrap_or(s.len());
    &s[..end]
}

/// False for "I", "I'm" and acronyms like "API".
fn keeps_lowercase(word: &str) -> bool {
    if word == "I" || word.starts_with("I'") || word.starts_with("I’") {
        return false;
    }
    let letters: Vec<char> = word.chars().filter(|c| c.is_alphabetic()).collect();
    !(letters.len() > 1 && letters.iter().all(|c| c.is_uppercase()))
}

fn upper_first(s: &str) -> String {
    let mut c = s.chars();
    c.next().map_or(String::new(), |f| f.to_uppercase().chain(c).collect())
}

fn lower_first(s: &str) -> String {
    let mut c = s.chars();
    c.next().map_or(String::new(), |f| f.to_lowercase().chain(c).collect())
}

/// Deterministic cleanup that runs before insertion: drops fillers and stutters, tidies spaces.
/// Only words that are never doubled in correct English count as stutters ("the the"); "had had",
/// "that that" and "very very" are what the user said.
pub fn cleanup(raw: &str) -> String {
    let s = raw.trim();
    let starts_upper = s.chars().next().is_some_and(char::is_uppercase);
    let s = tidy_spaces(&drop_stutters(&drop_fillers(s)));
    let s = s.trim();
    match s.chars().next() {
        Some(f) if starts_upper && f.is_lowercase() => upper_first(s),
        _ => s.to_string(),
    }
}

/// ICU's `\w`.
fn is_word(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

/// `(?i)u+m+|u+h+|uhm|erm|hmm+`, the whole word.
fn is_filler(w: &str) -> bool {
    let w = w.to_lowercase();
    let run = |a: char, b: char| {
        let rest = w.trim_start_matches(a);
        rest.len() < w.len() && !rest.is_empty() && rest.chars().all(|c| c == b)
    };
    run('u', 'm') || run('u', 'h') || w == "uhm" || w == "erm" || w.strip_prefix('h').is_some_and(|r| r.len() >= 2 && r.chars().all(|c| c == 'm'))
}

/// Swift: `(?<![\w-])filler(?![\w-])[,.]?\s*` → "". A word joined by a hyphen ("uh-huh") is not a filler.
fn drop_fillers(s: &str) -> String {
    let c: Vec<char> = s.chars().collect();
    let joined = |c: char| is_word(c) || c == '-';
    let (mut out, mut i) = (String::new(), 0);
    while i < c.len() {
        if !joined(c[i]) {
            out.push(c[i]);
            i += 1;
            continue;
        }
        let j = (i..c.len()).find(|&j| !joined(c[j])).unwrap_or(c.len());
        let w: String = c[i..j].iter().collect();
        i = j;
        if !is_filler(&w) {
            out.push_str(&w);
            continue;
        }
        if i < c.len() && (c[i] == ',' || c[i] == '.') {
            i += 1;
        }
        while i < c.len() && c[i].is_whitespace() {
            i += 1;
        }
    }
    out
}

/// Swift: `(?i)\b(the|an?|and|i)(?:\s+\1\b)+` → "$1".
fn drop_stutters(s: &str) -> String {
    let c: Vec<char> = s.chars().collect();
    let word_end = |i: usize| (i..c.len()).find(|&j| !is_word(c[j])).unwrap_or(c.len());
    let (mut out, mut i) = (String::new(), 0);
    while i < c.len() {
        if !is_word(c[i]) {
            out.push(c[i]);
            i += 1;
            continue;
        }
        let j = word_end(i);
        let w: String = c[i..j].iter().collect();
        out.push_str(&w);
        i = j;
        let w = w.to_lowercase();
        if !["the", "a", "an", "and", "i"].contains(&w.as_str()) {
            continue;
        }
        loop {
            let k = (i..c.len()).find(|&k| !c[k].is_whitespace()).unwrap_or(c.len());
            if k == i || k == c.len() || !is_word(c[k]) {
                break;
            }
            let e = word_end(k);
            if c[k..e].iter().collect::<String>().to_lowercase() != w {
                break;
            }
            i = e;
        }
    }
    out
}

/// Swift: `\s+([,.!?;:])` → "$1", then `\s{2,}` → " ".
fn tidy_spaces(s: &str) -> String {
    let (mut out, mut ws) = (String::new(), String::new());
    for ch in s.chars() {
        if ch.is_whitespace() {
            ws.push(ch);
            continue;
        }
        if !",.!?;:".contains(ch) {
            out.push_str(if ws.chars().count() > 1 { " " } else { ws.as_str() });
        }
        ws.clear();
        out.push(ch);
    }
    out + if ws.chars().count() > 1 { " " } else { ws.as_str() }
}

/// One test per Swift test in `Tests/ShepetalCoreTests/TextRulesTests.swift`, same cases.
#[cfg(test)]
mod tests {
    use super::*;

    fn f(s: &str, before: &str, after: &str) -> String {
        fit(s, before, after, "")
    }
    fn sel(s: &str, before: &str, after: &str, selected: &str) -> String {
        fit(s, before, after, selected)
    }
    fn nb(s: &str) -> String {
        format!("{s}{NBSP}")
    }

    #[test]
    fn empty_field_keeps_text_as_is() {
        assert_eq!(f("Hello there.", "", ""), "Hello there.");
    }

    #[test]
    fn mid_sentence_lowercases_and_adds_space() {
        assert_eq!(f("Send it today.", "Please", ""), " send it today.");
        assert_eq!(f("Send it today.", "Please ", ""), "send it today.");
    }

    #[test]
    fn after_sentence_end_keeps_capital() {
        assert_eq!(f("Thanks.", "Done.", ""), " Thanks.");
        assert_eq!(f("Thanks.", "Line one\n", ""), "Thanks.");
    }

    #[test]
    fn i_and_acronyms_stay_capitalized() {
        assert_eq!(f("I think so.", "and ", ""), "I think so.");
        assert_eq!(f("API keys rotate.", "the ", ""), "API keys rotate.");
    }

    #[test]
    fn following_text_drops_sentence_end_and_adds_space() {
        assert_eq!(f("The report.", "", "is due"), nb("The report"));
        assert_eq!(f("The report.", "", ", which"), "The report");
        assert_eq!(f("Done.", "", "Next sentence."), nb("Done."));
    }

    // Apps that trim trailing ASCII spaces from a paste would glue our last word to the next one.
    #[test]
    fn trailing_boundary_space_is_nbsp() {
        let out = f("Hello.", "", "world");
        assert_eq!(out.chars().last(), Some('\u{a0}'));
        assert!(!out.ends_with(' '));
    }

    #[test]
    fn no_trailing_space_when_nothing_follows() {
        assert_eq!(f("Hello there.", "Done.", ""), " Hello there.");
        assert_eq!(f("Hello there.", "", " Next one."), "Hello there.");
        assert_eq!(f("Hello there.", "", "\nnext line"), "Hello there.");
    }

    // Only the trailing space is non-breaking. A leading NBSP would stop the line from wrapping there.
    #[test]
    fn leading_space_stays_ascii() {
        assert_eq!(f("Send it.", "Please", ""), " send it.");
        assert_eq!(f("Send it", "Please", "now"), nb(" send it"));
    }

    // Replacing a selected word mid-sentence: the new words take its case.
    #[test]
    fn selection_lowercase_is_matched() {
        assert_eq!(sel("Quick brown.", "The ", " fox", "slow"), "quick brown");
        assert_eq!(sel("quick brown", "", "", "Slow"), "Quick brown");
    }

    #[test]
    fn selection_without_period_drops_ours() {
        assert_eq!(sel("New text.", "", "", "Old text"), "New text");
    }

    #[test]
    fn selection_with_period_keeps_it() {
        assert_eq!(sel("New text.", "", "", "Old text."), "New text.");
        assert_eq!(sel("New text", "", "", "Old text!"), "New text!");
        assert_eq!(sel("New text?", "", "", "Old text."), "New text?");
    }

    // The spaces around the selection are the user's; the insert replaces them, so they go back.
    #[test]
    fn selection_keeps_its_spaces() {
        assert_eq!(sel("Bar baz.", "(", ")", " Foo "), " Bar baz ");
        assert_eq!(sel("Bar baz.", "a", "b", " foo "), " bar baz ");
        assert_eq!(sel("Bar baz.", "", "", "\tfoo\n"), "\tbar baz\n");
    }

    // "I" and acronyms keep their capital, and a selected "I" or acronym says nothing about sentence position.
    #[test]
    fn i_and_acronyms_ignore_selection_case() {
        assert_eq!(sel("I agree.", "", "", "maybe"), "I agree");
        assert_eq!(sel("API keys.", "", "", "the keys"), "API keys");
        assert_eq!(sel("The endpoint", "Call ", "", "API"), "the endpoint");
        assert_eq!(sel("Then", "", "", "I"), "Then");
    }

    // Text on earlier lines says nothing about the cursor's sentence.
    #[test]
    fn only_last_line_of_before_counts() {
        assert_eq!(f("Please send it.", "Hello.\nplease", ""), " please send it.");
        assert_eq!(f("Send it.", "and then\n", ""), "Send it.");
        assert_eq!(f("Send it.", "and then\r\n", ""), "Send it.");
    }

    #[test]
    fn only_first_line_of_after_counts() {
        assert_eq!(f("Done.", "", "\ncontinues below"), "Done.");
    }

    #[test]
    fn no_space_after_opening_bracket() {
        assert_eq!(f("Maybe.", "(", ")"), "maybe.");
    }

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
}
