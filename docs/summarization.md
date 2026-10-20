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
| AMI | 137 | 0.216 | 0.042 | 0.115 | 0.201 | 0.040 | 0.112 | 675 | 392 / 112 | 88 / 283 ms |
| ICSI | 59 | 0.150 | 0.017 | 0.085 | 0.138 | 0.015 | 0.076 | 1205 | 521 / 97 | 251 / 777 ms |
| Committee | 36 | 0.200 | 0.044 | 0.113 | 0.207 | 0.065 | 0.133 | 801 | 610 / 135 | 521 / 1506 ms |
| **All** | 232 | **0.197** | **0.036** | **0.107** | 0.186 | 0.038 | 0.106 | 829 | 459 / 112 | 196 / 1506 ms |

These are the numbers with the current action-item model (`feat/summarize-actions-80`). The previous model gave
0.200 / 0.036 / 0.108 over all 232 meetings at 441 words, 185 / 1451 ms.

- **ROUGE is about a third of the fixture score** (ROUGE-1 0.197 against 0.654) and only just above LEAD:
  +0.011 ROUGE-1, -0.002 ROUGE-2, +0.001 ROUGE-L. On the committee meetings LEAD wins on all three scores. The
  Overview and Key points alone score 0.222 / 0.030 / 0.125 against LEAD 0.216 / 0.041 / 0.122 at the same length
  (239 words; the previous model left them at 0.222 / 0.030 / 0.126).
- The output is 4.1 times longer than the reference (459 against 112 words). The AMI-trained action items made it
  longer: 7.0 items per meeting on average against 3.8 with the old first-person rule (AMI 7.6, ICSI 6.6, committee
  5.6), plus 3.0 decisions. The QMSum references mention few action items, so ROUGE-1 fell from 0.212 to 0.197.
  Most of the AMI rows are meetings the classifier was trained on, so this table is not an action-item score; that
  score is in the next section. ICSI and committee meetings are out of domain for the classifier, and how many of
  their 6.6 and 5.6 items per meeting are real is not measured.
- The references are third-person prose ("The team agreed on ..."). Extracted sentences are first-person speech
  ("Okay, so um, we ..."), which hurts ROUGE-2 most. This gap is the case for an abstractive Overview model later.
- **Speed and memory on real lengths:** 196 ms per meeting on average (AMI 88 ms, ICSI 251 ms, committee
  521 ms). The slowest meeting took 1.4 to 3.0 s across runs, because other jobs shared the machine. In iteration 1
  the longest meeting (ICSI Bmr003: 2,393 sentences, 21.6k words) took 1.0 s and about 210 MB peak RSS on its own
  (not re-measured; the action items add about 10 ms per AMI meeting). The whole 232-meeting run peaks at 355 to
  720 MB across runs (573 MB in the current run). The dense TF-IDF and similarity matrices dominate, so the fixtures' 30 MB does
  not hold for an hour-long meeting. A port should use sparse vectors.

**textrank-minilm + rules** on the same 232 meetings (project-local torch, see Reproduce). Measured with the
previous action-item model and not re-run: torch was removed from the venv when the shared disk filled up during
this change. The MiniLM ranker's code did not change; its action items did, exactly as in the TF-IDF row.

| Corpus | ROUGE-1 | ROUGE-2 | ROUGE-L | LEAD R-1 | LEAD R-2 | LEAD R-L | Output / reference words | Latency mean / max |
|---|---|---|---|---|---|---|---|---|
| AMI | 0.242 | 0.044 | 0.126 | 0.222 | 0.043 | 0.124 | 253 / 112 | 1.4 / 4.1 s |
| ICSI | 0.184 | 0.015 | 0.100 | 0.161 | 0.015 | 0.087 | 317 / 97 | 3.9 / 10.8 s |
| Committee | 0.235 | 0.051 | 0.132 | 0.236 | 0.073 | 0.151 | 437 / 135 | 2.9 / 7.0 s |
| **All** | **0.226** | **0.038** | **0.120** | 0.209 | 0.040 | 0.119 | 298 / 112 | 2.3 / 10.8 s |

MiniLM picks shorter sentences, so its output is 298 words instead of 441 and its raw ROUGE is higher. Against
LEAD at the same length the gain is about the same as TF-IDF's (+0.017 ROUGE-1 against +0.011), and both lose to
LEAD on ROUGE-2. It is 10 to 20 times slower (an earlier run with a load average above 100 took 3.6 s mean, 26.4 s
max; iteration 1 measured 2.9 s mean, 12.2 s max). The harness peaks at 4.2 GB RSS because it embeds all of a
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
Nobody says "Speaker 2", so in that row no owner comes from a label: owners come from turn-taking and from the
titles and first names people give themselves ("I'm the Industrial Designer", "I'm Kate").

