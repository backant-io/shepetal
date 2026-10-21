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

/// Spoken dates become numbers (docs/text-rules.md): "the twenty sixth of July twenty twenty-six" is
/// "26.07.26" and "26. Juni" is "26.06.", in English and German at once. Runs on the cleaned text. No
/// platform had a number-word parser, so the small one below is the first.
pub fn dates(text: &str) -> String {
    let w = Words::new(text);
    let mut out = String::new();
    let (mut copied, mut i) = (0, 0);
    while i < w.at.len() {
        match w.date(i) {
            Some((date, next, end)) => {
                out.push_str(&text[copied..w.at[i].0]);
                out.push_str(&date);
                copied = end;
                i = next;
            }
            None => i += 1,
        }
    }
    out.push_str(&text[copied..]);
    out
}

const MONTHS: [&str; 12] =
    ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"];
const MONATE: [&str; 12] =
    ["januar", "februar", "märz", "april", "mai", "juni", "juli", "august", "september", "oktober", "november", "dezember"];
const UNITS: [&str; 9] = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"];
const TEENS: [&str; 10] = ["ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"];
const TENS: [&str; 8] = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"];
const ORDINALS: [&str; 19] = [
    "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "eleventh", "twelfth",
    "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth", "eighteenth", "nineteenth",
];
const EINER: [&str; 9] = ["ein", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun"];
const ZEHNER: [&str; 10] =
    ["zehn", "elf", "zwölf", "dreizehn", "vierzehn", "fünfzehn", "sechzehn", "siebzehn", "achtzehn", "neunzehn"];
const ZIGER: [&str; 8] = ["zwanzig", "dreißig", "vierzig", "fünfzig", "sechzig", "siebzig", "achtzig", "neunzig"];
const ORDNUNG: [&str; 9] = ["erst", "zweit", "dritt", "viert", "fünft", "sechst", "siebt", "acht", "neunt"];
/// What may follow a short year: `.` `;` `:` `!` `?` `)` and closing quotes ("July 26, 26", „... sechsundzwanzig“).
const ENDS: &str = ".;:!?)\"'’”“»«";

/// 1 for the first entry of `list`.
fn pos(list: &[&str], w: &str) -> Option<u32> {
    list.iter().position(|x| *x == w).map(|i| i as u32 + 1)
}

fn month(w: &str) -> Option<u32> {
    pos(&MONTHS, w).or_else(|| pos(&MONATE, w))
}

/// English 1 to 99: "six", "twelve", "twenty six".
fn en_number(p: &str) -> Option<u32> {
    let tens = |t| pos(&TENS, t).map(|i| i * 10 + 10);
    match p.split_once(' ') {
        Some((t, u)) => Some(tens(t)? + pos(&UNITS, u)?),
        None => pos(&UNITS, p).or_else(|| pos(&TEENS, p).map(|i| i + 9)).or_else(|| tens(p)),
    }
}

/// English day 1 to 31: "first", "twentieth", "twenty sixth".
fn en_ordinal(p: &str) -> Option<u32> {
    match p.split_once(' ') {
        Some(("twenty", u)) => pos(&ORDINALS[..9], u).map(|i| i + 20),
        Some(("thirty", "first")) => Some(31),
        Some(_) => None,
        None => pos(&ORDINALS, p).or(match p {
            "twentieth" => Some(20),
            "thirtieth" => Some(30),
            _ => None,
        }),
    }
}

/// German 1 to 99 as one word: "eins", "zwölf", "sechsundzwanzig".
fn de_number(w: &str) -> Option<u32> {
    let tens = |t| pos(&ZIGER, t).map(|i| i * 10 + 10);
    match w.split_once("und") {
        Some((e, z)) => Some(tens(z)? + pos(&EINER, e)?),
        None if w == "eins" => Some(1),
        None => pos(&EINER, w).or_else(|| pos(&ZEHNER, w).map(|i| i + 9)).or_else(|| tens(w)),
    }
}

/// German day as one word with its ending: "erste", "siebten", "zwölfter", "sechsundzwanzigsten".
fn de_ordinal(w: &str) -> Option<u32> {
    let stem = ["er", "en", "es", "em", "e"].iter().find_map(|e| w.strip_suffix(e))?;
    if stem == "siebent" {
        return Some(7);
    }
    pos(&ORDNUNG, stem)
        .or_else(|| stem.strip_suffix('t').and_then(|s| pos(&ZEHNER, s)).map(|i| i + 9))
        .or_else(|| stem.strip_suffix("st").and_then(de_number).filter(|v| *v >= 20))
}

/// zweitausend, zweitausendsechsundzwanzig, zweitausend sechsundzwanzig, zweitausendundfünf, neunzehnhundert...
fn de_year(p: &str) -> Option<u32> {
    let all: String = p.split(' ').collect();
    let rest = all.strip_prefix("zweitausend").or_else(|| all.strip_prefix("neunzehnhundert"))?;
    if rest.is_empty() {
        return Some(0);
    }
    de_number(rest.strip_prefix("und").unwrap_or(rest))
}

/// "26", "26th" or "1st": the day, and whether it is bare digits (only those take the German "26.").
fn digit_day(w: &str) -> Option<(u32, bool)> {
    let n = w.find(|c: char| !c.is_ascii_digit()).unwrap_or(w.len());
    if !(1..=2).contains(&n) || !["", "st", "nd", "rd", "th"].contains(&&w[n..]) {
        return None;
    }
    Some((w[..n].parse().ok()?, n == w.len()))
}

fn digits(w: &str, n: usize) -> Option<u32> {
    (w.len() == n && w.bytes().all(|b| b.is_ascii_digit())).then(|| w.parse().ok())?
}

/// A date found at a word: its numbers, the word after it, and the byte where it ends.
type Found = (String, usize, usize);

/// The text as words (runs of `is_word`) and what is between them.
struct Words<'a> {
    text: &'a str,
    at: Vec<(usize, usize)>,
}

