"""Run one STT engine over bench/fixtures and print a JSON summary line.

usage: bench.py ENGINE   (parakeet-v3 | parakeet-110m | moonshine-tiny | moonshine-base | sensevoice | wcpp-<ggml model name>
                         | fluid-parakeet-v3[-int8-v2|-int4|-itn]: FluidAudio CoreML through bench/fluid, model in FluidAudio's default cache)
Latency = wall time from "whole utterance available" to text (model load excluded), i.e. time-to-text
after end of audio for push-to-talk dictation. RTF = latency / audio seconds.
"""
import glob, json, os, re, resource, subprocess, sys, time, wave
import jiwer

HERE = os.path.dirname(os.path.abspath(__file__))
C = os.path.join(HERE, ".cache")
FIX = sorted(glob.glob(os.path.join(HERE, "fixtures", "*.wav")))
NUM = "zero one two three four five six seven eight nine ten".split()

def norm(s):
    s = s.lower().replace("%", " percent").replace("$", " dollars ")
    s = re.sub(r"(\d),(\d)", r"\1\2", s)
    s = re.sub(r"(\d)(st|nd|rd|th)\b", r"\1", s)
    s = re.sub(r"(\d)([a-z])", r"\1 \2", s)
    s = re.sub(r"[^a-z0-9' ]+", " ", s.replace(".", "").replace("-", " "))
    return " ".join(str(NUM.index(w)) if w in NUM else w for w in s.split())

def dur(p):
    with wave.open(p) as w:
        return w.getnframes() / w.getframerate()

def sherpa(kind):
    import sherpa_onnx as so, soundfile as sf
    t = time.perf_counter()
    if kind == "parakeet-110m":  # TDT-CTC hybrid, exported as CTC
        d = f"{C}/sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8"
        r = so.OfflineRecognizer.from_nemo_ctc(model=f"{d}/model.int8.onnx", tokens=f"{d}/tokens.txt", num_threads=4)
    elif kind == "parakeet-v3":
        d = f"{C}/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8"
        r = so.OfflineRecognizer.from_transducer(encoder=f"{d}/encoder.int8.onnx", decoder=f"{d}/decoder.int8.onnx",
            joiner=f"{d}/joiner.int8.onnx", tokens=f"{d}/tokens.txt", model_type="nemo_transducer", num_threads=4)
    elif kind.startswith("moonshine"):
        d = f"{C}/sherpa-onnx-{kind}-en-int8"
        r = so.OfflineRecognizer.from_moonshine(preprocessor=f"{d}/preprocess.onnx", encoder=f"{d}/encode.int8.onnx",
            uncached_decoder=f"{d}/uncached_decode.int8.onnx", cached_decoder=f"{d}/cached_decode.int8.onnx",
            tokens=f"{d}/tokens.txt", num_threads=4)
    else:
        d = glob.glob(f"{C}/sherpa-onnx-sense-voice-*")[0]
        r = so.OfflineRecognizer.from_sense_voice(model=f"{d}/model.int8.onnx", tokens=f"{d}/tokens.txt", use_itn=True, num_threads=4)
    load = time.perf_counter() - t
    return (lambda p: timed(r, *sf.read(p, dtype="float32"))), load, d

def timed(r, a, sr):  # time-to-text for one utterance already in memory
    t = time.perf_counter(); s = r.create_stream(); s.accept_waveform(sr, a); r.decode_stream(s)
    return s.result.text, time.perf_counter() - t

def wcpp_lat(stderr):  # whisper-cli's own timings: decode time without model load, in seconds
    ms = lambda k: float(re.search(k + r"\s*=\s*([\d.]+) ms", stderr).group(1)) / 1000
    return ms("total time") - ms("load time")

def wcpp(model):
    m = f"{C}/ggml-{model}.bin"; cli = f"{C}/whisper.cpp/build/bin/whisper-cli"
    def run(p):
        out = subprocess.run([cli, "-m", m, "-f", p, "-nt", "-l", "en", "-t", "4"], capture_output=True, text=True)
        return out.stdout.strip(), wcpp_lat(out.stderr)
    return run, None, m

def fluid(opt):  # "" (FluidAudio defaults) | "int8-v2" | "int4" encoder | "itn" (default encoder + ITN)
    env = dict(os.environ, FLUID_ENCODER=opt if opt not in ("", "itn") else "int8", FLUID_ITN=str(int(opt == "itn")))
    out = subprocess.run([f"{C}/fluid-build/release/fluid-bench", *FIX], capture_output=True, text=True, check=True, env=env).stdout
    head, *rows = [json.loads(l) for l in out.splitlines() if l.startswith("{")]
    res = {r["f"]: (r["text"], r["lat"]) for r in rows}  # the CLI warms up and times every file itself
    return (lambda p: res[os.path.basename(p)]), head["load"], head["dir"]

def score(rows):  # rows as saved in results/<engine>.json
    dic = [r for r in rows if r["f"].startswith("d")]; meet = [r for r in rows if r["f"].startswith("m")]
    return dict(
        wer_dictation=round(jiwer.wer([r["ref"] for r in dic], [r["hyp"] for r in dic]) * 100, 1),
        wer_meeting=round(jiwer.wer(meet[0]["ref"], meet[0]["hyp"]) * 100, 1),
        latency_dictation_ms_mean=round(sum(r["lat"] for r in dic) / len(dic) * 1000),
        latency_meeting_ms=round(meet[0]["lat"] * 1000),
        rtf=round(sum(r["lat"] for r in rows) / sum(r["sec"] for r in rows), 4))

def rss_mb(maxrss, platform=sys.platform):  # ru_maxrss is bytes on macOS, kilobytes on Linux
    return round(maxrss / (2**20 if platform == "darwin" else 2**10))

def size(p):
    if os.path.isfile(p): return os.path.getsize(p)
    return sum(os.path.getsize(os.path.join(a, f)) for a, _, fs in os.walk(p) for f in fs)

if __name__ == "__main__":
    assert norm("At 3pm, 4,250 dollars; two-day fix on the 15th") == "at 3 pm 4250 dollars 2 day fix on the 15"
    e = sys.argv[1]
    run, load, mpath = (sherpa(e) if e.split("-")[0] in ("parakeet", "moonshine", "sensevoice") else
                        wcpp(e[5:]) if e.startswith("wcpp-") else fluid(e[18:]) if e.startswith("fluid-parakeet-v3") else sys.exit(f"unknown engine {e}"))
    run(FIX[0])  # warm-up
    rows = []
    for p in FIX:
        txt, lat = run(p)
        ref = open(p[:-4] + ".txt").read()
        rows.append(dict(f=os.path.basename(p), sec=dur(p), lat=lat, ref=norm(ref), hyp=norm(txt), raw=txt.strip()))
    rss = max(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss, resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss)
    res = dict(engine=e, **score(rows),
        load_s=load and round(load, 2), peak_rss_mb=rss_mb(rss), model_mb=round(size(mpath) / 2**20))
    json.dump(rows, open(os.path.join(HERE, "results", e + ".json"), "w"), indent=1)
    print(json.dumps(res))
