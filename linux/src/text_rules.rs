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

/// Spoken dates become numbers, `DD.MM.YY` or `DD.MM.` without a year, in English and German at once
/// (docs/text-rules.md): "the twenty sixth of July twenty twenty-six" → "26.07.26", "am ersten März" → "am 01.03.".
/// Runs on cleaned text, before the dictionary and snippets. Anything that is not a whole valid date stays.
pub fn dates(text: &str) -> String {
    let w = Words::new(text);
    let (mut out, mut last, mut k) = (String::new(), 0, 0);
    while k < w.at.len() {
        let start = w.at[k].0;
        // A date never starts after a dot: "26.07.26" is numbers already.
        let hit = if text[..start].ends_with('.') { None } else { w.day_first(k).or_else(|| w.month_first(k)) };
        let Some((end, date)) = hit else {
            k += 1;
            continue;
        };
        out.push_str(&text[last..start]);
        out.push_str(&date);
        last = end;
        while k < w.at.len() && w.at[k].0 < end {
            k += 1;
        }
    }
    out + &text[last..]
}

const EN_UNITS: [&str; 9] = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"];
const EN_TEENS: [&str; 10] = ["ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"];
const EN_TENS: [&str; 8] = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"];
const EN_ORDINALS: [&str; 19] = [
    "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "eleventh", "twelfth",
    "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth", "eighteenth", "nineteenth",
];
const DE_UNITS: [&str; 9] = ["ein", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun"];
const DE_TEENS: [&str; 10] = ["zehn", "elf", "zwölf", "dreizehn", "vierzehn", "fünfzehn", "sechzehn", "siebzehn", "achtzehn", "neunzehn"];
const DE_TENS: [&str; 8] = ["zwanzig", "dreißig", "vierzig", "fünfzig", "sechzig", "siebzig", "achtzig", "neunzig"];
const MONTHS: [[&str; 2]; 12] = [
    ["january", "januar"], ["february", "februar"], ["march", "märz"], ["april", "april"], ["may", "mai"], ["june", "juni"],
    ["july", "juli"], ["august", "august"], ["september", "september"], ["october", "oktober"], ["november", "november"],
    ["december", "dezember"],
];

/// `first` plus the place of `w` in `list`.
fn find(list: &[&str], w: &str, first: u32) -> Option<u32> {
    list.iter().position(|&x| x == w).map(|i| first + i as u32)
}

/// Lowercase, with the ASCII spellings of German letters: "Maerz" and "dreissig" are "märz" and "dreißig".
fn fold(w: &str) -> String {
    w.to_lowercase().replace("ae", "ä").replace("oe", "ö").replace("ue", "ü").replace("ss", "ß")
}

/// A German number from 1 to 99, one word: "fünf", "zwölf", "sechsundzwanzig".
fn de_number(w: &str) -> Option<u32> {
    let tens = |t: &str| find(&DE_TENS, t, 2).map(|t| t * 10);
    if w == "eins" {
        return Some(1);
    }
    find(&DE_UNITS, w, 1).or_else(|| find(&DE_TEENS, w, 10)).or_else(|| tens(w)).or_else(|| {
        let (u, t) = w.split_once("und")?;
        Some(find(&DE_UNITS, u, 1)? + tens(t)?)
    })
}

/// A German ordinal, one word with its ending: "erste", "dritten", "sechsundzwanzigster".
fn de_ordinal(w: &str) -> Option<u32> {
    ["er", "en", "es", "em", "e"].iter().find_map(|end| match w.strip_suffix(end)? {
        "erst" => Some(1),
        "dritt" => Some(3),
        "siebt" => Some(7),
        "acht" => Some(8),
        stem => stem.strip_suffix("st").and_then(de_number).filter(|&n| n >= 20)
            .or_else(|| stem.strip_suffix('t').and_then(de_number).filter(|n| (2..20).contains(n))),
    })
}

/// A day in digits, "26" or "26th" (the suffix is not checked), and whether it is bare digits.
fn digit_day(raw: &str) -> Option<(u32, bool)> {
    let n = raw.len() - raw.trim_start_matches(|c: char| c.is_ascii_digit()).len();
    let (digits, suffix) = raw.split_at(n);
    let suffix_ok = suffix.is_empty() || ["st", "nd", "rd", "th"].contains(&suffix.to_ascii_lowercase().as_str());
    ((1..=2).contains(&n) && suffix_ok).then(|| (digits.parse().unwrap(), suffix.is_empty()))
}

/// The words of a text, `is_word` runs, with their folded spelling. A date is matched word by word.
struct Words<'a> {
    text: &'a str,
    at: Vec<(usize, usize)>,
    folded: Vec<String>,
}