**Split.** The corpus's own partition (`seen_type` in `corpusResources/meetings.xml`), which is the standard AMI
scenario-only split. Test is the unseen series ES2004, ES2014, IS1009, TS3003 and TS3007, four meetings each.
Train and dev are for building the model only:
- Features and rules were chosen by 5-fold cross-validation over the 30 train + dev series. A whole series stays in
  one fold, because its four meetings have the same people and tasks.
- The threshold comes from the same cross-validation, and the shipped model is then fit on all of train + dev.
- Why not dev alone: it has 34 owned items, and its recall moves by 2 to 3 items (6 to 9 points) between
  neighbouring thresholds. That is as much as this whole change gains on dev: fit on train only, the new pipeline
  gets 22 of 34 with role labels and 21 with Speaker labels at up to 8 items per meeting, against 20 and 18 before.
- The test split was scored once for this change, after the code and the model were frozen. It had been scored in
  earlier iterations, so it is not untouched, but nothing in this change was chosen by looking at it. A test pins
  that the cross-validation folds never contain a test meeting.

| Split | Meetings | Dialogue acts | Action-item acts | Gold items | with a named owner | team items |
|---|---|---|---|---|---|---|
| train | 98 | 77,609 | 255 | 202 | 153 | 49 |
| dev | 20 | 16,476 | 73 | 41 | 34 | 7 |
| test | 20 | 15,876 | 53 | 30 | 20 | 10 |

