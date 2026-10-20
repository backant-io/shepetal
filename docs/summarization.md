# Meeting summarization

Shepetal turns a speaker-labelled transcript into four sections: **Overview**, **Key points**, **Decisions**
and **Action items (owner, task, due)**. It runs fully on the device and uses no decoder-only chat LLM.

Code: `summarize/summarize.py`. Fixtures and reference summaries: `summarize/fixtures/`. Sample outputs: `summarize/out/`.
Real-meeting check: `summarize/eval_qmsum.py`. Tests: `summarize/test_summarize.py`.

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
   Action items are first-person commitments (`I'll` / `I will` + clause): owner = speaker, due = date phrase
   (`by Friday`, `today`, `next week`, `the 4th`).
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
| textrank-tfidf + rules | 0.647 | 0.426 | 0.448 | 12-45 ms (varies with machine load) | 0 s | 30 MB |
| textrank-minilm + rules | 0.628 | 0.421 | 0.471 | 125 ms | 2.0 s (mostly torch import) | 487 MB (PyTorch runtime; the model is 90 MB) |

Decisions and action items come from the same rules in both rows. Only the Overview and Key points differ, and on
these fixtures the two rankers are a tie: TF-IDF is slightly ahead on ROUGE-1, MiniLM slightly ahead on ROUGE-L.

**Manual check (textrank-tfidf, see `summarize/out/`):**
- Action items are the strongest part: all 16 reference action items were found with the right owner and due
  date, plus 2 extra minor commitments. Weak spots: pronoun tasks ("Tom: open it"), and an assignment phrased as
  "Tom, you will ..." is only caught when the owner confirms it in the first person.
- Decisions: most were found, but sentences phrased as a plan ("So the plan is the fix goes into 2.4") fall into
  Key points, and recap sentences sometimes repeat a decision.
- MiniLM picked a better Overview for fixture 1 ("This is the weekly release sync for version 2.4.") where TF-IDF
  picked the agenda sentence, which is the one quality gain from embeddings that we saw.