impl<'a> Words<'a> {
    fn new(text: &'a str) -> Self {
        let (mut at, mut start) = (Vec::new(), None);
        for (i, c) in text.char_indices().chain([(text.len(), ' ')]) {
            match (start, is_word(c)) {
                (None, true) => start = Some(i),
                (Some(s), false) => {
                    at.push((s, i));
                    start = None;
                }
                _ => {}
            }
        }
        let folded = at.iter().map(|&(s, e)| fold(&text[s..e])).collect();
        Words { text, at, folded }
    }

    fn w(&self, k: usize) -> &str {
        self.folded.get(k).map_or("", String::as_str)
    }

    fn raw(&self, k: usize) -> &str {
        self.at.get(k).map_or("", |&(s, e)| &self.text[s..e])
    }

    /// The text between word k-1 and word k.
    fn gap(&self, k: usize) -> &str {
        if k == 0 || k >= self.at.len() { "" } else { &self.text[self.at[k - 1].1..self.at[k].0] }
    }

    /// The words of one number join with a space or a hyphen: "twenty-six".
    fn join(&self, k: usize) -> bool {
        matches!(self.gap(k), " " | "-")
    }

    fn month(&self, k: usize) -> Option<u32> {
        MONTHS.iter().position(|m| m.contains(&self.w(k))).map(|i| i as u32 + 1)
    }

    /// An English number from 1 to 99 at word k, and the word after it.
    fn en_number(&self, k: usize) -> Option<(u32, usize)> {
        if let Some(t) = find(&EN_TENS, self.w(k), 2) {
            let unit = if self.join(k + 1) { find(&EN_UNITS, self.w(k + 1), 1) } else { None };
            return Some(unit.map_or((t * 10, k + 1), |u| (t * 10 + u, k + 2)));
        }
        find(&EN_UNITS, self.w(k), 1).or_else(|| find(&EN_TEENS, self.w(k), 10)).map(|n| (n, k + 1))
    }

    /// An English ordinal at word k, "fourth" or "twenty-sixth", and the word after it.
    fn en_ordinal(&self, k: usize) -> Option<(u32, usize)> {
        let tens = match self.w(k) {
            "twenty" => 20,
            "thirty" => 30,
            _ => 0,
        };
        if tens > 0 && self.join(k + 1) {
            return find(&EN_ORDINALS[..9], self.w(k + 1), 1).map(|u| (tens + u, k + 2));
        }
        match self.w(k) {
            "twentieth" => Some(20),
            "thirtieth" => Some(30),
            w => find(&EN_ORDINALS, w, 1),
        }
        .map(|n| (n, k + 1))
    }

    /// A year at word k: its last two digits, the full year and the word after it.
    fn year(&self, k: usize) -> Option<(u32, u32, usize)> {
        let (raw, w) = (self.raw(k), self.w(k));
        let digits = !raw.is_empty() && raw.bytes().all(|b| b.is_ascii_digit());
        if digits && raw.len() == 4 {
            let y: u32 = raw.parse().ok()?;
            return Some((y % 100, y, k + 1));
        }
        // twenty twenty-six, nineteen ninety nine, twenty oh nine
        let century = match w {
            "twenty" => 2000,
            "nineteen" => 1900,
            _ => 0,
        };
        if century > 0 && self.join(k + 1) {
            let n = if self.w(k + 1) == "oh" && self.join(k + 2) {
                find(&EN_UNITS, self.w(k + 2), 1).map(|u| (u, k + 3))
            } else {
                self.en_number(k + 1).filter(|&(n, _)| n >= 10)
            };
            if let Some((n, next)) = n {
                return Some((n, century + n, next));
            }
        }
        // two thousand, two thousand five, two thousand and twenty six
        if w == "two" && self.join(k + 1) && self.w(k + 1) == "thousand" {
            let and = self.w(k + 2) == "and" && self.join(k + 2) && self.join(k + 3) && self.en_number(k + 3).is_some();
            let j = k + 2 + usize::from(and);
            let (n, next) = Some(j).filter(|&j| self.join(j)).and_then(|j| self.en_number(j)).unwrap_or((0, k + 2));
            return Some((n, 2000 + n, next));
        }
        // zweitausendsechsundzwanzig, zweitausend sechsundzwanzig, zweitausendundfünf, neunzehnhundertneunundneunzig
        for (head, century) in [("zweitausend", 2000), ("neunzehnhundert", 1900)] {
            let Some(rest) = w.strip_prefix(head) else { continue };
            let space = |j: usize| self.gap(j) == " ";
            let mut tries = vec![(rest.to_string(), k + 1)];
            if (rest.is_empty() || rest == "und") && space(k + 1) {
                tries.insert(0, (format!("{rest}{}", self.w(k + 1)), k + 2));
                if rest.is_empty() && self.w(k + 1) == "und" && space(k + 2) {
                    tries.insert(0, (format!("und{}", self.w(k + 2)), k + 3));
                }
            }
            let tail = |s: &str| if s.is_empty() { Some(0) } else { de_number(s.strip_prefix("und").unwrap_or(s)) };
            return tries.iter().find_map(|(s, next)| tail(s).map(|n| (n, century + n, *next)));
        }
        // A short year needs punctuation or the end after it: in "July fourth twenty six people" it is a count.
        let (n, next) = if digits && raw.len() == 2 {
            (raw.parse().ok()?, k + 1)
        } else {
            self.en_number(k).or_else(|| de_number(w).map(|n| (n, k + 1))).filter(|&(n, _)| n >= 10)?
        };
        let ends = self.text[self.at[next - 1].1..].chars().next().map_or(true, |c| ".,;:!?)".contains(c));
        ends.then_some((n, 2000 + n, next))
    }