impl<'a> Words<'a> {
    fn new(text: &'a str) -> Self {
        let mut at = vec![];
        let mut i = 0;
        while let Some(c) = text[i..].chars().next() {
            match run(&text[i..], is_word) {
                0 => i += c.len_utf8(),
                n => {
                    at.push((i, i + n));
                    i += n;
                }
            }
        }
        Words { text, at }
    }

    /// Word `i` in lowercase, with ae, oe, ue and ss read as ä, ö, ü and ß; "" past the end.
    fn word(&self, i: usize) -> String {
        self.at.get(i).map_or(String::new(), |&(a, b)| {
            self.text[a..b].to_lowercase().replace("ae", "ä").replace("oe", "ö").replace("ue", "ü").replace("ss", "ß")
        })
    }

    /// The text after word `i` up to the next word, or to the end after the last one.
    fn gap(&self, i: usize) -> &str {
        match self.at.get(i) {
            Some(&(_, end)) => &self.text[end..self.at.get(i + 1).map_or(self.text.len(), |w| w.0)],
            None => "",
        }
    }

    /// A hyphen equals a space inside a spoken number.
    fn spaced(&self, i: usize) -> bool {
        matches!(self.gap(i), " " | "-")
    }

    /// The longest run of up to `max` spaced words from `i` that `f` reads: its value and length.
    fn longest(&self, i: usize, max: usize, f: fn(&str) -> Option<u32>) -> Option<(u32, usize)> {
        (1..=max).rev().find_map(|n| {
            let spaced = i + n <= self.at.len() && (i..i + n - 1).all(|k| self.spaced(k));
            let p = (i..i + n).map(|k| self.word(k)).collect::<Vec<_>>().join(" ");
            spaced.then(|| f(&p).map(|v| (v, n)))?
        })
    }

    fn date(&self, i: usize) -> Option<Found> {
        if self.text[..self.at[i].0].ends_with('.') {
            return None; // inside "26.07.26": already numbers
        }
        self.day_first(i).or_else(|| self.month_first(i))
    }