**Model.** Logistic regression (scikit-learn 1.9.1, L2, C = 0.03, balanced class weights), not an LLM and not a
neural network. Each sentence gets binary features: its words and word pairs, the words of the sentence before and
after it, its position in the meeting in tenths, its length, whether its speaker talks the most (the person running
the meeting), whether it is a question, and whether the old date and `I'll` rules fire. Five modal cues are new
in this change (`CUES` in `summarize.py`):
- `a:you`: "you" plus a modal ("you'll", "you should", "you two are going to").
- `a:i`: "I" plus a modal.
- `a:we`: "we" plus a modal.
- `a:name`: a capitalized word that does not open the sentence, plus a modal ("so Kate will", "the Industrial
  Designer can").
- `a:next`: "next meeting", "after lunch", "meantime" and the like.

Word pairs learn each spelling on its own ("you'll_look", "you_should"); the cues pool them. The model learns
`a:you`, `a:i` and `a:name` at +0.77 to +0.84, about as much as `chair`. Weights under 0.02 are dropped. That leaves
6,647 weights in `summarize/actions_model.json` (130 KB, about 690 KB once loaded). At run time the summarizer adds
up the weights of a sentence's features in plain Python, so it needs no scikit-learn, numpy or model runtime, and a
Swift or Rust port is a dictionary lookup plus five regexes. Training (five cross-validation fits plus the final one)
takes about 45 s on the M4 Pro and gives the same file every time.

The largest weights also include words of the AMI task itself ("trendwatching", "questionnaire", "evaluation",
"component"): the model learns the AMI scenario's vocabulary as well as the hand-off phrasing. That inflates AMI
scores somewhat, and it is the main reason ICSI and committee meetings need their own labels before anyone can claim
a number for them.

**Rules on top of the model** (`action_items()` in `summarize/summarize.py`, which `actions()` and the Action items
section use):
- A sentence is an action item when the model scores it at or above the threshold, or when it is a first-person
  commitment with a date ("I'll send the notes by Friday"). Questions are not action items, unless they ask someone
  to do something ("Could you e-mail me the slides?", "Can someone ...", "Do you want to ...").
- Owner, first rule that applies:
  1. A participant named in the sentence, matched as written. That is the speaker label or a word of it when
     capitalized, its initials in capitals ("ID" for Industrial Designer), a name someone introduced themselves with
     ("I'm Kate"; not "This is Friday's plan"), or a job title someone gave themselves. "I'm the Industrial
     Designer" makes "Industrial Designer", "Industrial" and "ID" name that speaker. A word that two titles share,
     such as "Designer", names nobody.
  2. "I'll", "I'm going to", "let me" and the like: the speaker, unless a name comes first or they ask someone else
     ("I'll ask Ben to ...").
  3. "you", or no person at all: the addressee. That is the next other speaker however far ahead, because the chair
     often hands out three tasks before anyone answers. With no later speaker, it is the previous one within three
     sentences. The old rule only looked three sentences ahead and then fell back to the previous speaker.
- Why "as written": calendar names are often words too. Matched in lowercase, "you will" named Will, "it is" named
  Ian Smith and "look at" named Amy Thompson. On the test split, labels with such names (Ian Smith, Amy Thompson, Tom
  Owens, Will Fern) scored 5 of 20 against 8 for Speaker 1 to 4. Now they score the same, and a test pins that. The
  ceiling: an all-caps word equal to someone's initials ("OK" for Olga Kim, "PM" as a time for Paul Miller) still names
  them, and so does a name that is also a word at the start of a sentence ("Will do.").
- Due date: the date phrase, preferring a "by" or "before" deadline ("follow up today and send it by Friday" is due
  Friday).
- The same task said twice to or by the same person is kept once, at the later mention (the recap). "The same task"
  now compares content words only (`same_task()`). The old check compared all words, so "you have to work on the
  components concept" and "you have to work on the user interface" counted as one task. A hand-out of several tasks
  to one person, or several "you" tasks that went to the same answerer, kept only the last one. This was the largest
  single fix: +5 of 187 items in cross-validation.

**Threshold.** From the cross-validation: among thresholds on a 0.025 grid giving at most 8 items per meeting, the
highest one with the best recall with the right owner (role labels). That is 0.575, with 7.8 items per meeting in
cross-validation; the test split gets 8.4 at the same threshold. The 8-item cap keeps the section readable. Without
it, recall keeps climbing: 59% in cross-validation at 28 items per meeting.

**Metric.** A gold item with a named owner is recovered when some predicted item comes from one of its linked
dialogue acts and names one of its owners. Precision counts predicted items that come from a linked act of any
action item. Annotators link only one or two acts per item while an assignment often spans its neighbours, so a
second precision column also accepts an act within two of a linked one. Latency is `action_items()` alone, per
meeting, in CPython on the M4 Pro.

`.venv/bin/python -I ami_actions.py eval test` and `eval cv` (5-fold cross-validation over train + dev at the
shipped threshold). The "before" rows are the previous code and model run the same day. The "before" CV rows put
the previous features and rules through the new protocol, which picks 0.575 for them too.

| Split | Approach | Recovered with right owner | Found (any owner) | Team items found | Precision (linked act) | Precision (within 2 acts) | Items / meeting | Latency mean / max |
|---|---|---|---|---|---|---|---|---|
| test | first-person rule (iteration 1) | 1/20 = 5.0% | 1/20 = 5.0% | 0/10 | 1/116 = 0.9% | 3/116 = 2.6% | 5.8 | under 1 ms |
| test | before, role labels | 13/20 = 65.0% | 17/20 = 85.0% | 7/10 | 30/155 = 19.4% | 44/155 = 28.4% | 7.8 | 9 / 13 ms |
| test | before, Speaker 1..4 labels | 8/20 = 40.0% | 15/20 = 75.0% | 7/10 | 28/152 = 18.4% | 42/152 = 27.6% | 7.6 | 8 / 13 ms |
| test | **now, role labels (best case)** | **16/20 = 80.0%** | 18/20 = 90.0% | 8/10 | 33/168 = 19.6% | 48/168 = 28.6% | 8.4 | 11 / 18 ms |
| test | **now, Speaker 1..4 labels** | **14/20 = 70.0%** | 18/20 = 90.0% | 8/10 | 33/168 = 19.6% | 48/168 = 28.6% | 8.4 | 10 / 16 ms |
| CV, train + dev | before, role labels | 92/187 = 49.2% | 142/187 = 75.9% | 31/56 | 194/901 = 21.5% | 285/901 = 31.6% | 7.6 | 8 / 15 ms |
| CV, train + dev | before, Speaker 1..4 labels | 73/187 = 39.0% | 137/187 = 73.3% | 31/56 | 189/899 = 21.0% | 280/899 = 31.1% | 7.6 | 8 / 15 ms |
| CV, train + dev | **now, role labels (best case)** | **102/187 = 54.5%** | 153/187 = 81.8% | 31/56 | 207/926 = 22.4% | 304/926 = 32.8% | 7.8 | 10 / 51 ms |
| CV, train + dev | **now, Speaker 1..4 labels** | **87/187 = 46.5%** | 152/187 = 81.3% | 31/56 | 206/927 = 22.2% | 303/927 = 32.7% | 7.9 | 9 / 19 ms |

Memory: the longest test meeting (1,483 dialogue acts) peaks at 3.5 MB of Python heap in `action_items()`; the whole
eval process peaks at 38 MB RSS, corpus included. The model is 130 KB on disk and 687 KB once loaded (603 KB before).
Latency is about 2 ms per meeting higher than before (the five cue regexes and the title regex); the 51 ms maximum
is one meeting during a load spike from other jobs on the machine.

**What the 80% means.** On the test split, 16 of 20 items are recovered with the right owner with role labels
(95% Wilson interval 58 to 92%). With Speaker 1 to 4 labels, which is what the app has without calendar names, the
figure is 14 of 20 (48 to 85%). That meets the goal's 80% only as a point estimate on 20 items, and only with role
labels. The cross-validation over train + dev (187 items, each scored by a model that never saw its series) puts
the same method at **54.5% with role labels and 46.5% with Speaker labels**: +5.3 and +7.5 points over the previous
code under the same protocol.

The test split gains more (+15 and +30 points) because each of its 20 items is 5 points. Most of that gap is the
draw, not the method. So issue https://github.com/backant-io/shepetal/issues/8 stays open: on AMI the best estimate
is about 55% with role labels and 47% with Speaker labels, not 80%. The old first-person rule scores 3 to 5% under
the same metric, close to the 4.4% measured on QMSum in iteration 1.

The first version of this section reported 14 of 20 (70%) on test and 19 of 34 on dev, with role labels only and
with the owner matched in lowercase. Review found that the 70% held only for role labels and that lowercase matching
breaks on name labels, so the owner is now matched as written. With role labels this cost one test item and gained
one dev item: the two test items it lost were said with lowercase role words ("And the marketing manager is coming
up with ...", "The user interface design, it's the same story."), and it gained one by chance. The test split had
been scored before this change, so it is no longer untouched. The change was made for name labels, not for the
score, and Speaker 1 to 4 numbers did not move.

Where the remaining gap is (cross-validation, role labels; the test split was not opened for error analysis):
- **Owner, more than detection.** The classifier finds 153 of 187 items (82%). 10 of the 34 misses have no linked
  dialogue act at all, so no system can recover them under this metric. The owner is right on 102 of the 153 found
  items (67%).
- **"you" is the wall.** By where the owner came from: a named participant is right on 37 of 38 found items, the
  first person on 12 of 13, and "you" on 49 of 97. For "you", no text cue tried beats "the next other speaker"
  (50 of 92 "you" acts, against 37 for a random other participant); see the table below. The rest is said with a
  look, not a word.
- AMI speakers also use names that are introduced only in the series' first meeting ("Kate will be looking at ...",
  "Ryan, you'll be working on ..."). Per meeting, nothing ties those names to a voice.
- Precision is low (20% strict, 29% within two acts) at about 8 items per meeting against 1.5 gold items. Part of
  this is the annotators: their summaries list only the main tasks, and many flagged sentences are real hand-offs
  that did not make the summary. This was not hand-checked.

Tried in this change and not kept (5-fold cross-validation over train + dev, 187 owned items; the first number is
role labels, the second Speaker 1..4 labels, both at up to 8 items per meeting):

| Try | Result |
|---|---|
| Addressee = first acknowledger ("okay", "sure", "mm-hmm") within 6 sentences | -1 / 0 items |
| Addressee by the words of each candidate's reply, or by their earlier or later speech in the meeting (topic affinity) | 49 / 32 / 41 of 92 "you" acts right, against 50 for the next speaker |
| Hand-out blocks: the one "you" left goes to the one participant not yet named; or "you" tasks spread over different people in order of who speaks | 0 / 0 and -2 / -7 items |
| Vocative names tied to whoever answers ("Kate, ..." and then a reply; "thanks, Kate") | 0 / +1 item; not worth the code |
| Third person about oneself ("the Industrial Designer will", said by the ID) | 0 / 0 items |
| Features: first word after fillers, cue words 2 to 5 sentences away, words two sentences away, an acknowledgment next, distance to the end, chair-only modal words | one at a time on the previous rules: between -5 and +1 items each. First word, acknowledgment and distance together on the final rules: -4 / -4 |
| No neighbour words | -4 / -4 items |
| Cue features beyond the five kept ("you guys", "want you to", "for you to", "let's") | 0 / 0 items each, dropped |
| C = 0.02 / 0.05 with the final features | same recall (102 / 87) |
| A per-meeting top-k (8 or 10) on top of the threshold | -3 to -5 / -2 to -4 items |
| Lowering the cap: recall keeps rising with more items | 59% (role labels) at 28 items per meeting; not readable |
| A small encoder (MiniLM + linear head) | Not retried. The earlier frozen-embedding runs below lost to the sparse model. A fine-tuned encoder would not fit the "weights JSON of a few MB, no runtime" constraint. The shared disk was also full during this change |

Tried before this change (dev numbers, same metric):

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
  this directly: its names are not tied to speakers outside the first meeting's introductions. The two rows bracket
  it: role labels are the case where people say each other's label aloud (54.5% CV, 80% test), Speaker 1 to 4 the
  case where nobody does (46.5% CV, 70% test).
- The addressee from the audio or video (who the speaker faces), which text cannot give.
- More labelled meetings: there are only 255 action-item acts in AMI train.

Decisions were not scored on real data: AMI also has a `decisions` list, but it is not matched yet (issue #18).

### Fixtures against real data

| | Fixtures | QMSum / AMI |
|---|---|---|
| Meetings | 3, self-written | 232 real (137 AMI, 59 ICSI, 36 committee) |
| Length | 480-690 words | 6k-14k words on average, up to 23.7k |
| ROUGE-1 / 2 / L | 0.654 / 0.432 / 0.444 | 0.197 / 0.036 / 0.107 (LEAD 0.186 / 0.038 / 0.106) |
| Action items with right owner | 15 / 16 | AMI test split 80% with role labels, 70% with Speaker 1..4 labels; 5-fold CV on train + dev 54.5% / 46.5% (old rule 5%) |
| Latency per meeting | 19-25 ms | about 200 ms mean, 1.4-3.0 s max |
| Peak RSS | 31 MB | 210 MB for the longest meeting alone, 355-720 MB for a full run |

The fixtures overstate quality badly. Treat them as a regression test for the rules, not as a quality number.

## Recommendation

| Platform | Default | Fallback |
|---|---|---|
| Mac | TF-IDF TextRank + rules + the 130 KB action-item model (on real meetings about 200 ms mean, up to 3.0 s, a few hundred MB RSS) | MiniLM-L6 TextRank via CoreML (90 MB), optional |
| iPhone | TF-IDF TextRank + rules | MiniLM-L6 CoreML encoder on the ANE |
| Linux CPU | TF-IDF TextRank + rules | MiniLM-L6 via ONNX Runtime |

MiniLM did not clearly beat TF-IDF on the fixtures or on QMSum (about +0.006 ROUGE-1 more over LEAD, at 10 to 20
times the latency plus a 90 MB model and a runtime), so TF-IDF stays the default and MiniLM stays optional. Both paths are deterministic and
hallucination-free. Action items come from the AMI-trained logistic regression plus owner rules on every platform:
it is a 130 KB JSON file and a sum of weights, so it needs no runtime. It reaches 80% on the AMI test split with role
labels and 70% with Speaker 1 to 4 labels. On the 187 items of the train + dev cross-validation it reaches only 54.5%
and 46.5%, so it is still short of the goal's 80% (issue #8). Add a seq2seq model only for the Overview line, once it has been measured: distilBART-CNN-12-6 or
a SAMSum fine-tune on Mac and Linux. Re-evaluate NCM when a meeting or dialogue checkpoint and a non-CUDA path
exist; issue #12 tracks this.

## Long transcripts

- Extractive: no context limit. TextRank runs over all sentences with an O(n^2) dense similarity matrix. Measured:
  2,393 sentences (21.6k words) take 1.0 s and about 210 MB. At 5k sentences the matrices alone pass 400 MB, so
  for longer meetings rank per 10-minute window and then rank the winners.
- Seq2seq: `chunks()` packs whole speaker turns up to the model limit (1024 tokens for BART, 512 for T5/NCM),
  summarizes each chunk and dedupes the result. LED / LongT5 accept 16k tokens if the chunk seams hurt quality.
- Decisions and action items always run on the full transcript, so chunking never drops them. The action-item model
  looks at one sentence and its two neighbours, so its cost grows linearly (about 10 ms for a 1,483-act AMI meeting).
  The "you" owner rule scans ahead to the next other speaker. In a long monologue with many flagged sentences that
  scan is quadratic, but it stops at the first reply.

## Embedding

- **Swift (Mac/iPhone):** convert all-MiniLM-L6-v2 with `coremltools` (`ct.convert` of the traced
  `AutoModel`, fp16, flexible sequence length up to 128) to `MiniLM.mlpackage`. Tokenize with
  swift-transformers' `BertTokenizer`. Mean-pool, then run TextRank in Swift with Accelerate (`vDSP` mat-mul plus
  50 power iterations). Port the regex rules to `NSRegularExpression`. For a seq2seq model, use ONNX Runtime's Swift
  package (`onnxruntime-objc`) with the `optimum` export (encoder plus decoder-with-past) and a host-side beam loop.
- **Action items, every platform:** load `actions_model.json` as a dictionary from feature string to weight, build the
  same feature strings as `action_features()` (`u:word`, `b:word_word`, `p:` and `n:` for the neighbours, `pos0` to
  `pos9`, `len0` to `len5`, `chair`, `q`, `due`, `commit`, and the cue features `a:you`, `a:i`, `a:we`, `a:name`,
  `a:next`), and score `1 / (1 + exp(-(bias + sum)))`. Port the owner and due rules as regexes. The tests in
  `test_summarize.py` pin the behaviour a port has to match.
- **What changed for the Swift port (Sources/ShepetalSummary) in `feat/summarize-actions-80`:**
  - The JSON keys are the same (`bias`, `threshold`, `weights`, `C`, `trained_on`). Scoring is unchanged. The
    threshold is now 0.575 (was 0.55); read it from the file, don't hard-code it.
  - Five new feature strings, each `1` when its regex in `CUES` matches the sentence. `MODAL` is
    `(?:will|'ll|should|could|can|must|(?:have|has|need|needs) to|(?:are|'re|is|am|'m) (?:going to|gonna)|gonna|might want to)`.
    - `a:you`: `\byou(?: two| guys| both| all)?\s*MODAL`, case-insensitive.
    - `a:i`: `\bI\s*MODAL`, case-sensitive.
    - `a:we`: `\bwe\s*MODAL`, case-insensitive.
    - `a:name`: `(?<=\s)[A-Z][a-z]{2,}(?: [A-Z][a-z]+)*\s+MODAL`, case-sensitive.
    - `a:next`: `\b(?:next meeting|next time|for next|by next|before next|after lunch|after the break|meantime)\b`,
      case-insensitive.
  - Rules:
    - Questions are dropped unless `REQUEST` matches after the fillers are stripped ("could you", "can someone",
      "do you want to").
    - The "you" owner is the next other speaker however far ahead, else the previous one within 3 sentences.
    - `aliases()` also reads `TITLE` self-introductions ("I'm the Industrial Designer") as extra names of the
      speaker. A word is an alias only when no other speaker's label or title has it. Labels win over titles.
    - The recap dedupe compares content words (`same_task()`, with the `FUNCTION` word list) instead of all words.
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
.venv/bin/python -I ami_actions.py eval test           # the test rows above
.venv/bin/pip install scikit-learn                     # training and cross-validation only (1.9.1 on 2026-10-20)
.venv/bin/python -I ami_actions.py eval cv             # the CV rows above (refits 5 fold models per label set), about 90 s
.venv/bin/python -I ami_actions.py train               # rewrites actions_model.json (same bytes every run), about 45 s

# Optional MiniLM ranker: its own torch in this venv (torch 2.14.1, transformers 5.20.2 on 2026-10-20)
.venv/bin/pip install torch transformers
.venv/bin/python summarize.py textrank-minilm        # expects .cache/minilm (all-MiniLM-L6-v2 files)
.venv/bin/python -I eval_qmsum.py textrank-minilm
.venv/bin/python summarize.py seq2seq sshleifer/distilbart-cnn-12-6   # not measured yet
```

The venv is project-local and must not borrow packages from another checkout. Model files and corpora go to
`summarize/.cache` (gitignored). Never commit downloaded weights or corpus text. The one exception is
`actions_model.json`: 130 KB of our own logistic-regression weights over single words, word pairs and five cue
features, trained here
from the CC BY 4.0 AMI annotations (credited in the file's `trained_on` field and above) and rebuilt byte for byte by
`ami_actions.py train`. It holds no corpus sentences. It is committed so the summarizer runs from a clean clone with
no download and no scikit-learn.
