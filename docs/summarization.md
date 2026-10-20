# Meeting summarization

Shepetal turns a speaker-labelled transcript into four sections: **Overview**, **Key points**, **Decisions**
and **Action items (owner, task, due)**. It runs fully on the device and uses no decoder-only chat LLM.

Code: `summarize/summarize.py`. Fixtures and reference summaries: `summarize/fixtures/`. Sample outputs: `summarize/out/`.
Real-meeting checks: `summarize/eval_qmsum.py` (summaries) and `summarize/ami_actions.py` (action items). Action-item
model: `summarize/actions_model.json`. Tests: `summarize/test_summarize.py`.

## Next-Concept Modeling (NCM): what it is and where it stands

NCM (Hazy Research, Oct 2026; [blog](https://hazyresearch.stanford.edu/blog/2026-10-12-ncm),
[code](https://github.com/HazyResearch/ncm), arXiv 2610.14162) is a two-stage, non-autoregressive generator.
A multiscale residual VQ tokenizer turns a sequence into 9 levels of discrete codes (4 to 48 positions). A
transformer predicts the levels from coarse to fine. Each level is predicted in parallel, so the model needs one
forward pass per level instead of one per token. It is not an LLM in the chat/instruct sense. The authors report
that it matches the strongest diffusion baseline's ROUGE-L on XSum while running 31x faster. The ROUGE number is
only shown in a figure, and the speed was measured on one H100.

Checked on 2026-10-20:

| Question | Answer |
|---|---|
| Weights released? | Yes, [hazyresearch/ncm-checkpoints](https://huggingface.co/hazyresearch/ncm-checkpoints) |
| License | MIT (code and checkpoints) |
| Summarization checkpoint | Yes, `xsum/`: generator.pt 354 MB + tokenizer.pt 300 MB. Generator: 12 layers, 768 dim (GPT-2-small scale). Tokenizer: 6-layer VQ-VAE, 384 dim |
| Input / output limits | 512 GPT-2 tokens of input, **48 tokens of output** (one XSum-style sentence) |
| Other checkpoints | LM1B small/medium/large (97M/317M/725M), TinyStories, WMT14 De-En, Sudoku. OpenWebText is listed but marked TODO |
| Apple Silicon / CPU | Not supported as shipped. `scripts/eval_shard.py` calls `.cuda()` directly and the README asks for CUDA. The model code is plain PyTorch, so a CPU/MPS port looks like a device-string change, but nobody has tested it |
| ONNX / CoreML | None. You would have to export the VQ-VAE decoder and the generator yourself. The per-level sampling loop has to stay in host code |
| Safety | Checkpoints are pickles loaded with `weights_only=False`, so loading one can run code. Convert them to safetensors once, in a sandbox, before shipping |

**Is it a meeting summarizer?** Not yet. The only summarization checkpoint is trained on XSum news articles to
write one sentence of at most 48 tokens. It cannot produce key points, decisions or action items. To use it, we
would have to fine-tune it on meeting data (AMI, ICSI, QMSum, MeetingBank) with a longer output length, which
also means retraining the tokenizer levels. Even then it would only write the Overview line, chunk by chunk.

**Not measured here.** The XSum checkpoint download (654 MB) ran at about 0.3 MB/s on the shared sprint network, so
I stopped it. NCM latency and RAM on the M4 Pro are unmeasured.

**Other 2026 non-LLM text-generation families.** I found no model family that calls itself "procedural". The
closest 2026 work: shortcut flow matching for one-step non-autoregressive NLG (ACL 2026 short, no meeting
checkpoint) and the xLM package for non-autoregressive LMs (EACL 2026 demo, a library, not a model). Neither is a
better fit than NCM.

## Approaches compared

1. **Extractive TextRank + rules (deterministic).** Sentences are ranked with PageRank over cosine similarity.
   Sentence vectors come from either TF-IDF (no model at all) or MiniLM-L6 mean-pooled embeddings (22M-param
   encoder, 90 MB). Decisions come from keyword rules (`Decision:`, `we move/keep/ship/offer`, `postponed`...).
   Action items come from a logistic-regression classifier trained on AMI, plus rules for the owner and the due
   date (see "Action items with owners" below). Until this change they were first-person commitments only
   (`I'll` / `I will` + clause, owner = speaker), which found 4 to 7% of real action items.
2. **Encoder-decoder seq2seq (BART-large-CNN, PEGASUS, LED / LongT5, distilBART).** These are abstractive
   summarizers with a bidirectional encoder. They are not decoder-only chat LLMs, and they do not follow
   instructions. Wired up in the harness (`summarize.py seq2seq <hf-id>`), but **not measured**: the cheapest useful
   checkpoint (t5-small, 242 MB) would not download within the sprint. Expect BART-large-CNN at around 1.6 GB on
   disk and 1 to 3 s per 1k-token chunk on M-series CPU (not measured here). Its output is news-style prose, so
   decisions and action items would still come from the rules.
3. **NCM**: see above. Not runnable on this machine as shipped.

## Self-written fixtures (M4 Pro, 24 GB, CPU, 3 synthetic meetings of 480 to 690 words, about 4 to 5 min of speech each)

ROUGE F1 is computed on the whole four-section output against the hand-written reference, using lowercase words
without stemming. Latency is per meeting after the model has loaded. Peak RAM is the process max RSS.

| Approach | ROUGE-1 | ROUGE-2 | ROUGE-L | Latency / meeting | Model load | Peak RSS |
|---|---|---|---|---|---|---|
| textrank-tfidf + rules | 0.654 | 0.432 | 0.444 | 19-25 ms (varies with machine load) | 0 s | 31 MB |
| textrank-minilm + rules | 0.635 | 0.426 | 0.467 | 89-102 ms | 3.2-4.6 s (mostly torch import) | 577-596 MB (PyTorch runtime; the model is 90 MB) |

Decisions and action items come from the same code in both rows. Only the Overview and Key points differ, and on
these fixtures the two rankers are a tie: TF-IDF is slightly ahead on ROUGE-1, MiniLM slightly ahead on ROUGE-L.

**Manual check (textrank-tfidf, see `summarize/out/`):**
- Action items: 15 of the 16 reference items are found with the right owner and due date. The miss is "Maya:
  update the roadmap and tell the support team": it has no date, and the classifier scores it 0.09. There is one
  false item, a decision read as a task ("Tom: The release moves to the 4th"). Weak spots: pronoun tasks ("Tom:
  open it"). Most fixture items are clean "I'll X by Friday" lines, which AMI rarely has, so the dated
  first-person rule finds most of them, not the classifier.
- Decisions: most were found, but sentences phrased as a plan ("So the plan is the fix goes into 2.4") fall into
  Key points, and recap sentences sometimes repeat a decision.
- MiniLM picked a better Overview for fixture 1 ("This is the weekly release sync for version 2.4.") where TF-IDF
  picked the agenda sentence, which is the one quality gain from embeddings that we saw.
- The Overview is a sentence copied from the transcript, so it reads as speech ("We have about ten minutes, so
  I'd like to cover ..."). An abstractive model would help most here.
- These rules were written against these same three fixtures, so the scores are optimistic. The next section
  shows how optimistic: on real meetings the old first-person action-item rule drops from 100% to about 5%.

## Real meetings: QMSum and AMI

The fixtures above are self-written, and the rules were tuned on them. `summarize/eval_qmsum.py` runs the
default summarizer on all 232 meetings of [QMSum](https://github.com/Yale-LILY/QMSum) (MIT, commit `83d7768`):
137 AMI product-design meetings, 59 ICSI research meetings and 36 parliament committee meetings. Nothing was tuned
on this data. The transcripts are human transcripts, so these numbers do not include speech-recognition errors.

Each speaker turn becomes a `Speaker: text` line. The corpus markup (`{vocalsound}`, `{disfmarker}`) is removed and
the spaced punctuation (`okay .`) is joined, so the input looks like STT output. The reference is the answer to the
meeting's first general query ("Summarize the whole meeting." on 174 meetings, the same request in other words on
the rest). The ROUGE code is the same as for the fixtures. **LEAD** is a baseline: the first N words of the meeting,
where N is the length of our output, so the comparison is at equal length.

**textrank-tfidf + rules (the default)**, full four-section output with the AMI-trained action items, M4 Pro CPU:

| Corpus | Meetings | ROUGE-1 | ROUGE-2 | ROUGE-L | LEAD R-1 | LEAD R-2 | LEAD R-L | Sentences | Output / reference words | Latency mean / max |
|---|---|---|---|---|---|---|---|---|---|---|
| AMI | 137 | 0.219 | 0.042 | 0.116 | 0.203 | 0.041 | 0.113 | 675 | 378 / 112 | 81 / 278 ms |
| ICSI | 59 | 0.154 | 0.017 | 0.086 | 0.141 | 0.015 | 0.078 | 1205 | 501 / 97 | 238 / 763 ms |
| Committee | 36 | 0.204 | 0.043 | 0.115 | 0.212 | 0.066 | 0.136 | 801 | 584 / 135 | 492 / 1451 ms |
| **All** | 232 | **0.200** | **0.036** | **0.108** | 0.189 | 0.038 | 0.108 | 829 | 441 / 112 | 185 / 1451 ms |

An earlier run while other jobs shared the machine gave the same ROUGE and 355 / 2986 ms latency.

- **ROUGE is about a third of the fixture score** (ROUGE-1 0.200 against 0.654) and only just above LEAD:
  +0.011 ROUGE-1, -0.002 ROUGE-2, a tie on ROUGE-L. On the committee meetings LEAD wins on all three scores. The
  Overview and Key points alone score 0.222 / 0.031 / 0.126 against LEAD 0.216 / 0.041 / 0.122 at the same length
  (237 words).
- The output is 3.9 times longer than the reference (441 against 112 words). The AMI-trained action items made it
  longer: 6.3 items per meeting on average against 3.8 with the old first-person rule (AMI 6.9, ICSI 5.9, committee
  4.7), plus 3.0 decisions. The QMSum references mention few action items, so ROUGE-1 fell from 0.212 to 0.200.
  Part of the AMI rows are meetings the classifier was trained on, so this table is not an action-item score; that
  score is in the next section.
- The references are third-person prose ("The team agreed on ..."). Extracted sentences are first-person speech
  ("Okay, so um, we ..."), which hurts ROUGE-2 most. This gap is the case for an abstractive Overview model later.
- **Speed and memory on real lengths:** 185 ms per meeting on average (AMI 81 ms, ICSI 238 ms, committee
  492 ms). The slowest meeting took 1.4 to 3.0 s across runs, because other jobs shared the machine. In iteration 1
  the longest meeting (ICSI Bmr003: 2,393 sentences, 21.6k words) took 1.0 s and about 210 MB peak RSS on its own
  (not re-measured; the action items add about 10 ms per AMI meeting). The whole 232-meeting run peaks at 355 to
  720 MB across runs. The dense TF-IDF and similarity matrices dominate, so the fixtures' 30 MB does
  not hold for an hour-long meeting. A port should use sparse vectors.

**textrank-minilm + rules** on the same 232 meetings (project-local torch, see Reproduce):

| Corpus | ROUGE-1 | ROUGE-2 | ROUGE-L | LEAD R-1 | LEAD R-2 | LEAD R-L | Output / reference words | Latency mean / max |
|---|---|---|---|---|---|---|---|---|
| AMI | 0.241 | 0.043 | 0.126 | 0.222 | 0.043 | 0.124 | 254 / 112 | 2.1 / 26.4 s |
| ICSI | 0.185 | 0.015 | 0.100 | 0.161 | 0.015 | 0.087 | 316 / 97 | 6.7 / 20.0 s |
| Committee | 0.234 | 0.051 | 0.132 | 0.236 | 0.073 | 0.151 | 440 / 135 | 4.1 / 12.5 s |
| **All** | **0.226** | **0.037** | **0.120** | 0.208 | 0.040 | 0.119 | 299 / 112 | 3.6 / 26.4 s |

MiniLM picks shorter sentences, so its output is 299 words instead of 441 and its raw ROUGE is higher. Against
LEAD at the same length the gain is about the same as TF-IDF's (+0.018 ROUGE-1 against +0.011), and both lose to
LEAD on ROUGE-2. It is 10 to 20 times slower; this run's latency is inflated because the machine had a load average
above 100 (iteration 1 measured 2.9 s mean, 12.2 s max). The harness peaks at 4.1 GB RSS because it embeds all of a
meeting's sentences in one batch; a port would batch them. Decisions and action items are the same code in both
rows, so they score the same.

### Action items with owners

QMSum has no action-item or owner labels: its annotations are topic spans and query-answer pairs. So action items
are trained and scored on the AMI Meeting Corpus manual annotations (`ami_public_manual_1.6.2`, CC BY 4.0,
https://groups.inf.ed.ac.uk/ami/download). Code: `summarize/ami_actions.py`.

**Labels.** Each AMI scenario meeting has a hand-written abstractive summary with an `actions` list ("The marketing
expert will prepare a trendwatching report."). The `summlink` annotations tie every summary sentence to the dialogue
acts it summarizes. A dialogue act is an action item when it is linked to a sentence of the `actions` list. The
owner is the role named in the subject of that sentence (PM, ID and UI are accepted); items given to "the team" or
"they" have no single owner. The transcript is built from the AMI words, one dialogue act per sentence, with role
labels as speaker names (as QMSum does) and spelled letters joined (`T_V_` becomes `TV`, as STT writes it).

**Speaker labels.** Role labels are the best case for the owner rules. AMI speakers often say the roles aloud ("the
ID", "the Marketing Expert"), so the named-participant rule works as if everyone called each other by their calendar
name. The app never has role labels: it has calendar names or, without them, the local diarizer's
"Speaker 1", "Speaker 2". So every split is scored twice: with the role labels, and with the speakers renamed
Speaker 1 to 4 in order of first appearance, the owners mapped back to roles afterwards (`score(..., labels=SPEAKERS)`).
Nobody says "Speaker 2", so that row is the case where no owner comes from a name.

**Split.** The corpus's own partition (`seen_type` in `corpusResources/meetings.xml`), which is the standard AMI
scenario-only split. Test is the unseen series ES2004, ES2014, IS1009, TS3003 and TS3007, four meetings each. The
model is trained on train only, the threshold is picked on dev only, and the test split was first scored after
everything was frozen. One owner-rule change came after that (see below).

| Split | Meetings | Dialogue acts | Action-item acts | Gold items | with a named owner | team items |
|---|---|---|---|---|---|---|
| train | 98 | 77,609 | 255 | 202 | 153 | 49 |
| dev | 20 | 16,476 | 73 | 41 | 34 | 7 |
| test | 20 | 15,876 | 53 | 30 | 20 | 10 |

**Model.** Logistic regression (scikit-learn 1.9.1, L2, C = 0.03, balanced class weights), not an LLM and not a
neural network. Each sentence gets binary features: its words and word pairs, the words of the sentence before and
after it, its position in the meeting in tenths, its length, whether its speaker talks the most (the person running
the meeting), whether it is a question, and whether the old date and `I'll` rules fire. Weights under 0.02 are
dropped, which moves dev by at most one item. That leaves 5,513 weights in `summarize/actions_model.json` (106 KB, about
600 KB once loaded). At run time the summarizer adds up the weights of a sentence's features in plain Python, so it
needs no scikit-learn, numpy or model runtime, and a Swift or Rust port is a dictionary lookup. Training takes about
8 s on the M4 Pro and gives the same file every time.

**Rules on top of the model** (`action_items()` in `summarize/summarize.py`, which `actions()` and the Action items
section use):
- A sentence is an action item when the model scores it at or above the threshold, or when it is a first-person
  commitment with a date ("I'll send the notes by Friday"). Questions are never action items.
- Owner, first rule that applies: (1) a participant named in the sentence, matched as written: the speaker label or
  a word of it when capitalized, its initials in capitals ("ID" for Industrial Designer), or a name someone
  introduced themselves with ("I'm Kate"; not "This is Friday's plan"); (2) "I'll",
  "I'm going to", "let me" and the like: the speaker, unless a name comes first or they ask someone else ("I'll ask
  Ben to ..."); (3) "you", or no person at all: the addressee, taken as the next other speaker within three sentences
  (they usually acknowledge), else the previous one.
- Why "as written": calendar names are often words too. Matched in lowercase, "you will" named Will, "it is" named
  Ian Smith and "look at" named Amy Thompson. On the test split, labels with such names (Ian Smith, Amy Thompson, Tom
  Owens, Will Fern) scored 5 of 20 against 8 for Speaker 1 to 4. Now they score the same, and a test pins that. The
  ceiling: an all-caps word equal to someone's initials ("OK" for Olga Kim, "PM" as a time for Paul Miller) still names
  them, and so does a name that is also a word at the start of a sentence ("Will do.").
- Due date: the date phrase, preferring a "by" or "before" deadline ("follow up today and send it by Friday" is due
  Friday).
- The same task said twice to or by the same person is kept once, at the later mention (the recap).

**Threshold.** On dev, among thresholds giving at most 8 items per meeting, the highest one with the best recall with
the right owner: 0.55. The 8-item cap keeps the section readable; without it, dev recall with the right owner peaks
at 76% with 48 items per meeting.

**Metric.** A gold item with a named owner is recovered when some predicted item comes from one of its linked
dialogue acts and names one of its owners. Precision counts predicted items that come from a linked act of any
action item. Annotators link only one or two acts per item while an assignment often spans its neighbours, so a
second precision column also accepts an act within two of a linked one. Latency is `action_items()` alone, per
meeting, in CPython on the M4 Pro.

`.venv/bin/python -I ami_actions.py eval test` (and `eval dev`):

| Split | Approach | Recovered with right owner | Found (any owner) | Team items found | Precision (linked act) | Precision (within 2 acts) | Items / meeting | Latency mean / max |
|---|---|---|---|---|---|---|---|---|
| test | first-person rule (iteration 1) | 1/20 = 5.0% | 1/20 = 5.0% | 0/10 | 1/116 = 0.9% | 3/116 = 2.6% | 5.8 | under 1 ms |
| test | **AMI classifier + owner rules, role labels (best case)** | **13/20 = 65.0%** | 17/20 = 85.0% | 7/10 | 30/155 = 19.4% | 44/155 = 28.4% | 7.8 | 8 / 12 ms |
| test | **AMI classifier + owner rules, Speaker 1..4 labels** | **8/20 = 40.0%** | 15/20 = 75.0% | 7/10 | 28/152 = 18.4% | 42/152 = 27.6% | 7.6 | 8 / 12 ms |
| dev | first-person rule (iteration 1) | 1/34 = 2.9% | 1/34 = 2.9% | 1/7 | 3/91 = 3.3% | 9/91 = 9.9% | 4.5 | under 1 ms |
| dev | AMI classifier + owner rules, role labels (best case) | 20/34 = 58.8% | 26/34 = 76.5% | 5/7 | 35/151 = 23.2% | 49/151 = 32.5% | 7.5 | 8 / 13 ms |
| dev | AMI classifier + owner rules, Speaker 1..4 labels | 18/34 = 52.9% | 26/34 = 76.5% | 5/7 | 35/151 = 23.2% | 49/151 = 32.5% | 7.5 | 8 / 13 ms |

Memory: the longest test meeting (1,483 dialogue acts) peaks at 3.5 MB of Python heap in `action_items()`; the whole
eval process peaks at 33 to 42 MB RSS, corpus included.

**This still fails the goal's bar of at least 80%** (issue https://github.com/backant-io/shepetal/issues/8 stays
open), and how far below depends on the speaker labels. With AMI's role labels, 13 of 20 test items are recovered
with the right owner: 65%, with a 95% Wilson interval of 43 to 82%, because the test split has only 20 owned items.
That is the best case (see Speaker labels above). With Speaker 1 to 4 labels, which is what the app has without
calendar names, the same model and rules recover 8 of 20: **40%** (22 to 61%). Dev is 59% with role labels and 53%
with Speaker labels. The old rule scores 3 to 5% under the same metric, close to the 4.4% measured on QMSum in
iteration 1.

The first version of this section reported 14 of 20 (70%) on test and 19 of 34 on dev, with role labels only and
with the owner matched in lowercase. Review found that the 70% held only for role labels and that lowercase matching
breaks on name labels, so the owner is now matched as written. With role labels this cost one test item and gained
one dev item: the two test items it lost were said with lowercase role words ("And the marketing manager is coming
up with ...", "The user interface design, it's the same story."), and it gained one by chance. The test split had
been scored before this change, so it is no longer untouched. The change was made for name labels, not for the
score, and Speaker 1 to 4 numbers did not move.

Where the remaining gap is:
- **Owner, more than detection.** The classifier finds 85% of the test items and 77% of the dev items. With role
  labels the owner is wrong on 4 of the 17 found test items and 6 of the 26 found dev items; with Speaker labels on 7
  of 15 and 8 of 26. Even with perfect detection (every linked act), the owner rules are right on 65% of train items
  and 82% of dev items with role labels (72% and 85% when roles were matched in lowercase), and 54% and 82% with
  Speaker labels.
- Most wrong owners are tasks handed out with "you ..." while the speaker looks at someone. Text does not say who,
  and the next speaker is often someone else. AMI speakers also use names that are never introduced in the same
  meeting ("Kate will be looking at ...") and abbreviations such as "UID".
- Of the 3 test misses, two score under the threshold: a task stated as a fact ("we've got um the working design
  for ID", 0.42) and the PM's own "I'm going to finish my end report" (0.37 and 0.49). The third is a question ("What
  would you specifically like marketing to look at before the next meeting?", 0.92), and questions are never action items.
- Precision is low (19% strict, 28% within two acts) at 7.8 items per meeting against 1.5 gold items. Part of this
  is the annotators: their summaries list only the main tasks, and many flagged sentences are real hand-offs that
  did not make the summary. This was not hand-checked.

Tried and not kept (dev numbers, same metric):

| Try | Result |
|---|---|
| MiniLM-L6 embeddings of the sentence and its neighbours (1,152 dims) + logistic head | Worse: 20/34 at 13.7 items per meeting at best, the sparse model reaches 20/34 at 8.9 in the same harness |
| Sparse features + MiniLM embeddings | Same as sparse alone (19/34 at 6.3 items per meeting) |
| Learned owner ranker: logistic regression over speaker, next/previous speaker, named, pronoun and acknowledgment features | With perfect detection 72% train / 79% dev, the rules (then matching in lowercase) got 72% / 85%, role labels |
| Speaker-topic affinity (owner = whoever's own speech is closest to the task) | 26% / 36% alone, no gain as a ranker feature |
| Names carried across the four meetings of a series | +1 of 177 items |
| Previous short sentence as a vocative ("And marketing," then "you'll ..."), addressee window 3 to 20 sentences, self-mentions | within 1 item |
| C = 0.01 / 0.03 / 0.1, neighbour window 0 / 1 / 2, no word pairs | C = 0.03 with one neighbour each side is best per item shown |
| Dedupe keeping the first mention, the higher score, or none | First or higher score: 1 to 2 items fewer than keeping the later mention. None: about 1 item more at the same item count, but the section repeats tasks |
| Weight cut-off 0 to 0.05 | Within 1 item on dev; 0.02 chosen |

Not tried: a model that learns which role does which task. AMI's role play gives every role the same tasks (the
marketing expert always does trend watching), so it would score higher on AMI and mean nothing in a real meeting.

What would close the gap, not done here:
- Calendar names as speaker labels (goal rule 7), so "Kate, you'll ..." resolves to a speaker. AMI cannot measure
  this: its names are not tied to speakers. The two rows bracket it: role labels are the case where people say each
  other's label aloud (65%), Speaker 1 to 4 the case where nobody does (40%).
- The addressee from the audio or video (who the speaker faces), which text cannot give.
- More labelled meetings: there are only 255 action-item acts in AMI train.

Decisions were not scored on real data: AMI also has a `decisions` list, but it is not matched yet (issue #18).

### Fixtures against real data

| | Fixtures | QMSum / AMI |
|---|---|---|
| Meetings | 3, self-written | 232 real (137 AMI, 59 ICSI, 36 committee) |
| Length | 480-690 words | 6k-14k words on average, up to 23.7k |
| ROUGE-1 / 2 / L | 0.654 / 0.432 / 0.444 | 0.200 / 0.036 / 0.108 (LEAD 0.189 / 0.038 / 0.108) |
| Action items with right owner | 15 / 16 | AMI test split 65% with role labels, 40% with Speaker 1..4 labels (old rule 5%) |
| Latency per meeting | 19-25 ms | about 190 ms mean, 1.4-3.0 s max |
| Peak RSS | 31 MB | 210 MB for the longest meeting alone, 355-720 MB for a full run |

The fixtures overstate quality badly. Treat them as a regression test for the rules, not as a quality number.

## Recommendation

| Platform | Default | Fallback |
|---|---|---|
| Mac | TF-IDF TextRank + rules + the 106 KB action-item model (on real meetings about 190 ms mean, up to 3.0 s, a few hundred MB RSS) | MiniLM-L6 TextRank via CoreML (90 MB), optional |
| iPhone | TF-IDF TextRank + rules | MiniLM-L6 CoreML encoder on the ANE |
| Linux CPU | TF-IDF TextRank + rules | MiniLM-L6 via ONNX Runtime |

MiniLM did not clearly beat TF-IDF on the fixtures or on QMSum (about +0.007 ROUGE-1 more over LEAD, at 10 to 20
times the latency plus a 90 MB model and a runtime), so TF-IDF stays the default and MiniLM stays optional. Both paths are deterministic and
hallucination-free. Action items come from the AMI-trained logistic regression plus owner rules on every platform:
it is a 106 KB JSON file and a sum of weights, so it needs no runtime. It reaches 65% on the AMI test split with role labels and 40% with
Speaker 1 to 4 labels, short of the goal's 80% (issue #8). Add a seq2seq model only for the Overview line, once it has been measured: distilBART-CNN-12-6 or
a SAMSum fine-tune on Mac and Linux. Re-evaluate NCM when a meeting or dialogue checkpoint and a non-CUDA path
exist; issue #12 tracks this.

## Long transcripts

- Extractive: no context limit. TextRank runs over all sentences with an O(n^2) dense similarity matrix. Measured:
  2,393 sentences (21.6k words) take 1.0 s and about 210 MB. At 5k sentences the matrices alone pass 400 MB, so
  for longer meetings rank per 10-minute window and then rank the winners.
- Seq2seq: `chunks()` packs whole speaker turns up to the model limit (1024 tokens for BART, 512 for T5/NCM),
  summarizes each chunk and dedupes the result. LED / LongT5 accept 16k tokens if the chunk seams hurt quality.
- Decisions and action items always run on the full transcript, so chunking never drops them. The action-item model
  looks at one sentence and its two neighbours, so its cost grows linearly (8 ms for a 1,483-act AMI meeting).

## Embedding

- **Swift (Mac/iPhone):** convert all-MiniLM-L6-v2 with `coremltools` (`ct.convert` of the traced
  `AutoModel`, fp16, flexible sequence length up to 128) to `MiniLM.mlpackage`. Tokenize with
  swift-transformers' `BertTokenizer`. Mean-pool, then run TextRank in Swift with Accelerate (`vDSP` mat-mul plus
  50 power iterations). Port the regex rules to `NSRegularExpression`. For a seq2seq model, use ONNX Runtime's Swift
  package (`onnxruntime-objc`) with the `optimum` export (encoder plus decoder-with-past) and a host-side beam loop.
- **Action items, every platform:** load `actions_model.json` as a dictionary from feature string to weight, build the
  same feature strings as `action_features()` (`u:word`, `b:word_word`, `p:` and `n:` for the neighbours, `pos0` to
  `pos9`, `len0` to `len5`, `chair`, `q`, `due`, `commit`), and score `1 / (1 + exp(-(bias + sum)))`. Port the owner
  and due rules as regexes. The tests in `test_summarize.py` pin the behaviour a port has to match.
- **Linux:** export MiniLM to ONNX (`optimum-cli export onnx --model sentence-transformers/all-MiniLM-L6-v2`),
  run it with `onnxruntime` on CPU, and port the rest of `summarize.py` (only numpy is needed). The TF-IDF fallback
  needs no model file.

## Reproduce

```bash
cd summarize && python3 -m venv .venv && .venv/bin/pip install numpy   # the default path needs numpy only
.venv/bin/python -m unittest -v                                       # includes a test that blocks torch
.venv/bin/python summarize.py textrank-tfidf

# Real meetings (text only, about 45 MB, into .cache)
git clone -q --depth 1 --filter=blob:none --sparse https://github.com/Yale-LILY/QMSum.git .cache/qmsum
git -C .cache/qmsum sparse-checkout set data/ALL/train data/ALL/val data/ALL/test
.venv/bin/python -I eval_qmsum.py                      # textrank-tfidf, about 45 s for 232 meetings

# Action items: AMI manual annotations (22.9 MB zip, about 160 MB unpacked, into .cache)
mkdir -p .cache/ami && curl -sSLo .cache/ami/m.zip https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/ami_public_manual_1.6.2.zip
unzip -q -o .cache/ami/m.zip 'abstractive/*' 'extractive/*' 'dialogueActs/*' 'words/*' 'corpusResources/*' -d .cache/ami
.venv/bin/python -m unittest -v                       # now also runs the AMI test-split checks instead of skipping them
.venv/bin/python -I ami_actions.py eval test           # the table above; `eval dev` for dev
.venv/bin/pip install scikit-learn                     # training only (1.9.1 on 2026-10-20)
.venv/bin/python -I ami_actions.py train               # rewrites actions_model.json (same bytes every run), about 8 s

# Optional MiniLM ranker: its own torch in this venv (torch 2.14.1, transformers 5.20.2 on 2026-10-20)
.venv/bin/pip install torch transformers
.venv/bin/python summarize.py textrank-minilm        # expects .cache/minilm (all-MiniLM-L6-v2 files)
.venv/bin/python -I eval_qmsum.py textrank-minilm
.venv/bin/python summarize.py seq2seq sshleifer/distilbart-cnn-12-6   # not measured yet
```

The venv is project-local and must not borrow packages from another checkout. Model files and corpora go to
`summarize/.cache` (gitignored). Never commit downloaded weights or corpus text. The one exception is
`actions_model.json`: 106 KB of our own logistic-regression weights over single words and word pairs, trained here
from the CC BY 4.0 AMI annotations (credited in the file's `trained_on` field and above) and rebuilt byte for byte by
`ami_actions.py train`. It holds no corpus sentences. It is committed so the summarizer runs from a clean clone with
no download and no scikit-learn.
