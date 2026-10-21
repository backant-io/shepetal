import FluidAudio
import ShepetalCore
import XCTest
@testable import Shepetal

/// F39 (#30): Parakeet, the default model, takes no prompt, so the personal dictionary reaches it through a keyword
/// model that rescores the text. The rescoring lines words up with the audio by time, so it must get exactly the
/// samples Parakeet heard. The keyword model is 100 MB the user downloads on purpose: a missing one must cost
/// nothing and fetch nothing, and its download must not leave FluidAudio free to re-download models (#78).
/// Hermetic: no model, no Hugging Face (a local stub stands in), no dictionary.txt of the user's.
final class SpeechBoostTests: XCTestCase {
    private final class FakeBooster: VocabularyBooster, @unchecked Sendable {
        var isInstalled = true
        var answer: String? = "boosted"
        var calls: [(text: String, samples: [Float], terms: [String])] = []
        func boost(_ text: String, timings: [TokenTiming], samples: [Float], terms: [String]) async -> String? {
            calls.append((text, samples, terms))
            return answer
        }
    }

    private var heard: [[Float]] = []

    private func engine(_ booster: VocabularyBooster, dictionary: String = "Postgres", says text: String = "post gress") -> ParakeetEngine {
        ParakeetEngine(recognize: { [unowned self] samples in
            heard.append(samples)
            let timing = TokenTiming(token: "▁postgres", tokenId: 1, startTime: 0, endTime: 0.4, confidence: 0.9)
            return ASRResult(text: text, confidence: 0.9, duration: 0.4, processingTime: 0, tokenTimings: [timing])
        }, booster: booster, dictionary: { Vocabulary(dictionary) })
    }

    private let wav = URL(fileURLWithPath: "/dev/null")

    override func tearDown() {
        ModelRegistry.baseURL = "http://127.0.0.1:9"  // never the real Hugging Face, whatever runs next
        ParakeetEngine.stayOffline()
    }

    func testBoosterGetsTheSamplesTheModelHeard() async throws {
        let booster = FakeBooster()
        let short = (0..<1_600).map { Float($0) / 1_600 }  // 0.1 s: Parakeet needs padding to hear it
        let text = try await engine(booster).transcribe(short, wav: wav)
        XCTAssertEqual(text, "boosted", "the rescored text is what the user gets")
        XCTAssertEqual(heard.count, 1)
        XCTAssertEqual(booster.calls.count, 1)
        XCTAssertEqual(booster.calls.first?.samples, heard.first, "timings and audio must be on the same clock")
        XCTAssertEqual(booster.calls.first?.samples.count, ASRConstants.minimumRequiredSamples(forSampleRate: AudioStore.sampleRate))
        XCTAssertEqual(booster.calls.first?.text, "post gress")
    }

    func testDictionaryReachesTheBoosterStarredFirstWithItsCasing() async throws {
        let booster = FakeBooster()
        _ = try await engine(booster, dictionary: "# comment\nuseEffect\n*Postgres\nredis => Redis").transcribe([0.1], wav: wav)
        // A replacement is boosted by its spoken side; the dictionary's own rule then writes the other side.
        XCTAssertEqual(booster.calls.first?.terms, ["Postgres", "useEffect", "redis"])

        let many = FakeBooster()
        _ = try await engine(many, dictionary: (0..<250).map { "word\($0)" }.joined(separator: "\n")).transcribe([0.1], wav: wav)
        XCTAssertEqual(many.calls.first?.terms.count, Vocabulary.promptLimit)
    }

    func testNoBoostWithoutTheKeywordModelOrADictionary() async throws {
        let missing = FakeBooster()
        missing.isInstalled = false
        let plain = try await engine(missing).transcribe([0.1], wav: wav)
        XCTAssertEqual(plain, "post gress")
        XCTAssertTrue(missing.calls.isEmpty, "a missing keyword model is skipped, not loaded")

        let empty = FakeBooster()
        let unboosted = try await engine(empty, dictionary: "# only the header\n").transcribe([0.1], wav: wav)
        XCTAssertEqual(unboosted, "post gress")
        XCTAssertTrue(empty.calls.isEmpty, "an empty dictionary costs nothing")
    }

    func testFailedBoostKeepsTheModelText() async throws {
        let failing = FakeBooster()
        failing.answer = nil
        let text = try await engine(failing).transcribe([0.1], wav: wav)
        XCTAssertEqual(text, "post gress")
        XCTAssertEqual(failing.calls.count, 1)
    }

    /// The keyword model knows English only, while Parakeet on Automatic writes 25 languages. On this Mac it wrote
    /// "Las redes sociales" as "Las Redis sociales" with Redis in the dictionary (docs/models.md).
    func testADictationInAnotherLanguageKeepsTheModelText() async throws {
        for text in ["Las redes sociales están llenas de ruido hoy.", "Wir haben den Cache von Redis auf Postgres verschoben.",
                     "Nous avons déplacé le cache de Rodiver Postgre.", "Abbiamo spostato la cache da reddis a postgress."] {
            let booster = FakeBooster()
            let out = try await engine(booster, dictionary: "Redis\nPostgres", says: text).transcribe([0.1], wav: wav)
            XCTAssertEqual(out, text)
            XCTAssertTrue(booster.calls.isEmpty, "not boosted: \(text)")
        }
        // English, and dictations too short to tell, are boosted; so is the launch warm-up, which hears nothing.
        for text in ["We moved the cache from Redis to postgars.", "Redis.", "Postgres.", "npm install.", "post gress", ""] {
            let booster = FakeBooster()
            _ = try await engine(booster, says: text).transcribe([0.1], wav: wav)
            XCTAssertEqual(booster.calls.count, 1, "boosted: \(text)")
        }
    }