    /// `[the] DAY [of] MONTH [,] [YEAR]`
    fn day_first(&self, i: usize) -> Option<Found> {
        let the = self.word(i) == "the" && self.gap(i) == " ";
        let d = i + usize::from(the);
        // A spelled day is the whole number: in "twenty ninth" the day is 29, never "ninth", and "forty first"
        // and "sechs und zwanzigsten" are no day. Cleanup leaves "twenty, ninth" from "twenty, uh, ninth".
        let tens_before = d > 0 && matches!(self.gap(d - 1), " " | "-" | ", ") && pos(&TENS, &self.word(d - 1)).is_some();
        let und_before = d > 1
            && self.word(d - 1) == "und"
            && self.gap(d - 1) == " "
            && self.gap(d - 2) == " "
            && pos(&EINER, &self.word(d - 2)).is_some();
        let (day, n, bare, en) = if let Some((v, n)) = self.longest(d, 2, en_ordinal).filter(|_| !tens_before) {
            (v, n, false, true)
        } else if let Some(v) = de_ordinal(&self.word(d)).filter(|_| !und_before) {
            (v, 1, false, false)
        } else {
            let (v, bare) = digit_day(&self.word(d))?;
            (v, 1, bare, false)
        };
        let gap = self.gap(d + n - 1);
        let dot = bare && gap == ". ";
        if gap != " " && !dot {
            return None;
        }
        // "of" never ends a phrase, so a comma after it is a dropped filler's: "the first of, um, March".
        let of = self.word(d + n) == "of" && matches!(self.gap(d + n), " " | ", ");
        if en && !of {
            return None; // "my first April", "this is my third September"
        }
        let m = d + n + usize::from(of);
        let mo = month(&self.word(m))?;
        if self.gap(m).starts_with('-') {
            return None; // "die erste Juli-Woche" is a week
        }
        if dot && pos(&MONATE, &self.word(m)).is_none() {
            return None; // the German "26." needs a German month: "version 2. March is next", "5. May I ask"
        }
        if !of && matches!(self.word(m).as_str(), "may" | "march") && !self.capital(m) {
            return None; // "the second may be better", "the first march was long"
        }
        let year = self.year(m);
        if of && year.is_none() && (day, mo) == (4, 7) {
            return None; // "Happy Fourth of July!" is the holiday's name
        }
        self.found(day, mo, m, year)
    }

    /// `MONTH [the] DAY [,] [YEAR]`, with an English month and an English or digit day. German puts the day
    /// first, so "Mai 2" in "I met Mai 2 weeks ago" is no date.
    fn month_first(&self, i: usize) -> Option<Found> {
        let mo = pos(&MONTHS, &self.word(i))?;
        if self.word(i) == "may" && !self.capital(i) {
            return None; // "you may first want to"
        }
        if self.gap(i) != " " {
            return None;
        }
        let d = i + 1 + usize::from(self.word(i + 1) == "the" && self.gap(i + 1) == " ");
        let (day, n) = match self.longest(d, 2, en_ordinal) {
            Some(found) => found,
            None if self.joined(d) => return None, // "June 26.07.2026", "July 10:30", "March 3-5", "July 26%"
            None => (digit_day(&self.word(d))?.0, 1),
        };
        self.found(day, mo, d + n - 1, self.year(d + n - 1))
    }

    /// The year after word `last` (a comma between is fine): its last two digits, the full year and the
    /// word after it.
    fn year(&self, last: usize) -> Option<(u32, u32, usize)> {
        if !matches!(self.gap(last), " " | ", ") {
            return None;
        }
        let y = last + 1;
        let w = self.word(y);
        let (yy, full, n) = match digits(&w, 4) {
            Some(v) => (v % 100, v, 1),
            None => {
                let century = if w.starts_with("nineteen") || w.starts_with("neunzehn") { 1900 } else { 2000 };
                let (yy, n) = self.spoken_year(y, &w)?;
                (yy, century + yy, n)
            }
        };
        // A year ending in 00 is also a round count: "On July 4th two thousand people marched". And a year
        // never stops inside a hyphenated word: "nineteen twenty-first" is not 1920.
        let last = y + n - 1;
        ((yy != 0 || self.ends(last)) && !self.gap(last).starts_with('-')).then_some((yy, full, y + n))
    }

