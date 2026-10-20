import Foundation
import ShepetalCore
import ShepetalSummary

/// `shepetal --e2e-meeting <me.wav> <others.wav>`: a meeting through the real transcriber, store and summarizer,
/// with no capture and no UI. Both files are written into a new meeting folder under the data dir the way the
/// recorder writes them: the header first with its sizes still 0, then 30 s at a time with a live pass after each,
/// then the closed file. Prints one JSON object.
enum MeetingE2E {
    static func main(_ args: [String]) -> Never {
        Task { @MainActor in exit(await run(args)) }
        dispatchMain()
    }

    @MainActor
    static func run(_ args: [String]) async -> Int32 {
        guard args.count >= 2 else {
            print(json(["error": "usage: shepetal --e2e-meeting <me.wav> <others.wav>"]))
            return 2
        }
        do {
            print(json(try await meeting(me: args[0], others: args[1])))
            return 0
        } catch {
            print(json(["error": "\(error)"]))
            return 1
        }
    }

    @MainActor
    private static func meeting(me: String, others: String) async throws -> [String: Any] {
        let id = UUID().uuidString
        let dir = Paths.root.appendingPathComponent("meetings").appendingPathComponent(id)
        for d in [Paths.root, dir.deletingLastPathComponent(), dir] { try AudioStore.makeOwnerOnlyDirectory(d) }
        let sources = try [me, others].map { try Resampler.read(URL(fileURLWithPath: $0)) }
        let meeting = Meeting(id: id, app: "E2E Meeting", startedAt: Date(),
                              meAudioPath: dir.appendingPathComponent("Me.wav").path,
                              othersAudioPath: dir.appendingPathComponent("Others.wav").path)
        let dbURL = Paths.root.appendingPathComponent("meetings.sqlite")
        let store = try MeetingStore(path: dbURL)
        try store.save(meeting)
        let engine = try await Speech.load()
        let transcriber = MeetingTranscriber(meeting: meeting, engine: engine, store: store,
                                             summarizer: try MeetingSummarizer())

        // Recording: a header that still says 0 samples, then the audio in 30 s steps with a live pass after each,
        // as the live timer does.
        let files = [meeting.meAudioPath, meeting.othersAudioPath]
        for f in files { try write(f, AudioStore.wav([])) }
        let step = Int(MeetingTranscriber.chunkSeconds) * AudioStore.sampleRate
        var live = 0
        var written = 0
        while written + step <= sources.map(\.count).max() ?? 0 {
            for (f, s) in zip(files, sources) where written < s.count {
                let h = try FileHandle(forWritingTo: URL(fileURLWithPath: f))
                try h.seekToEnd()
                try h.write(contentsOf: Array(s[written..<min(s.count, written + step)]).withUnsafeBufferPointer { Data(buffer: $0) })
                try h.close()
            }
            written += step
            live += try await transcriber.poll().count
        }
        let storedLive = try store.get(id)?.segments.count ?? -1
        // Stop: the recorder writes the last seconds and closes both files (the final header), and the meeting
        // gets its end time. The final pass takes it from there.
        for (f, s) in zip(files, sources) { try write(f, AudioStore.wav(s)) }
        var ended = meeting
        ended.endedAt = Date()
        try store.save(ended)
        let t0 = ProcessInfo.processInfo.systemUptime
        let record = try await transcriber.finish()
        let finishMs = Int((ProcessInfo.processInfo.systemUptime - t0) * 1000)

        // Read back through a new connection, as the meetings window opens it.
        let reopened = try MeetingStore(path: dbURL)
        let stored = try reopened.get(id)
        let query = record.segments.filter { $0.speaker == .others }.flatMap { $0.text.split(separator: " ") }
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }.max { $0.count < $1.count }?.uppercased() ?? ""
        func segs(_ s: [Segment]) -> [[String: Any]] {
            s.map { ["speaker": $0.speaker.rawValue, "start": $0.start, "end": $0.end, "text": $0.text] }
        }
        func summary(_ s: Summary?) -> Any {
            guard let s else { return NSNull() }
            return ["overview": s.overview, "key_points": s.keyPoints, "decisions": s.decisions,
                    "action_items": s.actionItems.map { ["owner": $0.owner, "task": $0.task, "due": $0.due] }]
        }
        return [
            "error": "", "meeting_id": id, "model": engine.name, "finish_ms": finishMs,
            "audio_seconds": sources.map { Double($0.count) / Double(AudioStore.sampleRate) },
            "live_segments": live, "stored_before_finish": storedLive,
            "segments": segs(record.segments), "summary": summary(record.summary),
            "stored_segments": segs(stored?.segments ?? []), "stored_summary": summary(stored?.summary),
            "stored_app": stored?.meeting.app ?? "", "stored_ended": stored?.meeting.endedAt != nil,
            "stored_audio": [stored?.meeting.meAudioPath ?? "", stored?.meeting.othersAudioPath ?? ""],
            "listed": try reopened.list(limit: 50).contains { $0.id == id },
            "search_query": query, "search_hit": try reopened.search(query, limit: 50).contains { $0.id == id },
            "audio_modes": files.map(mode), "dir_mode": mode(dir.path), "db_mode": mode(dbURL.path),
            "scratch_left": FileManager.default.fileExists(atPath: dir.appendingPathComponent(".utterance.wav").path),
        ]
    }

    private static func write(_ path: String, _ data: Data) throws {
        guard FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
        }
    }

    private static func mode(_ path: String) -> String {
        let n = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        return String(n, radix: 8)
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}
