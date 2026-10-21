import Foundation
import ShepetalCleanup
import ShepetalCore

// cleanup-bench <model.gguf|rules> <fixtures.jsonl>
// For each fixture: the model alone on the rules' text (`model`), and the app's path (`app`: rules, cue
// gate, model, word guard), each with its time in ms. Then one summary line: load time, the model's time on
// the 10 s transcripts (five runs each), and peak memory.
let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: cleanup-bench <model.gguf|rules> <fixtures.jsonl>\n".utf8))
    exit(2)
}

func now() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }

func peakMemoryMB() -> (rss: Int, footprint: Int) {
    var ru = rusage()
    getrusage(RUSAGE_SELF, &ru)
    var info = rusage_info_v4()
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    return (Int(ru.ru_maxrss) >> 20, Int(info.ri_lifetime_max_phys_footprint) >> 20)
}

func line(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    print(String(decoding: data, as: UTF8.self))
}

let t0 = now()
let model: CleanupModel?
do { model = args[1] == "rules" ? nil : try LlamaCleanup(path: args[1]) } catch {
    line(["error": error.localizedDescription])
    exit(1)
}
let loadMs = now() - t0

let fixtures = try! String(contentsOfFile: args[2], encoding: .utf8).split(separator: "\n").map {
    try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: String]
}
for f in fixtures {
    let raw = f["raw"]!
    var out: [String: Any] = ["id": f["id"]!]
    if let model {
        let ruled = Cleanup.apply(raw)
        let t = now()
        out["model"] = (try? model.rewrite(ruled)) ?? ""
        out["model_ms"] = now() - t
    }
    let t = now()
    let app = SmartCleanup.apply(raw, model: model)
    out["app_ms"] = now() - t
    out["app"] = app.text
    out["used_model"] = app.usedModel
    line(out)
}
// Latency for a 10 s utterance: each fixture of 24 or more words (about 10 s of speech) five more times.
var longMs: [Double] = []
if let model {
    for f in fixtures where f["raw"]!.split(separator: " ").count >= 24 {
        let ruled = Cleanup.apply(f["raw"]!)
        for _ in 0..<5 {
            let t = now()
            _ = try? model.rewrite(ruled)
            longMs.append(now() - t)
        }
    }
}
let mem = peakMemoryMB()
line(["summary": true, "model": model?.name ?? "rules", "load_ms": loadMs, "long_ms": longMs,
      "peak_rss_mb": mem.rss, "peak_footprint_mb": mem.footprint])