    /// The year that may follow word `last` (`,? YEAR`): its two digits, the full year and the word after it.
    fn year_after(&self, last: usize) -> Option<(u32, u32, usize)> {
        if matches!(self.gap(last + 1), " " | ", ") { self.year(last + 1) } else { None }
    }

    /// `[the] DAY [of] MONTH [,] [YEAR]` from word k: the byte where it ends and the date.
    fn day_first(&self, k: usize) -> Option<(usize, String)> {
        let i = if self.w(k) == "the" && self.gap(k + 1) == " " { k + 1 } else { k };
        // In "twenty ninth" the day is 29: "ninth" never starts a day there.
        let after_tens = self.join(i) && matches!(self.w(i - 1), "twenty" | "thirty");
        let (day, bare, i) = match digit_day(self.raw(i)) {
            Some((d, bare)) => (d, bare, i + 1),
            None => {
                let en = if after_tens { None } else { self.en_ordinal(i) };
                let (d, next) = en.or_else(|| de_ordinal(self.w(i)).map(|d| (d, i + 1)))?;
                (d, false, next)
            }
        };
        // "26. Juni": bare digits may take a German dot.
        if !(self.gap(i) == " " || bare && self.gap(i) == ". ") {
            return None;
        }
        let of = self.w(i) == "of" && self.gap(i + 1) == " ";
        let i = i + usize::from(of);
        let month = self.month(i)?;
        let year = self.year_after(i);
        // "Fourth of July" without a year is the holiday's name (docs/text-rules.md, the decision for Pavel).
        if of && year.is_none() && day == 4 && month == 7 {
            return None;
        }
        self.written(year.map_or(i, |y| y.2 - 1), day, month, year)
    }

    /// `MONTH [the] DAY [,] [YEAR]` from word k, with an English or digit day.
    fn month_first(&self, k: usize) -> Option<(usize, String)> {
        let month = self.month(k)?;
        // Before a day only "May" with a capital M is the month: "you may first want to check".
        if self.w(k) == "may" && self.raw(k) != "May" || self.gap(k + 1) != " " {
            return None;
        }
        let i = if self.w(k + 1) == "the" && self.gap(k + 2) == " " { k + 2 } else { k + 1 };
        let (day, next) = match digit_day(self.raw(i)) {
            Some((d, _)) => (d, i + 1),
            None => self.en_ordinal(i)?,
        };
        let year = self.year_after(next - 1);
        self.written(year.map_or(next - 1, |y| y.2 - 1), day, month, year)
    }

