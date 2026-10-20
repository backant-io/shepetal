//! Personal dictionary and snippets, as on the Mac (docs/re/text-pipeline.md §2.6, §4).
//!
//! `~/.config/shepetal/dictionary.txt`, one entry per line, the Mac's format:
//!   `GitHub`             a word or phrase: biases the model and fixes its casing in the text
//!   `btw => by the way`  a replacement
//!   `*Shepetal`          a leading `*` stars an entry: starred entries go first in the model hint
//!   `# ...`              a comment
//! `~/.config/shepetal/snippets.toml`, one `"trigger" = "expansion"` pair per line (TOML).
//! Both files are owner-only (0600) and re-read on every dictation.

use std::io::Write;
use std::path::{Path, PathBuf};

/// At most this many entries go to the model as a hint (Wispr sends at most 200).
pub const PROMPT_LIMIT: usize = 200;

#[derive(Debug, Clone, PartialEq)]
pub struct Entry {
    /// What to find: case-insensitive, whole words, any run of spaces between words.
    pub spoken: String,
    /// What goes in its place.
    pub written: String,
    pub starred: bool,
}

impl Entry {
    pub fn parse(line: &str) -> Option<Entry> {
        let mut s = line.trim();
        if s.is_empty() || s.starts_with('#') {
            return None;
        }
        let starred = s.starts_with('*');
        if starred {
            s = s[1..].trim();
        }
        let (spoken, written) = match s.split_once("=>") {
            Some((a, b)) => (a.trim(), b.trim()),
            None => (s, s),
        };
        (!spoken.is_empty() && !written.is_empty())
            .then(|| Entry { spoken: spoken.into(), written: written.into(), starred })
    }

    fn is_replacement(&self) -> bool {
        self.spoken != self.written
    }
}

#[derive(Debug, Default, Clone, PartialEq)]
pub struct Vocab {
    pub dictionary: Vec<Entry>,
    /// (trigger, expansion) in file order.
    pub snippets: Vec<(String, String)>,
}

impl Vocab {
    pub fn parse(dictionary: &str, snippets: &str) -> Vocab {
        Vocab {
            dictionary: dictionary.lines().filter_map(Entry::parse).collect(),
            snippets: parse_snippets(snippets),
        }
    }

    /// Both files from `dir`; a missing file is empty. Files found are made 0600 again.
    pub fn load(dir: &Path) -> Vocab {
        let read = |name: &str| {
            let p = dir.join(name);
            let s = std::fs::read_to_string(&p).unwrap_or_default();
            if !s.is_empty() {
                use std::os::unix::fs::PermissionsExt;
                let _ = std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o600));
            }
            s
        };
        Vocab::parse(&read(DICTIONARY), &read(SNIPPETS))
    }

    /// The hint for Whisper's initial prompt: the spoken side (what the model has to hear),
    /// starred first, then file order, at most PROMPT_LIMIT. None when the dictionary is empty.
    pub fn prompt(&self) -> Option<String> {
        let d = &self.dictionary;
        let terms: Vec<&str> = d.iter().filter(|e| e.starred).chain(d.iter().filter(|e| !e.starred))
            .map(|e| e.spoken.as_str()).take(PROMPT_LIMIT).collect();
        (!terms.is_empty()).then(|| terms.join(", "))
    }

    /// The text after transcription. A dictation that is only a snippet trigger (punctuation
    /// and case ignored) becomes its expansion. Otherwise snippet triggers and dictionary
    /// entries are replaced inline in one pass: case-insensitive, whole words only, longest
    /// first, and nothing inserted is replaced again.
    pub fn apply(&self, text: &str) -> String {
        let whole = normalize(text);
        if !whole.is_empty() {
            if let Some((_, x)) = self.snippets.iter().find(|(t, _)| normalize(t) == whole) {
                return x.clone();
            }
        }
        // Snippets before dictionary entries of the same length (the sort is stable).
        let mut rules: Vec<(Vec<Vec<char>>, &str, bool)> = self.snippets.iter()
            .map(|(t, x)| (words(t), x.as_str(), false))
            .chain(self.dictionary.iter().map(|e| (words(&e.spoken), e.written.as_str(), e.is_replacement())))
            .filter(|(w, _, _)| !w.is_empty())
            .collect();
        if rules.is_empty() {
            return text.to_string();
        }
        rules.sort_by_key(|(w, _, _)| std::cmp::Reverse(w.iter().map(Vec::len).sum::<usize>() + w.len()));
        let chars: Vec<char> = text.chars().collect();
        let mut out = String::with_capacity(text.len());
        let mut i = 0;
        while i < chars.len() {
            let at_start = i == 0 || !is_word(chars[i - 1]);
            let hit = at_start.then(|| rules.iter().find_map(|(w, x, rep)| match_at(&chars, i, w).map(|end| (end, *x, *rep)))).flatten();
            match hit {
                Some((end, written, rep)) => {
                    // A replacement at the start of a sentence keeps its capital ("Btw" -> "By the way").
                    let mut cs = written.chars();
                    match cs.next() {
                        Some(f) if rep && chars[i].is_uppercase() && f.is_lowercase() => {
                            out.extend(f.to_uppercase());
                            out.extend(cs);
                        }
                        _ => out.push_str(written),
                    }
                    i = end;
                }
                None => {
                    out.push(chars[i]);
                    i += 1;
                }
            }
        }
        out
    }
}

