# Meeting summarization

Shepetal turns a speaker-labelled transcript into four sections: **Overview**, **Key points**, **Decisions**
and **Action items (owner, task, due)**. It runs fully on the device and uses no decoder-only chat LLM.

Code: `summarize/summarize.py`. Fixtures and reference summaries: `summarize/fixtures/`. Sample outputs: `summarize/out/`.

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

## Measured results (M4 Pro, 24 GB, CPU, 3 synthetic meetings of 480 to 690 words, about 4 to 5 min of speech each)

ROUGE F1 is computed on the whole four-section output against the hand-written reference, using lowercase words
without stemming. Latency is per meeting after the model has loaded. Peak RAM is the process max RSS.

| Approach | ROUGE-1 | ROUGE-2 | ROUGE-L | Latency / meeting | Model load | Peak RSS |
|---|---|---|---|---|---|---|
| textrank-tfidf + rules | 0.647 | 0.426 | 0.448 | 26-45 ms | 0 s | 30 MB |
| textrank-minilm + rules | 0.628 | 0.421 | 0.471 | 236 ms | 5.0 s (mostly torch import) | 388 MB (PyTorch runtime; the model is 90 MB) |

Decisions and action items come from the same rules in both rows. Only the Overview and Key points differ, and on
these fixtures the two rankers are a tie: TF-IDF is slightly ahead on ROUGE-1, MiniLM slightly ahead on ROUGE-L.

**Manual check (textrank-tfidf, see `summarize/out/`):**
- Action items are the strongest part: all 16 reference action items were found with the right owner and due
  date, plus 2 extra minor commitments. Weak spots: pronoun tasks ("Tom: open it"), and an assignment phrased as
  "Tom, you will ..." is only caught when the owner confirms it in the first person.
- Decisions: most were found, but sentences phrased as a plan ("So the plan is the fix goes into 2.4") fall into
  Key points, and recap sentences sometimes repeat a decision.
- The Overview is a sentence copied from the transcript, so it reads as speech ("We have about ten minutes, so
  I'd like to cover ..."). An abstractive model would help most here.
- These rules were written against these same three fixtures, so the scores are optimistic. Validate them on
  real transcripts (AMI or QMSum) before relying on the numbers.

## Recommendation

| Platform | Default | Fallback |
|---|---|---|
| Mac | TF-IDF TextRank + rules (no model, about 30 MB RSS, under 50 ms) | MiniLM-L6 TextRank via CoreML (90 MB) |
| iPhone | TF-IDF TextRank + rules | MiniLM-L6 CoreML encoder on the ANE |
| Linux CPU | TF-IDF TextRank + rules | MiniLM-L6 via ONNX Runtime |

MiniLM did not beat TF-IDF on these fixtures, so it does not earn its 90 MB as the default. Switch to it only if
real transcripts, which have more paraphrase than these, show a gain. Both paths are deterministic and
hallucination-free, and both stay well under a second per meeting. Add a seq2seq model only for the Overview line, once it has been measured: distilBART-CNN-12-6 or
a SAMSum fine-tune on Mac and Linux. Re-evaluate NCM when a meeting or dialogue checkpoint and a non-CUDA path
exist.

## Long transcripts

- Extractive: no context limit. TextRank runs over all sentences (O(n^2) similarity, fine up to about 5k
  sentences, roughly 8 h of speech). For longer meetings, rank per 10-minute window and then rank the winners.
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
cd summarize && python3 -m venv .venv && .venv/bin/pip install numpy torch transformers
.venv/bin/python summarize.py textrank-tfidf
.venv/bin/python summarize.py textrank-minilm        # expects .cache/minilm (all-MiniLM-L6-v2 files)
.venv/bin/python summarize.py seq2seq sshleifer/distilbart-cnn-12-6   # not measured yet
```

Model files go to `summarize/.cache` (gitignored). Never commit weights.
