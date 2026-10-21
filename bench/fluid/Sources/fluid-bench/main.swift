// usage: fluid-bench               download Parakeet TDT 0.6B v3 into FluidAudio's default cache, load it, print its dir
//        fluid-bench A.wav B.wav   also print one JSON line per file: {"f", "text", "lat"} (seconds, samples already in memory)
// The first JSON line is {"load", "dir"}: CoreML load + ANE compile time after the download.
// FLUID_ENCODER=int8 (default, FluidAudio's own default) | int8-v2 | int4 picks the encoder build.
// FLUID_ITN=1 runs FluidAudio's NeMo inverse text normalization on the text, inside the timed span.
// FLUID_VOCAB=a,b,c rescores the text against those dictionary terms with the CTC 110M keyword model, as the app
// does (F39, KeywordBooster in Sources/Shepetal/Speech.swift), inside the timed span. The keyword model is
// downloaded into FluidAudio's default cache if missing.
import FluidAudio
import Foundation

func json(_ o: [String: Any]) {
    print(String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!)
}

let files = CommandLine.arguments.dropFirst()
let enc = ProcessInfo.processInfo.environment["FLUID_ENCODER"] ?? "int8"
let itn = ProcessInfo.processInfo.environment["FLUID_ITN"] == "1"
guard let precision = ParakeetEncoderPrecision(rawValue: enc) else { fatalError("unknown FLUID_ENCODER \(enc)") }
nonisolated(unsafe) var lastPct = -1  // progress lines only; a race can at worst print a duplicate line
let dir = try await AsrModels.download(version: .v3, encoderPrecision: precision) { p in
    let pct = Int(p.fractionCompleted * 100)
    if pct / 5 != lastPct / 5 { lastPct = pct; FileHandle.standardError.write("download \(pct)% \(p.phase)\n".data(using: .utf8)!) }
}
let clock = ContinuousClock()
var t = clock.now
let asr = AsrManager()
try await asr.loadModels(try await AsrModels.load(from: dir, version: .v3, encoderPrecision: precision))
let secs = { (d: Duration) in Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
let load = secs(clock.now - t)
if files.isEmpty { print(dir.path); exit(0) }
json(["load": load, "dir": dir.path])

var boost: VocabularyBoostingSession?
if let terms = ProcessInfo.processInfo.environment["FLUID_VOCAB"]?.split(separator: ",").map(String.init), !terms.isEmpty {
    let ctc = try await CtcModels.load(from: try await CtcModels.download())
    let vocabulary = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) },
                                             minSimilarity: 0.7)  // KeywordBooster.minSimilarity
    boost = try await VocabularyBoostingSession(vocabulary: vocabulary, ctcModels: ctc,
                                                config: .init(spotterRescueEnabled: false))  // KeywordBooster.config
}

let conv = AudioConverter()
for (i, f) in ([files.first!] + files).enumerated() {  // first pass over file 1 is the warm-up, not printed
    let samples = try conv.resampleAudioFile(path: f)
    var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
    t = clock.now
    let r = try await asr.transcribe(samples, decoderState: &state)
    var text = r.text
    if let boost, let out = await boost.rescore(text: text, tokenTimings: r.tokenTimings ?? [], audioSamples: samples) { text = out.text }
    if itn { text = TextNormalizer.shared.normalizeSentence(text) }
    let lat = secs(clock.now - t)
    if i > 0 { json(["f": (f as NSString).lastPathComponent, "text": text, "lat": lat]) }
}