pub const DICTIONARY: &str = "dictionary.txt";
pub const SNIPPETS: &str = "snippets.toml";

fn is_word(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

fn words(s: &str) -> Vec<Vec<char>> {
    s.split_whitespace().map(|w| w.chars().collect()).collect()
}

fn same(a: char, b: char) -> bool {
    a == b || a.to_lowercase().eq(b.to_lowercase())
}

/// Where the phrase `w` matching at `i` ends, if it does and is not followed by a word char.
fn match_at(text: &[char], mut i: usize, w: &[Vec<char>]) -> Option<usize> {
    for (n, word) in w.iter().enumerate() {
        if n > 0 {
            let ws = text[i..].iter().take_while(|c| c.is_whitespace()).count();
            if ws == 0 {
                return None;
            }
            i += ws;
        }
        if text.len() < i + word.len() || !word.iter().zip(&text[i..]).all(|(&a, &b)| same(a, b)) {
            return None;
        }
        i += word.len();
    }
    (i == text.len() || !is_word(text[i])).then_some(i)
}

/// Lowercase words with punctuation dropped: "My address." and "my  address" are equal.
fn normalize(s: &str) -> String {
    let kept: String = s.chars().map(|c| if is_word(c) { c } else { ' ' }).flat_map(char::to_lowercase).collect();
    kept.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// `"trigger" = "expansion"` lines: TOML basic strings on both sides. Other lines are ignored.
pub fn parse_snippets(s: &str) -> Vec<(String, String)> {
    s.lines().filter_map(|l| {
        let l = l.trim();
        let (k, rest) = toml_str(l.strip_prefix('"')?)?;
        let rest = rest.trim_start().strip_prefix('=')?.trim_start().strip_prefix('"')?;
        let (v, tail) = toml_str(rest)?;
        let tail = tail.trim();
        (tail.is_empty() || tail.starts_with('#')).then_some((k, v)).filter(|(k, _)| !k.trim().is_empty())
    }).collect()
}

/// Reads a basic string body up to its closing quote: (value, rest after the quote).
fn toml_str(s: &str) -> Option<(String, &str)> {
    let mut out = String::new();
    let mut it = s.char_indices();
    while let Some((i, c)) = it.next() {
        match c {
            '"' => return Some((out, &s[i + 1..])),
            '\\' => out.push(match it.next()?.1 {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '"' => '"',
                '\\' => '\\',
                'u' => {
                    let hex: String = (0..4).map(|_| it.next().map(|x| x.1)).collect::<Option<_>>()?;
                    char::from_u32(u32::from_str_radix(&hex, 16).ok()?)?
                }
                _ => return None,
            }),
            c if (c as u32) < 0x20 => return None,
            c => out.push(c),
        }
    }
    None
}

fn toml_quote(s: &str) -> String {
    let mut out = String::from('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            c if (c as u32) < 0x20 || c == '\u{7f}' => out.push_str(&format!("\\u{:04X}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// `$XDG_CONFIG_HOME/shepetal`, or `~/.config/shepetal` when it is unset, empty or relative.
pub fn config_dir(xdg: Option<&str>, home: &str) -> PathBuf {
    match xdg {
        Some(d) if d.starts_with('/') => PathBuf::from(d).join("shepetal"),
        _ => PathBuf::from(home).join(".config/shepetal"),
    }
}

pub fn default_dir() -> PathBuf {
    config_dir(std::env::var("XDG_CONFIG_HOME").ok().as_deref(), &std::env::var("HOME").unwrap_or_default())
}

/// Replaces `dir/name` with `body` through an owner-only temp file and a rename, so the file
/// is 0600 from its first byte and a crash never leaves it half written.
pub fn save(dir: &Path, name: &str, body: &str) -> std::io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    let tmp = dir.join(format!(".{name}.{}", std::process::id()));
    let _ = std::fs::remove_file(&tmp);
    let mut f = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&tmp)?;
    f.write_all(body.as_bytes())?;
    f.sync_all()?;
    std::fs::rename(&tmp, dir.join(name))
}

const DICT_HEADER: &str = "# shepetal personal dictionary. One entry per line; changes apply on your next dictation.\n\
#   Kubernetes          a word or phrase, written with exactly this spelling and casing\n\
#   spoken => written   what you say on the left is replaced with the text on the right\n\
#   *Shepetal           a leading * stars an entry: starred entries go first in the hint to the model\n";

const SNIPPET_HEADER: &str = "# shepetal snippets: \"spoken trigger\" = \"text it expands to\"\n";

fn eq_ci(a: &str, b: &str) -> bool {
    words(a).len() == words(b).len() && normalize_spaces(a).to_lowercase() == normalize_spaces(b).to_lowercase()
}

fn normalize_spaces(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// `shepetal dict add|remove|list` and `shepetal snippet add|remove|list`, on files in `dir`.
/// Returns what to print.
pub fn cli(dir: &Path, args: &[String]) -> Result<String, String> {
    let rest = args.get(2..).unwrap_or_default().join(" ");
    let io = |e: std::io::Error| format!("{}: {e}", dir.display());
    let read = |name: &str| std::fs::read_to_string(dir.join(name)).unwrap_or_default();
    match (args.first().map(String::as_str), args.get(1).map(String::as_str)) {
        (Some("dict"), Some("list")) => {
            let v = Vocab::parse(&read(DICTIONARY), "");
            Ok(v.dictionary.iter().map(|e| {
                let star = if e.starred { "*" } else { "" };
                if e.is_replacement() { format!("{star}{} => {}\n", e.spoken, e.written) } else { format!("{star}{}\n", e.spoken) }
            }).collect())
        }
        (Some("dict"), Some("add")) => {
            let e = Entry::parse(&rest).filter(|_| !rest.trim_start().starts_with('#'))
                .ok_or("usage: shepetal dict add WORD | 'SPOKEN => WRITTEN' (a leading * stars it)")?;
            let old = read(DICTIONARY);
            let mut body = if old.is_empty() { DICT_HEADER.to_string() } else { without_entry(&old, &e.spoken) };
            if !body.is_empty() && !body.ends_with('\n') {
                body.push('\n');
            }
            body.push_str(rest.trim());
            body.push('\n');
            save(dir, DICTIONARY, &body).map_err(io)?;
            Ok(format!("added {}\n", rest.trim()))
        }
        (Some("dict"), Some("remove")) if !rest.trim().is_empty() => {
            let old = read(DICTIONARY);
            let body = without_entry(&old, rest.trim_start_matches('*'));
            if body == old {
                return Err(format!("not in the dictionary: {}", rest.trim()));
            }
            save(dir, DICTIONARY, &body).map_err(io)?;
            Ok(format!("removed {}\n", rest.trim()))
        }
        (Some("snippet"), Some("list")) => {
            Ok(parse_snippets(&read(SNIPPETS)).iter().map(|(t, x)| format!("{t} => {}\n", x.replace('\n', "\\n"))).collect())
        }
        (Some("snippet"), Some("add")) if args.len() >= 4 && !args[2].trim().is_empty() => {
            let (trigger, text) = (normalize_spaces(&args[2]), args[3..].join(" "));
            let mut s: Vec<_> = parse_snippets(&read(SNIPPETS)).into_iter().filter(|(t, _)| !eq_ci(t, &trigger)).collect();
            s.push((trigger.clone(), text));
            save(dir, SNIPPETS, &snippets_file(&s)).map_err(io)?;
            Ok(format!("added snippet {trigger}\n"))
        }
        (Some("snippet"), Some("remove")) if !rest.trim().is_empty() => {
            let all = parse_snippets(&read(SNIPPETS));
            let s: Vec<_> = all.iter().filter(|(t, _)| !eq_ci(t, &rest)).cloned().collect();
            if s.len() == all.len() {
                return Err(format!("no snippet for: {}", rest.trim()));
            }
            save(dir, SNIPPETS, &snippets_file(&s)).map_err(io)?;
            Ok(format!("removed snippet {}\n", rest.trim()))
        }
        _ => Err("usage: shepetal dict add|remove|list [ENTRY] | shepetal snippet add TRIGGER TEXT | snippet remove TRIGGER | snippet list".into()),
    }
}

/// The dictionary file without lines whose entry is `spoken` (case-insensitive); comments stay.
fn without_entry(file: &str, spoken: &str) -> String {
    file.lines().filter(|l| Entry::parse(l).is_none_or(|e| !eq_ci(&e.spoken, spoken)))
        .map(|l| format!("{l}\n")).collect()
}

fn snippets_file(s: &[(String, String)]) -> String {
    let mut out = SNIPPET_HEADER.to_string();
    for (t, x) in s {
        out.push_str(&format!("{} = {}\n", toml_quote(t), toml_quote(x)));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(dict: &str, snippets: &[(&str, &str)]) -> Vocab {
        let s: String = snippets.iter().map(|(t, x)| format!("{} = {}\n", toml_quote(t), toml_quote(x))).collect();
        Vocab::parse(dict, &s)
    }

    #[test]
    fn dictionary_fixes_casing_whole_words_only() {
        let d = v("GitHub\nKubernetes\n", &[]);
        assert_eq!(d.apply("push to github and kubernetes."), "push to GitHub and Kubernetes.");
        assert_eq!(d.apply("GITHUB, Github; github!"), "GitHub, GitHub; GitHub!");
        // Inside a longer word nothing changes.
        assert_eq!(d.apply("githubber mygithub github_x"), "githubber mygithub github_x");
    }

    #[test]
    fn replacement_keeps_a_sentence_capital() {
        let d = v("btw => by the way\n", &[]);
        assert_eq!(d.apply("btw, it works"), "by the way, it works");
        assert_eq!(d.apply("It works. Btw it's fast"), "It works. By the way it's fast");
        assert_eq!(d.apply("BTW!"), "By the way!");
        assert_eq!(d.apply("btwx and xbtw"), "btwx and xbtw", "a trigger inside a word must not fire");
    }

    #[test]
    fn whole_dictation_snippet_ignores_case_and_punctuation() {
        let d = v("", &[("my address", "221B Baker Street\nLondon")]);
        assert_eq!(d.apply("My address."), "221B Baker Street\nLondon");
        assert_eq!(d.apply("  my,   ADDRESS!? "), "221B Baker Street\nLondon");
        assert_eq!(d.apply("my addresses"), "my addresses");
    }

    #[test]
    fn inline_snippet_expands_inside_a_sentence() {
        let d = v("", &[("my address", "221B Baker Street")]);
        assert_eq!(d.apply("Send it to my address, please."), "Send it to 221B Baker Street, please.");
        assert_eq!(d.apply("Send it to My  Address."), "Send it to 221B Baker Street.");
        assert_eq!(d.apply("Send it to my addressbook."), "Send it to my addressbook.", "inside a word");
        assert_eq!(d.apply("to amy address"), "to amy address", "inside a word on the left");
        assert_eq!(d.apply("my\naddress"), "221B Baker Street", "any whitespace between words");
    }

    #[test]
    fn longest_first_and_never_replaced_again() {
        let d = v("new york => NYC\nnew york city => New York City\nNYC => wrong\n", &[]);
        assert_eq!(d.apply("in new york city and new york"), "in New York City and NYC");
        let s = v("sig => sig sig\n", &[]);
        assert_eq!(s.apply("sig"), "sig sig", "the inserted text is not scanned again");
    }

    #[test]
    fn unicode_words_and_boundaries() {
        let d = v("Zürich\nÅngström\nстрасть => Страсть\n", &[("эл почта", "me@example.org")]);
        assert_eq!(d.apply("zürich ZÜRICH ångström"), "Zürich Zürich Ångström");
        assert_eq!(d.apply("zürichsee"), "zürichsee", "a non-ASCII letter after the trigger is a word char");
        assert_eq!(d.apply("äzürich"), "äzürich", "a non-ASCII letter before it too");
        assert_eq!(d.apply("моя эл почта"), "моя me@example.org");
        assert_eq!(d.apply("Эл почта."), "me@example.org");
        assert_eq!(d.apply("СТРАСТЬ"), "Страсть");
    }

    #[test]
    fn prompt_puts_starred_first_and_is_capped() {
        let d = v("# c\nalpha\n*Shepetal\nbtw => by the way\n", &[("sig", "x")]);
        assert_eq!(d.prompt().as_deref(), Some("Shepetal, alpha, btw"));
        assert_eq!(Vocab::default().prompt(), None);
        let many: String = (0..300).map(|n| format!("w{n}\n")).collect();
        assert_eq!(v(&many, &[]).prompt().unwrap().split(", ").count(), PROMPT_LIMIT);
    }

    #[test]
    fn dictionary_lines() {
        assert_eq!(Entry::parse("  # x"), None);
        assert_eq!(Entry::parse("=> x"), None);
        assert_eq!(Entry::parse("*  gh => GitHub "), Some(Entry { spoken: "gh".into(), written: "GitHub".into(), starred: true }));
    }

    #[test]
    fn snippets_toml_round_trips() {
        let s = vec![("a \"b\"".to_string(), "line1\nline2\t\\ é 🤫 \u{1}".to_string())];
        assert_eq!(parse_snippets(&snippets_file(&s)), s);
        assert_eq!(parse_snippets("\"x\" = \"\\u00e9\" # c\n\"\" = \"y\"\nbad\n\"k\" = \"v\" junk"), vec![("x".into(), "é".into())]);
    }

    #[test]
    fn config_dir_follows_xdg() {
        assert_eq!(config_dir(Some("/c"), "/h"), PathBuf::from("/c/shepetal"));
        assert_eq!(config_dir(Some("rel"), "/h"), PathBuf::from("/h/.config/shepetal"));
        assert_eq!(config_dir(None, "/h"), PathBuf::from("/h/.config/shepetal"));
    }

    #[test]
    fn cli_edits_owner_only_files() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("shepetal-vocab-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let run = |a: &[&str]| cli(&dir, &a.iter().map(|s| s.to_string()).collect::<Vec<_>>());
        run(&["dict", "add", "GitHub"]).unwrap();
        run(&["dict", "add", "btw", "=>", "by", "the", "way"]).unwrap();
        run(&["dict", "add", "github"]).unwrap();
        assert_eq!(run(&["dict", "list"]).unwrap(), "btw => by the way\ngithub\n", "re-adding replaces");
        run(&["dict", "remove", "BTW"]).unwrap();
        assert!(run(&["dict", "remove", "nope"]).is_err());
        assert_eq!(run(&["dict", "list"]).unwrap(), "github\n");
        assert!(std::fs::read_to_string(dir.join(DICTIONARY)).unwrap().starts_with("# shepetal"), "comments kept");

        run(&["snippet", "add", "my  address", "221B\nBaker \"St\""]).unwrap();
        run(&["snippet", "add", "sig", "Pavel"]).unwrap();
        run(&["snippet", "add", "SIG", "Pavel H"]).unwrap();
        assert_eq!(run(&["snippet", "list"]).unwrap(), "my address => 221B\\nBaker \"St\"\nSIG => Pavel H\n");
        let loaded = Vocab::load(&dir);
        assert_eq!(loaded.apply("My address!"), "221B\nBaker \"St\"");
        assert_eq!(loaded.apply("github sig"), "github Pavel H", "dictionary written as typed");
        run(&["snippet", "remove", "sig"]).unwrap();
        assert!(run(&["snippet", "remove", "sig"]).is_err());
        assert!(run(&["snippet", "add", "only-trigger"]).is_err());
        assert!(run(&["dict", "frob"]).is_err());

        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&dir.join(DICTIONARY)), 0o600);
        assert_eq!(mode(&dir.join(SNIPPETS)), 0o600);
        assert_eq!(mode(&dir), 0o700);
        std::fs::set_permissions(dir.join(DICTIONARY), std::fs::Permissions::from_mode(0o644)).unwrap();
        Vocab::load(&dir);
        assert_eq!(mode(&dir.join(DICTIONARY)), 0o600, "load makes a loosened file owner-only again");
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