    /// The rescorer's own text drops the punctuation of a word it replaces; the user's sentence must keep it.
    func testRescoredTermsKeepTheSentencePunctuation() {
        XCTAssertEqual(KeywordBooster.replacing([("postgars.", "Postgres"), ("redisc", "Redis")],
                                                in: "We moved the redisc cache to postgars."),
                       "We moved the Redis cache to Postgres.")
        XCTAssertEqual(KeywordBooster.replacing([("use effect", "useEffect")], in: "Call the use effect hook, then log."),
                       "Call the useEffect hook, then log.")
        XCTAssertEqual(KeywordBooster.replacing([("PostGer's", "Postgres")], in: "the PostGer's replica, and"),
                       "the Postgres replica, and")
        XCTAssertEqual(KeywordBooster.replacing([("postgars", "Postgres")], in: "xpostgars and postgarsy, postgars?"),
                       "xpostgars and postgarsy, Postgres?", "whole words only")
        XCTAssertEqual(KeywordBooster.replacing([("nowhere", "Redis"), (".", "Redis")], in: "Nothing to do."), "Nothing to do.")
    }

    func testMissingKeywordModelFetchesNothing() async throws {
        let hub = try StubServer()
        ModelRegistry.baseURL = hub.url.absoluteString
        ModelHub.offlineMode = false  // the worst case: even with the network allowed
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("boost-\(UUID().uuidString)/parakeet-ctc-110m-coreml")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let booster = KeywordBooster(directory: dir)

        XCTAssertFalse(booster.isInstalled)
        let none = await booster.boost("post gress", timings: [], samples: [0.1], terms: ["Postgres"])
        XCTAssertNil(none)
        let text = try await engine(booster).transcribe([0.1], wav: wav)
        XCTAssertEqual(text, "post gress")
        XCTAssertTrue(hub.requests.isEmpty, "nothing may download without the user asking: \(hub.requests.map(\.path))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testDownloadRestoresOfflineMode() async throws {
        let hub = try StubServer()  // 404 for everything
        ModelRegistry.baseURL = hub.url.absoluteString
        ParakeetEngine.stayOffline()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("boost-\(UUID().uuidString)/parakeet-ctc-110m-coreml")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

        do {
            try await KeywordBooster.download(to: dir)
            XCTFail("the stub has no model")
        } catch {}
        XCTAssertFalse(hub.requests.isEmpty, "the download itself has to reach the network")
        XCTAssertTrue(ModelHub.offlineMode, "after the download FluidAudio may not fetch models on its own again")
    }

    /// The keyword model's line in the 🤫 menu: nothing on a normal day (#210 keeps that menu at 12 items), and
    /// only for someone whose dictionary the default model would otherwise ignore.
    @MainActor
    func testMenuOffersTheDownloadOnlyWhenTheDictionaryNeedsIt() {
        let menu = SpeechMenu()
        let missing = FakeBooster()
        missing.isInstalled = false
        menu.booster = missing
        menu.dictionary = { Vocabulary("Postgres") }
        XCTAssertEqual(menu.dictionarySupport(speechInstalled: true), .offered)
        XCTAssertNil(menu.dictionarySupport(speechInstalled: false), "speech recognition's own download comes first")
        menu.dictionary = { Vocabulary("# only the header\n") }
        XCTAssertNil(menu.dictionarySupport(speechInstalled: true), "no dictionary words: nothing to boost, nothing to offer")
        menu.dictionary = { Vocabulary("Postgres") }
        menu.booster = FakeBooster()
        XCTAssertNil(menu.dictionarySupport(speechInstalled: true), "installed: nothing to offer")
    }

    /// One download at a time, shown as running until it is done, and the keyword model loaded before "ready", so
    /// the first dictation after it does not wait for the load.
    @MainActor
    func testDownloadShowsWhileItRunsThenLoadsTheKeywordModel() async throws {
        let menu = SpeechMenu()
        let booster = FakeBooster()
        booster.isInstalled = false
        var downloads = 0, notices: [String] = [], failures: [String] = []
        menu.booster = booster
        menu.dictionary = { Vocabulary("Redis\n*Postgres") }
        menu.downloadBooster = { downloads += 1; booster.isInstalled = true }
        menu.notice = { notices.append($0) }
        menu.fail = { failures.append($0) }

        let task = try XCTUnwrap(menu.downloadBoost())
        XCTAssertEqual(menu.dictionarySupport(speechInstalled: true), .downloading)
        XCTAssertNil(menu.downloadBoost(), "a second click starts no second download")
        await task.value
        XCTAssertEqual(downloads, 1)
        XCTAssertEqual(booster.calls.map(\.terms), [["Postgres", "Redis"]], "loaded with the user's own terms")
        XCTAssertEqual(notices, ["Downloading dictionary support…", "Dictionary support is ready"])
        XCTAssertEqual(failures, [])
        XCTAssertNil(menu.dictionarySupport(speechInstalled: true), "installed: the line leaves the menu")

        // A failed download says so in plain words, loads nothing and offers the download again.
        let offline = FakeBooster()
        offline.isInstalled = false
        menu.booster = offline
        menu.downloadBooster = { throw URLError(.notConnectedToInternet) }
        await menu.downloadBoost()?.value
        XCTAssertEqual(failures, ["Download failed: check the internet connection and try again"])
        XCTAssertTrue(offline.calls.isEmpty)
        XCTAssertEqual(menu.dictionarySupport(speechInstalled: true), .offered)
    }
}
