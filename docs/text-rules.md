# Text rules: spoken dates become numbers

Pavel's rule (2026-10-21): a spoken date is written as numbers, `DD.MM.YY`, in every language. "Sechsundzwanzigster Juni sechsundzwanzig" becomes `26.06.26`, and "Twenty sixth of July twenty twenty-six" becomes `26.07.26`. This is not the US month/day order.

Feature: F32 (formatting) in docs/parity.md. Test vectors: `Tests/fixtures/text-rules/dates.json`. Mac, Linux and Windows must all pass every case. Follow-ups: #150.

## What the text rules do today

| | Mac | Linux | Windows |
|---|---|---|---|
| Code | `Sources/ShepetalCore/TextRules.swift` | `linux/src/text_rules.rs`, `linux/src/vocab.rs` | `windows/crates/core/src/text.rs` |
| Rules | `Cleanup` (fillers, stutters, spaces), `InsertionRules.fit` (spacing, case and the period next to the cursor) | the same `cleanup`, then the personal dictionary and snippets | the same `cleanup` and `fit` |
| Numbers | none | none | none |

No platform turns number words into digits, in any language. The Mac app does not use FluidAudio's ITN either (`TextNormalizer` is only in `bench/fluid`). Digits appear only when the speech engine writes them.

What the engines write for d03 ("due on March 15th", `bench/results/*.json`):

| Engine | Where | Output |
|---|---|---|
| Parakeet v3, FluidAudio, no ITN | Mac default | `due on march fifteenth,` (lowercase month, spelled day) |
| Parakeet 110M, sherpa-onnx | Linux and Windows, low-end CPU fallback | `due on march fifteenth,` |
| Parakeet v3, FluidAudio with ITN | bench only | `due on march 15,` |
| Parakeet v3 in sherpa-onnx, Whisper in whisper.cpp | Linux and Windows tiers | `due on March 15,` |