    /// A spelled or two-digit year at word `y` (`w`): its last two digits and its length in words.
    fn spoken_year(&self, y: usize, w: &str) -> Option<(u32, usize)> {
        if w == "nineteen" && self.spaced(y) && self.word(y + 1) == "hundred" {
            return Some((0, 2));
        }
        // twenty twenty-six, nineteen ninety nine, twenty oh nine
        if (w == "twenty" || w == "nineteen") && self.spaced(y) {
            if self.word(y + 1) == "oh" && self.spaced(y + 1) {
                if let Some(u) = pos(&UNITS, &self.word(y + 2)) {
                    return Some((u, 3));
                }
            }
            if let Some((v, n)) = self.longest(y + 1, 2, en_number).filter(|(v, _)| *v >= 10) {
                return Some((v, 1 + n));
            }
        }
        // two thousand, two thousand five, two thousand and twenty six
        if w == "two" && self.spaced(y) && self.word(y + 1) == "thousand" {
            let and = usize::from(self.spaced(y + 1) && self.word(y + 2) == "and" && self.spaced(y + 2));
            let more = if self.spaced(y + 1) { self.longest(y + 2 + and, 2, en_number) } else { None };
            return Some(more.map_or((0, 2), |(v, n)| (v, 2 + and + n)));
        }
        // zweitausend sechs und zwanzig is 2026 as a whole, never 2006
        if let Some(found) = self.longest(y, 4, de_year) {
            return Some(found);
        }
        // A short year (26, twenty six, sechsundzwanzig) only where `ends`: in "July fourth twenty six people
        // came" it is a count.
        let (v, n) = match digits(w, 2) {
            Some(v) => (v, 1),
            None => self.longest(y, 2, en_number).or_else(|| de_number(w).map(|v| (v, 1))).filter(|(v, _)| *v >= 10)?,
        };
        self.ends(y + n - 1).then_some((v, n))
    }

    /// The end of the text, or `.` `;` `:` `!` `?` `)` or a quote without a digit right after it, follows word
    /// `k`. A comma does not count: in "May 15, 16, and 17" the 16 is a day, and in "March 5, 10:30" a time.
    fn ends(&self, k: usize) -> bool {
        let mut after = self.text[self.at[k].1..].chars();
        after.next().is_none_or(|c| ENDS.contains(c) && !after.next().is_some_and(|c| c.is_ascii_digit()))
    }

    /// Word `k` runs on into another number or a sign: only a space, the end, or `,` or what `ends` takes,
    /// without a digit right after it, ends a day. "26.07.2026", "10:30", "3-5", "26/27" and "26%" stay.
    fn joined(&self, k: usize) -> bool {
        let Some(&(_, end)) = self.at.get(k) else { return false };
        let mut after = self.text[end..].chars();
        after.next().is_some_and(|c| {
            !c.is_whitespace() && (!(c == ',' || ENDS.contains(c)) || after.next().is_some_and(|c| c.is_ascii_digit()))
        })
    }

    /// Word `i` starts with a capital: "May", "MAY".
    fn capital(&self, i: usize) -> bool {
        self.text[self.at[i].0..].starts_with(char::is_uppercase)
    }

    /// The date as numbers if it exists, from its fields and its last word before the year.
    fn found(&self, day: u32, mo: u32, last: usize, year: Option<(u32, u32, usize)>) -> Option<Found> {
        let leap = |y: u32| y.is_multiple_of(4) && (!y.is_multiple_of(100) || y.is_multiple_of(400));
        let feb = match year {
            Some((_, full, _)) if !leap(full) => 28,
            _ => 29,
        };
        if day < 1 || day > [31, feb, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][mo as usize - 1] {
            return None;
        }
        Some(match year {
            Some((yy, _, next)) => (format!("{day:02}.{mo:02}.{yy:02}"), next, self.at[next - 1].1),
            // A "." right after "DD.MM." is the date's own dot.
            None => {
                let end = self.at[last].1;
                (format!("{day:02}.{mo:02}."), last + 1, end + usize::from(self.text[end..].starts_with('.')))
            }
        })
    }
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