- The Overview is a sentence copied from the transcript, so it reads as speech ("We have about ten minutes, so
  I'd like to cover ..."). An abstractive model would help most here.
- These rules were written against these same three fixtures, so the scores are optimistic. The next section
  shows how optimistic: on real meetings the action-item rule drops from 100% to about 5%.

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

**textrank-tfidf + rules (the default)**, full four-section output, M4 Pro CPU, no other load:

| Corpus | Meetings | ROUGE-1 | ROUGE-2 | ROUGE-L | LEAD R-1 | LEAD R-2 | LEAD R-L | Sentences | Output / reference words | Latency mean / max |
|---|---|---|---|---|---|---|---|---|---|---|
| AMI | 137 | 0.231 | 0.042 | 0.122 | 0.212 | 0.041 | 0.119 | 675 | 306 / 112 | 81 / 389 ms |
| ICSI | 59 | 0.171 | 0.017 | 0.095 | 0.155 | 0.016 | 0.085 | 1205 | 389 / 97 | 239 / 865 ms |
| Committee | 36 | 0.204 | 0.042 | 0.116 | 0.210 | 0.067 | 0.136 | 801 | 579 / 135 | 485 / 1473 ms |
| **All** | 232 | **0.212** | **0.036** | **0.114** | 0.197 | 0.039 | 0.113 | 829 | 369 / 112 | 184 / 1473 ms |

- **ROUGE is about a third of the fixture score** (ROUGE-1 0.212 against 0.647) and only just above LEAD:
  +0.015 ROUGE-1, -0.003 ROUGE-2. On the committee meetings LEAD wins on all three scores. The Overview and Key
  points alone score 0.223 / 0.031 / 0.126 against LEAD 0.215 / 0.041 / 0.122 at the same length (235 words).
- The output is 3.3 times longer than the reference (369 against 112 words). The Decisions and Action items
  sections fill up with false hits (3.0 decisions and 3.8 action items per meeting on average), which costs
  precision.
- The references are third-person prose ("The team agreed on ..."). Extracted sentences are first-person speech
  ("Okay, so um, we ..."), which hurts ROUGE-2 most. This gap is the case for an abstractive Overview model later.
- **Speed and memory on real lengths:** 184 ms per meeting on average (AMI 81 ms, ICSI 239 ms, committee
  485 ms). The slowest meeting took 1.4 to 2.7 s across four runs, because other jobs shared the machine. The
  longest meeting (ICSI Bmr003: 2,393 sentences, 21.6k words) takes 1.0 s and about 210 MB peak RSS on its own.
  The whole 232-meeting run peaks at 355 to 650 MB across four runs. The dense TF-IDF and similarity matrices dominate, so the fixtures' 30 MB does
  not hold for an hour-long meeting. A port should use sparse vectors.

**textrank-minilm + rules** on the same 232 meetings (project-local torch, see Reproduce):

| Corpus | ROUGE-1 | ROUGE-2 | ROUGE-L | LEAD R-1 | LEAD R-2 | LEAD R-L | Output / reference words | Latency mean / max |
|---|---|---|---|---|---|---|---|---|
| AMI | 0.243 | 0.042 | 0.130 | 0.223 | 0.041 | 0.127 | 177 / 112 | 1.7 / 6.6 s |
| ICSI | 0.198 | 0.016 | 0.109 | 0.158 | 0.011 | 0.088 | 195 / 97 | 5.1 / 11.6 s |
| Committee | 0.239 | 0.052 | 0.135 | 0.238 | 0.077 | 0.152 | 435 / 135 | 3.7 / 12.2 s |
| **All** | **0.231** | **0.037** | **0.125** | 0.209 | 0.039 | 0.121 | 222 / 112 | 2.9 / 12.2 s |

MiniLM picks shorter sentences, so its output is 222 words instead of 369 and its raw ROUGE is higher. Against
LEAD at the same length the gain is about the same as TF-IDF's (+0.022 ROUGE-1 against +0.015), and both lose to
LEAD on ROUGE-2. It is 16 times slower, and this harness peaks at 4.3 GB RSS because it embeds all of a meeting's
sentences in one batch; a port would batch them. Action items and decisions are the same rules, so they score the
same.

### Action items with owners

QMSum has no action-item or owner labels: its annotations are topic spans and query-answer pairs. So I measured
on AMI instead. The AMI manual annotations (`ami_public_manual_1.6.2`, CC BY 4.0) include a hand-written abstractive
summary for each meeting, with an `actions` list whose items name the owner by role ("The marketing expert will
prepare a trendwatching report."). QMSum labels AMI speakers with the same four roles (Project Manager, Marketing,
Industrial Designer, User Interface), so owners compare directly.

- **Gold:** 109 of the 137 AMI meetings in QMSum have a non-empty actions list. 205 items name an owner. The owner is
  read from the sentence subject only, with the abbreviations PM, ID and UI accepted. 65 items go to the whole team
  or to "they" and are not scored.
- **Automatic match:** a gold item counts as recovered when a predicted item has the same owner and shares at least
  two content words with it (5-letter prefix match, with stopwords and role words removed).
- **Hand check:** I read all 26 same-owner pairs that share at least one content word, plus 12 random same-owner
  pairs that share none, and judged whether the prediction is the gold task.

| Data | Action items recovered with the right owner |
|---|---|
| Self-written fixtures (3 meetings) | 16 / 16 = 100% |
| AMI, automatic match | 9 / 205 = **4.4%** |
| AMI, hand-judged | about 14 / 205 = **7%** (none of the 12 zero-overlap pairs was a match) |
| AMI, upper bound: the owner said any "I'll" at all | 130 / 205 = 63% |

**This fails the goal's bar of at least 80%** (tracked in https://github.com/backant-io/shepetal/issues/8). Why:
- In AMI most action items are assigned, not volunteered. The project manager reads the next steps, or the group
  agrees on them, and the annotator writes "The industrial designer will work on the components concept." The
  first-person `I'll` rule only fires when the owner says it.
- Most real `I'll` / `I will` sentences are moves inside the meeting, not tasks: "I'll go first", "I'll show you",
  "take this one", "I'll come to that later". The rule returns 450 items on these 109 meetings, and about 14 of
  them are real.
- The fixtures were written with clean commitments ("I'll send the build notes by Friday"), so they rewarded the
  one pattern that real meetings rarely use.
- AMI is a role-play design task with coached assignments, so it is not a perfect stand-in for work meetings. It is
  the only owner-labelled meeting data used here.

Decisions were not scored on real data: AMI also has a `decisions` list, but it is not matched yet.

### Fixtures against real data

| | Fixtures | QMSum / AMI |
|---|---|---|
| Meetings | 3, self-written | 232 real (137 AMI, 59 ICSI, 36 committee) |
| Length | 480-690 words | 6k-14k words on average, up to 23.7k |
| ROUGE-1 / 2 / L | 0.647 / 0.426 / 0.448 | 0.212 / 0.036 / 0.114 (LEAD 0.197 / 0.039 / 0.113) |
| Action items with right owner | 100% | 4-7% |
| Latency per meeting | 12-45 ms | about 190 ms mean, 1.4-2.7 s max |
| Peak RSS | 30 MB | 210 MB for the longest meeting alone, 355-650 MB for a full run |

The fixtures overstate quality badly. Treat them as a regression test for the rules, not as a quality number.

## Recommendation

| Platform | Default | Fallback |
|---|---|---|
| Mac | TF-IDF TextRank + rules (no model; on real meetings about 190 ms mean, up to 2.7 s, a few hundred MB RSS) | MiniLM-L6 TextRank via CoreML (90 MB), optional |
| iPhone | TF-IDF TextRank + rules | MiniLM-L6 CoreML encoder on the ANE |
| Linux CPU | TF-IDF TextRank + rules | MiniLM-L6 via ONNX Runtime |

MiniLM did not clearly beat TF-IDF on the fixtures or on QMSum (about +0.007 ROUGE-1 more over LEAD, at 16
times the latency plus a 90 MB model and a runtime), so TF-IDF stays the default and MiniLM stays optional. Both paths are deterministic and
hallucination-free. The action-item rule must be rebuilt before the summarizer meets the goal (issue #8): on real
meetings it is the weakest part, not the strongest. Add a seq2seq model only for the Overview line, once it has been measured: distilBART-CNN-12-6 or
a SAMSum fine-tune on Mac and Linux. Re-evaluate NCM when a meeting or dialogue checkpoint and a non-CUDA path
exist; issue #12 tracks this.

## Long transcripts

- Extractive: no context limit. TextRank runs over all sentences with an O(n^2) dense similarity matrix. Measured:
  2,393 sentences (21.6k words) take 1.0 s and about 210 MB. At 5k sentences the matrices alone pass 400 MB, so
  for longer meetings rank per 10-minute window and then rank the winners.
- Seq2seq: `chunks()` packs whole speaker turns up to the model limit (1024 tokens for BART, 512 for T5/NCM),
  summarizes each chunk and dedupes the result. LED / LongT5 accept 16k tokens if the chunk seams hurt quality.
- Decisions and action items always run on the full transcript with the rules, so chunking never drops them.

## Embedding

- **Swift (Mac/iPhone):** convert all-MiniLM-L6-v2 with `coremltools` (`ct.convert` of the traced
  `AutoModel`, fp16, flexible sequence length up to 128) to `MiniLM.mlpackage`. Tokenize with
  swift-transformers' `BertTokenizer`. Mean-pool, then run TextRank in Swift with Accelerate (`vDSP` mat-mul plus
  50 power iterations). Port the regex rules to `NSRegularExpression`. For a seq2seq model, use ONNX Runtime's Swift
  package (`onnxruntime-objc`) with the `optimum` export (encoder plus decoder-with-past) and a host-side beam loop.
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
mkdir -p .cache/ami && curl -sSLo .cache/ami/m.zip https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/ami_public_manual_1.6.2.zip
unzip -q -o .cache/ami/m.zip 'abstractive/*' -d .cache/ami
.venv/bin/python -I eval_qmsum.py                      # textrank-tfidf, about 40 s for 232 meetings

# Optional MiniLM ranker: its own torch in this venv (torch 2.14.1, transformers 5.20.2 on 2026-10-20)
.venv/bin/pip install torch transformers
.venv/bin/python summarize.py textrank-minilm        # expects .cache/minilm (all-MiniLM-L6-v2 files)
.venv/bin/python -I eval_qmsum.py textrank-minilm
.venv/bin/python summarize.py seq2seq sshleifer/distilbart-cnn-12-6   # not measured yet
```

The venv is project-local and must not borrow packages from another checkout. Model files and corpora go to
`summarize/.cache` (gitignored). Never commit weights or corpus text.