So the rule must accept lowercase month names, spelled days and digit days. There is no German clip in the bench yet, so the German forms below are assumed, not measured (#150).

## Where the rule runs

The rule is one function, the text in and the text out. It runs on the cleaned text, after cleanup and before the personal dictionary, snippets and `fit`:

- After cleanup, because cleanup removes fillers and stutters inside the phrase ("the the first of, um, March") and leaves single spaces.
- Before the dictionary and snippets, because text the user stored there is inserted as written. Linux already runs those after cleanup for the same reason.
- Before `fit`, which only changes the edges of the text.

| Platform | Insertion point |
|---|---|
| Mac | `Pipeline.finishText` in `Sources/Shepetal/Pipeline.swift`: the output of `Cleanup.apply` (of `SmartCleanup.apply` once #44 lands) goes through the date rule, then to the `Vocabulary` (#39) and `InsertionRules.fit`. `finishText` also serves re-transcription from the Hub. The rule goes in `ShepetalCore`, next to `Cleanup`. |
| Linux | `transcribe()` in `linux/src/main.rs`, its last line: `vocab.apply(&dates(&cleanup(...)))`. The rule goes in `linux/src/text_rules.rs`. Linux does not call `fit`. |
| Windows | The rule goes in `windows/crates/core/src/text.rs`. Main has no pipeline yet. In PR #80, `windows/crates/app/src/main.rs` passes `shepetal_core::text::cleanup` to `Flow::new`. It must pass a function that runs `cleanup` and then the date rule instead. Windows does not call `fit` (#80 does not read the text around the cursor). |

The history keeps the transcript before any rule in `rawText`, so nothing the rule changes is lost.

`fit` interaction (Mac): `fit` removes the dictation's final `.` when the text after the cursor continues the sentence. When the dictation ends in a `DD.MM.` date, that dot belongs to the date and stays: "on 26.07." pasted before "and then" must stay "on 26.07.", not become "on 26.07".

## Output

- Day, month and year: `DD.MM.YY`. Day and month are zero-padded, and the year is its last two digits: 2026 → `26`, 2005 → `05`, 2000 → `00`, 1999 → `99`.
- Day and month without a year: `DD.MM.` (for example `26.07.`).
- The same format for every language. The rule is not told the language: it knows the English and the German words at the same time. `lang` in the vectors is for people reading them.

## What counts as a date

Words match in any case, with one exception for "May" (below). A hyphen equals a space ("twenty-sixth"). In German words, `ae`, `oe`, `ue` and `ss` equal `ä`, `ö`, `ü` and `ß`.

**Month**: the full name. English: January to December. German: Januar, Februar, März, April, Mai, Juni, Juli, August, September, Oktober, November, Dezember.

**Day**, 1 to 31:

| Form | Examples |
|---|---|
| Digits | `26`, `1` |
| Digits with an English ordinal suffix (st, nd, rd, th; the suffix is not checked) | `26th`, `1st`, `3rd` |
| Digits with a German dot | `26.`, `1.` |
| English ordinal words | first ... nineteenth, twentieth, twenty first ... twenty ninth, thirtieth, thirty first |
| German ordinal words, one word, ending in -e, -er, -en, -es or -em | erste, zweiter, dritten, vierten, fünften, sechsten, siebten or siebenten, achten, neunten, zehnten, elften, zwölften, dreizehnten ... neunzehnten, zwanzigsten, einundzwanzigsten ... neunundzwanzigsten, dreißigsten, einunddreißigsten |

A spelled day is the whole number: in "twenty ninth" the day is 29, and "ninth" alone never matches inside it. English and German cardinal words ("twenty six", "sechsundzwanzig") are never a day.

**Year**, optional, right after the month (a comma between them is allowed):

| Form | Examples | YY |
|---|---|---|
| Four digits | `2026`, `1999` | `26`, `99` |
| English: twenty or nineteen, then a number from 10 to 99, or "oh" and a digit | twenty twenty-six, nineteen ninety nine, twenty oh nine | `26`, `99`, `09` |
| English: two thousand, optionally "and" and a number from 1 to 99 | two thousand, two thousand five, two thousand and twenty six | `00`, `05`, `26` |
| German: zweitausend or neunzehnhundert, optionally "und" and a number from 1 to 99, as one word or two | zweitausendsechsundzwanzig, zweitausend sechsundzwanzig, zweitausendundfünf, neunzehnhundertneunundneunzig | `26`, `26`, `05`, `99` |
| A short year: two digits, or a number word from 10 to 99, only when punctuation (`. , ; : ! ? )`) or the end of the text follows | `26`, twenty six, sechsundzwanzig | `26` |

The short year needs the punctuation because "On July fourth twenty six people came" is a count, not a year: it becomes "On 04.07. twenty six people came".

**Word order**:

- Day first: `[the] DAY [of] MONTH [,] [YEAR]`. Examples: "the twenty sixth of July twenty twenty-six", "26 July 2026", "26th July", "sechsundzwanzigster Juni sechsundzwanzig", "26. Juni 2026", "erster März".
- Month first: `MONTH [the] DAY [,] [YEAR]`, with an English or digit day. Examples: "July twenty sixth, twenty twenty six", "July 26th 2026", "July 26, 2026", "March 1st", "July the fourth".

**"May"**: before a day (month first), only "May" with a capital M is the month. "You may first want to check" stays. After "of" or a day, any case is the month: "the fifth of may" → `05.05.`.

## The words and punctuation around a date

- English "the" before the day and "of" between day and month are part of the date and go: "on the twenty sixth of July" → "on 26.07.", "July the fourth" → "04.07.".
- Everything else stays: "on", "by", "am", "den", "der", "bis zum", and weekdays. "Monday, the 26th of July" → "Monday, 26.07.", "Montag, den 26. Juli" → "Montag, den 26.07.".
- A comma between day and year goes. A comma after the date stays: "July 26, 2026, at noon" → "26.07.26, at noon".
- Punctuation after the date stays, with one merge: a `.` right after a `DD.MM.` date is the same dot, so "on the first of March." → "on 01.03.", not "01.03..". After `DD.MM.YY` the period stays: "26.07.26.". `?`, `!` and `,` stay after either form: "on 04.03.?".

## Left unchanged

- **Invalid dates**: a day past the month's end, as a whole phrase ("the 31st of February", "February thirtieth", "am 31. April 2026"). 29 February needs a leap year when a year is given; without a year it is accepted.
- **Dates that are already numbers**: "26.07.26", "26.07.2026", "2026-07-26", "07/26/2026". Running the rule twice changes nothing.
- **No day, or no month**: "in July", "July 2026", "Juli 2026", "the 26th was busy", "the first of many", "first of all", "the second time", "one second", "wait a second", "a quarter past three", "twenty six people", "sechsundzwanzig Leute", "der erste Versuch", "zum dritten Mal".
- **Verbs that are month names**: "May I ask", "I march on", "we march forward".

## Decision for Pavel: "Fourth of July"

Recommended: **"Fourth of July" without a year stays in words.** The rule is narrow. It covers day 4, July, day-first order with "of" and no year: "Happy Fourth of July!", "the 4th of July parade". It does not cover these:

- With a year it is a date: "the Fourth of July twenty twenty-six" → `04.07.26`.
- Month first is a date: "July fourth", "July 4th" → `04.07.`.
- German has no such phrase: "am vierten Juli" → "am 04.07.".

Why: without a year the phrase is almost always the holiday's name, and nobody writes "Happy 04.07.!". Changing a name is a wrong edit. Leaving a date in words loses nothing, because the reader still sees the date. Only this one phrase gets the exception. Other English holidays are not date phrases (Christmas, Thanksgiving). German holidays such as "am ersten Mai" and "der 3. Oktober" are normally written as numbers in German, so they convert.

The other choice is to convert it like any date. That is one rule less. If Pavel picks that, the two vectors whose note says "(decision)" change to "Happy 04.07.!" and "04.07. parade".

## Known limits

These follow from the rules above. They are accepted because the alternative breaks the most common real form ("March 15").

- A bare number right after a month name is a day: "in July 26 people came" → "in 26.07. people came". Engines usually write a comma there ("In July, 26 people").
- Lowercase "march" before a day is the month: "we march 2 miles" → "we 02.03. miles". Parakeet writes the month in lowercase ("march fifteenth"), so lowercase must count.
- A short spoken year in the middle of a sentence without a comma stays in words: "am sechsundzwanzigsten Juni sechsundzwanzig haben wir" → "am 26.06. sechsundzwanzig haben wir".

## Not covered yet (#150)

- **Slovenian.** No platform's rules know Slovenian number words (or any number words), so "šestindvajsetega julija dva tisoč šestindvajset" stays as spoken.
- German ordinal months ("am ersten dritten").
- Ranges ("vom ersten bis dritten März").
- Abbreviated months ("Sept.").
- Austrian "Jänner".
- Spelled years outside 1900 to 2099.
- A German bench clip.

## Test vectors

`Tests/fixtures/text-rules/dates.json` is a JSON array, UTF-8. Write `Tests` with a capital T. On macOS, `tests/` is the same folder, but on Linux it is a different one. SwiftPM ignores `Tests/fixtures`, because it is not a test target. Each case has exactly four string fields:

```json
{"input": "on the twenty sixth of July", "expected": "on 26.07.", "lang": "en", "note": "'on' stays, 'the' and 'of' go"}
```

- `input` is the cleaned text (after cleanup), and `expected` is the date rule's output. A case where they are equal must stay unchanged.
- Each suite asserts `dates(input) == expected` and `dates(expected) == expected` (running the rule twice changes nothing) for every case. It reports the failing `input` and `note`, and it fails when the file is missing or holds fewer than 80 cases.
- A case is changed or added here, in the file, not in one platform's tests.

Reading the file from each suite:

- **Mac**: `URL(fileURLWithPath: #filePath)` up to the repo root, as `ShepetalSummaryTests` reads `python_golden.json`. Decode it with `JSONDecoder`.
- **Linux**: `include_str!("../../Tests/fixtures/text-rules/dates.json")` from `linux/src`, with `serde_json` (already a dependency). The Linux Docker commands (`scripts/ci/run-checks.sh`, `linux/README.md`, `linux/indicator/check.sh`) mount the repo root and work in `linux/`, so the file is in the container.
- **Windows**: `include_str!("../../../../Tests/fixtures/text-rules/dates.json")` from `windows/crates/core/src`. The core crate has no dependencies, so add `serde_json` as a dev-dependency.