    /// The date that ends at word `last`, if that day exists: the byte where it ends and its numbers.
    fn written(&self, last: usize, day: u32, month: u32, year: Option<(u32, u32, usize)>) -> Option<(usize, String)> {
        let leap = |y: u32| y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);
        let days = match month {
            2 if year.is_some_and(|(_, y, _)| !leap(y)) => 28,
            2 => 29,
            4 | 6 | 9 | 11 => 30,
            _ => 31,
        };
        if !(1..=days).contains(&day) {
            return None;
        }
        let end = self.at[last].1;
        Some(match year {
            Some((yy, _, _)) => (end, format!("{day:02}.{month:02}.{yy:02}")),
            // The sentence's "." after "DD.MM." is the date's own dot.
            None => (end + usize::from(self.text[end..].starts_with('.')), format!("{day:02}.{month:02}.")),
        })
    }
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

    // Vectors from #176 (spec changes after the #161 reviews) that this port does not pass yet: #189. Each
    // one must still fail, so the list shrinks as the port catches up, and it goes when it is empty.
    const PENDING: &[&str] = &[
        "Does May July 4th work?",
        "Juli 26.07.2026",
        "March 3-5",
        "Meet on March 5, 10:30.",
        "Am 5. März, 14:30 Uhr",
        "Termin am 3. März, 10.30 Uhr",
        "Am Freitag, den 5. Juni, 14:30 Uhr.",
        "on May 15, 16, and 17.",
        "am sechsundzwanzigsten Juni sechsundzwanzig, also bald",
        "the twenty, sixth of July twenty twenty six",
        "the twenty, first of March",
        "the first of, March",
        "The second may be better.",
        "the first may be fine",
        "Option 2 may work.",
        "Step 3 may fail on Windows.",
        "Chapter 2 may 2026 notes",
        "The first march was long.",
        "MAY 5th",
        "On July 4th two thousand people marched.",
        "On March 3rd 2000 people marched.",
        "am 4. Juli zweitausend Leute",
        "die erste Juli-Woche",
        "the first of May nineteen twenty-first",
        "Mai 26.06.2026",
        "Termin mit August 26.06.26 passt.",
        "Ask June 26.07.26 works.",
        "Tell June May 5th works",
        "Im Juni 1.000 Besucher.",
        "Im März 3,5 Prozent mehr.",
        "In June 1,000 people came.",
        "In May 2,500 users signed up.",
        "In March 3.5 million users joined.",
        "In July 26% of users churned.",
        "June 5-7",
        "July 26/27",
        "am 26. Juni 10:30 Uhr",
        "Am 26. Juni, 14:00 Uhr.",
        "Call me on March 3 10:30 a.m.",
        "am sechs und zwanzigsten Juni",
        "am dreißigsten Juni zweitausend sechs und zwanzig",
        "forty first of March",
        "The first may fail, the second may not.",
        "This is my third September at the company.",
        "My first April in Berlin was cold.",
        "I met Mai 2 weeks ago.",
        "We shipped version 2. March is next.",
        "We need 5. May I ask why?",
        "On March 3 1500 visitors came.",
        "He said \"July 26, 26\".",
        "„Sechsundzwanzigster Juni sechsundzwanzig“",
        "The first of, March.",
        "the 29th of February nineteen hundred",
        "the first of January nineteen hundred.",
        // From the #159 review: #197.
        "the forty ninth of July",
        "the hundred and first of May",
        "the 4th of July 26 people",
        "the thirtieth of February 15 people",
        "Step 2 may take a while.",
        "Option 3 may be better.",
        "The first may be easier than the second.",
        "the second may not work",
        "Call me March 3rd, 10:30.",
        "July 26th 11:00",
        "On July 4th, 15,000 people came.",
        "On July 4th 12.5 percent left.",
        "On May 5th 1200 visitors came.",
        "By March 1st 5000 units shipped.",
        "On July 4th two thousand people came.",
        "On May 5th 1350 visitors came.",
        "the 14th of July 1789",
        "May the fourth be with you.",
        "in week 2 of March we ship",
        "Chapter 3 of May's report",
        "wir hatten 3 März-Termine",
        "the second March sprint",
        "the first July weekend",
        "das erste Mai-Wochenende",
        "the first march was peaceful",
        "In March second-quarter numbers dropped",
        "on June 5, 10, and 15",
    ];

    // Pavel: dates are written as numbers. Every platform passes the same vectors (docs/text-rules.md),
    // so a case added to the file is enforced here without touching this test.
    #[test]
    fn spoken_dates_become_numbers() {
        let cases: Vec<serde_json::Value> = serde_json::from_str(include_str!("../../Tests/fixtures/text-rules/dates.json")).unwrap();
        assert!(cases.len() >= 80, "only {} date vectors", cases.len());
        let mut passing_but_pending = vec![];
        let failed: Vec<String> = cases
            .iter()
            .filter_map(|c| {
                let s = |k: &str| c[k].as_str().unwrap_or_else(|| panic!("{k} missing in {c}"));
                let (once, twice) = (dates(s("input")), dates(s("expected")));
                let fails = once != s("expected") || twice != s("expected");
                if PENDING.contains(&s("input")) {
                    if !fails {
                        passing_but_pending.push(s("input").to_string());
                    }
                    return None;
                }
                fails.then(|| format!("{:?} ({}): want {:?}, got {once:?}, run twice {twice:?}", s("input"), s("note"), s("expected")))
            })
            .collect();
        assert!(failed.is_empty(), "{} of {} date vectors fail:\n{}", failed.len(), cases.len(), failed.join("\n"));
        assert!(passing_but_pending.is_empty(), "these pass now, remove them from PENDING (#189, #197): {passing_but_pending:?}");
    }

    // "Uh-huh" and "mm-hmm" are answers, not fillers.
    #[test]
    fn keeps_hyphenated_answers() {
        assert_eq!(cleanup("Uh-huh, sounds good."), "Uh-huh, sounds good.");
        assert_eq!(cleanup("Mm-hmm, ship it."), "Mm-hmm, ship it.");
    }
}