    // Vectors from the #159 review that this rule does not pass yet: #197. Each one must still fail, so the
    // list shrinks as the rule catches up, and it goes when it is empty.
    const PENDING: &[&str] = &[
        "the hundred and first of May",
        "the 4th of July 26 people",
        "the thirtieth of February 15 people",
        "On May 5th 1350 visitors came.",
        "the 14th of July 1789",
        "May the fourth be with you.",
        "in week 2 of March we ship",
        "Chapter 3 of May's report",
        "In March second-quarter numbers dropped",
    ];

    // Pavel: spoken dates are written DD.MM.YY. The vectors are shared with the Mac and Linux, so a case
    // added to the file is enforced here without touching this test.
    #[test]
    fn dates_match_the_shared_vectors() {
        let json = include_str!("../../../../Tests/fixtures/text-rules/dates.json");
        let cases: Vec<serde_json::Value> = serde_json::from_str(json).expect("dates.json is a JSON array");
        assert!(cases.len() >= 80, "dates.json holds {} cases, want at least 80", cases.len());
        let mut failed = vec![];
        let mut passing_but_pending = vec![];
        for c in &cases {
            let (input, expected, note) = (c["input"].as_str().unwrap(), c["expected"].as_str().unwrap(), &c["note"]);
            let (got, again) = (dates(input), dates(expected));
            if PENDING.contains(&input) {
                if got == expected && again == expected {
                    passing_but_pending.push(input);
                }
                continue;
            }
            if got != expected {
                failed.push(format!("{input:?} gave {got:?}, want {expected:?} ({note})"));
            }
            if again != expected {
                failed.push(format!("{expected:?} changed on a second run to {again:?} ({note})"));
            }
        }
        assert!(failed.is_empty(), "{} of {} date cases failed:\n{}", failed.len(), cases.len(), failed.join("\n"));
        assert!(passing_but_pending.is_empty(), "these pass now, remove them from PENDING (#197): {passing_but_pending:?}");
    }

    // docs/text-rules.md: running the rule twice changes nothing, also on text no vector holds. A month
    // before a numeric date once re-read its first number as a day: "Juli 26.07.2026" became
    // "26.07.07.2026", and "Does May July 4th work?" changed again on a second run.
    #[test]
    fn dates_on_its_own_output_changes_nothing() {
        let vocab: Vec<&str> = "the of on am den May may March march Juli July Juni 4th 26 5 26. 07. 1st first second \
            twenty sixth ninth twenty-sixth nineteen two thousand 2026 2000 26.07.2026 04.07. 10:30 3-5 zweitausend \
            sechsundzwanzig people Mai forty und sechs zwanzigsten hundred 26% 1.000 3,5 \" , . ?"
            .split_whitespace()
            .collect();
        let mut seed = 0x2545_f491_4f6c_dd1d_u64;
        let mut next = move || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed as usize
        };
        let mut changed = 0;
        for _ in 0..50_000 {
            let n = 1 + next() % 8;
            let s = (0..n).map(|_| vocab[next() % vocab.len()]).collect::<Vec<_>>().join(" ");
            // A trailing space once made "In July " read past the last word and panic.
            let s = s.replace(" ,", ",").replace(" .", ".").replace(" ?", "?") + [" ", ""][next() % 2];
            let once = dates(&s);
            changed += usize::from(once != s);
            assert_eq!(dates(&once), once, "{s:?} became {once:?} on the first run");
        }
        assert!(changed > 5_000, "only {changed} of 50000 strings held a date, so the check proves little");
    }
}
