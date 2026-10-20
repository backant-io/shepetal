import AVFoundation
import Foundation
import ShepetalCore

/// Transcribes a meeting's two kept WAVs, the mic as "Me" and the system audio as "Others", with the dictation
/// speech engine, and summarizes the result with the non-LLM summarizer (rule 6). Each channel is cut into
/// utterances at its pauses (30 s at most), so the segments keep who spoke when.
/// While the meeting runs, `startLive()` reads what the recorder wrote every 30 s and stores the utterances that
/// have ended. `finish()` does the rest of both files and writes the summary.
@MainActor
final class MeetingTranscriber {
    nonisolated static let chunkSeconds = Utterances.maxSeconds

    let meeting: Meeting
    private let engine: SpeechEngine
    private let store: MeetingStoring
    private let summarizer: MeetingSummarizing
    private let channels: [Channel]
    private var live: Task<Void, Never>?

    /// The meeting must already be saved in `store`.
    init(meeting: Meeting, engine: SpeechEngine, store: MeetingStoring, summarizer: MeetingSummarizing) {
        self.meeting = meeting
        self.engine = engine
        self.store = store
        self.summarizer = summarizer
        // "" is a channel the recorder did not write (mic only, without System Audio Recording).
        channels = [(Speaker.me, meeting.meAudioPath), (.others, meeting.othersAudioPath)]
            .filter { !$0.1.isEmpty }.map { Channel($0.0, URL(fileURLWithPath: $0.1)) }
    }

    func startLive(every seconds: Double = chunkSeconds) {
        live = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self else { return }
                // A failed pass leaves its audio pending, for the next pass or for finish().
                _ = try? await self.poll()
            }
        }
    }

    /// One live pass: the audio written since the last pass, and the utterances in it that have ended.
    @discardableResult
    func poll() async throws -> [Segment] { try await pass(final: false) }

    /// After the recording stopped: the rest of both files, then the summary of the whole meeting.
    func finish() async throws -> MeetingRecord {
        live?.cancel()
        await live?.value  // a pass in flight completes first; two passes never overlap
        live = nil
        defer { try? FileManager.default.removeItem(at: scratchDir.appendingPathComponent(".utterance.wav")) }
        try await pass(final: true)
        guard var record = try store.get(meeting.id) else { throw SpeechError("Meeting \(meeting.id) is not saved") }
        let summary = summarizer.summarize(record.segments)
        try store.setSummary(summary, for: meeting.id)
        record.summary = summary
        return record
    }

    @discardableResult
    private func pass(final: Bool) async throws -> [Segment] {
        var out: [Segment] = []
        for ch in channels {
            while try ch.readMore() {  // in blocks, so a long meeting never sits in memory whole
                out += try await transcribe(ch, final: false)
            }
            if final {
                try ch.flush()
                out += try await transcribe(ch, final: true)
            }
        }
        return out
    }

    /// Transcribes the utterances in the channel's pending audio and stores them before dropping that audio.
    private func transcribe(_ ch: Channel, final: Bool) async throws -> [Segment] {
        let (spans, done) = Utterances.cut(ch.pending, final: final)
        let rate = Double(AudioStore.sampleRate)
        var segments: [Segment] = []
        var kept = done
        var failure: Error?
        for span in spans {
            var samples = Array(ch.pending[span])
            // The model needs a little audio around a short "yes"; silence after it changes nothing.
            if samples.count < AudioStore.sampleRate { samples += [Float](repeating: 0, count: AudioStore.sampleRate - samples.count) }
            do {
                let text = try await engine.transcribe(samples, wav: try scratchWAV(samples))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    segments.append(Segment(speaker: ch.speaker, start: Double(ch.base + span.lowerBound) / rate,
                                            end: Double(ch.base + span.upperBound) / rate, text: text))
                }
            } catch {
                kept = span.lowerBound  // this utterance and the rest stay pending
                failure = error
                break
            }
        }
        try store.append(segments, to: meeting.id)  // stored before its audio is dropped from memory
        ch.drop(kept)
        if let failure { throw failure }
        return segments
    }

    /// The whisper.cpp fallback reads a file, not samples. It lives next to the meeting audio (owner-only, never
    /// /tmp) and is overwritten by the next utterance.
    private func scratchWAV(_ samples: [Float]) throws -> URL {
        try AudioStore(dir: scratchDir).save(samples, id: ".utterance")
    }

    private var scratchDir: URL {
        URL(fileURLWithPath: meeting.meAudioPath.isEmpty ? meeting.othersAudioPath : meeting.meAudioPath).deletingLastPathComponent()
    }
}

/// One channel: its growing WAV, the resampler to 16 kHz mono, and the 16 kHz audio not yet transcribed.
@MainActor
final class Channel {
    let speaker: Speaker
    private let tail: WavTail
    private var resampler: Resampler?
    private(set) var pending: [Float] = []
    /// The 16 kHz sample index of `pending[0]` from the start of the file.
    private(set) var base = 0

    init(_ speaker: Speaker, _ url: URL) {
        self.speaker = speaker
        tail = WavTail(url)
    }

    /// Adds up to a minute of new audio. False when nothing new was written.
    func readMore() throws -> Bool {
        guard let buffer = try tail.read(maxSeconds: 60) else { return false }
        if resampler == nil {
            guard let r = Resampler(from: buffer.format) else { throw SpeechError("Cannot convert \(tail.url.lastPathComponent)") }
            resampler = r
        }
        pending += resampler!.convert(buffer)
        return true
    }

    /// The end of the recording: what the resampler still holds. The file must exist by now.
    func flush() throws {
        guard FileManager.default.fileExists(atPath: tail.url.path) else {
            throw SpeechError("Meeting audio missing: \(tail.url.path)")
        }
        pending += resampler?.convert(nil) ?? []
        resampler = nil
    }

    func drop(_ n: Int) {
        pending.removeFirst(n)
        base += n
    }
}

/// Reads a WAV that may still be growing: each call returns the whole frames written since the last one.
/// While a recorder writes, the header's sizes are still 0, so the data runs to the end of the file; once it is
/// closed, the data chunk's size marks the end.
final class WavTail {
    let url: URL
    private var format: AVAudioFormat?
    private var dataStart: UInt64 = 0
    private var read: UInt64 = 0

    init(_ url: URL) { self.url = url }

    func read(maxSeconds: Double) throws -> AVAudioPCMBuffer? {
        guard let h = FileHandle(forReadingAtPath: url.path) else { return nil }  // not written yet
        defer { try? h.close() }
        let size = try h.seekToEnd()
        if format == nil {
            try h.seek(toOffset: 0)
            guard try parseHeader(h.read(upToCount: 65_536) ?? Data()) else { return nil }
        }
        guard let format else { return nil }
        try h.seek(toOffset: dataStart - 4)
        let declared = UInt64(try h.read(upToCount: 4).map { $0.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } } ?? 0)
        let end = declared > 0 && dataStart + declared <= size ? dataStart + declared : size
        let frameBytes = UInt64(format.streamDescription.pointee.mBytesPerFrame)
        let frames = min((end - min(end, dataStart + read)) / frameBytes, UInt64(maxSeconds * format.sampleRate))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        try h.seek(toOffset: dataStart + read)
        let data = try h.read(upToCount: Int(frames * frameBytes)) ?? Data()
        guard UInt64(data.count) == frames * frameBytes else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.copyBytes(to: buffer.mutableAudioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: UInt8.self), count: data.count)
        read += UInt64(data.count)
        return buffer
    }

    /// Finds "fmt " and "data" among the chunks (`say` and AVAudioFile put JUNK and FLLR before them).
    /// False while the header is not all written yet.
    private func parseHeader(_ d: Data) throws -> Bool {
        let b = [UInt8](d)
        func u16(_ i: Int) -> UInt32 { UInt32(b[i]) | UInt32(b[i + 1]) << 8 }
        func u32(_ i: Int) -> UInt32 { u16(i) | u16(i + 2) << 16 }
        guard b.count >= 12 else { return false }
        guard b[0..<4].elementsEqual("RIFF".utf8), b[8..<12].elementsEqual("WAVE".utf8) else {
            throw SpeechError("\(url.lastPathComponent) is not a WAV file")
        }
        var i = 12
        var fmt: AVAudioFormat?
        while i + 8 <= b.count {
            let id = String(decoding: b[i..<i + 4], as: UTF8.self)
            let len = Int(u32(i + 4))
            if id == "data" {
                guard let fmt else { throw SpeechError("\(url.lastPathComponent) has no format before its data") }
                format = fmt
                dataStart = UInt64(i + 8)
                return true
            }
            if id == "fmt " {
                guard i + 8 + 16 <= b.count else { return false }
                var tag = u16(i + 8)
                if tag == 0xFFFE, len >= 40, i + 8 + 26 <= b.count { tag = u16(i + 8 + 24) }  // extensible: the subformat
                let channels = u16(i + 10), rate = u32(i + 12), align = u16(i + 20), bits = u16(i + 22)
                let float = tag == 3 && (bits == 32 || bits == 64)
                guard float || (tag == 1 && [16, 24, 32].contains(bits)), channels > 0, align == channels * bits / 8 else {
                    throw SpeechError("\(url.lastPathComponent): unsupported WAV format \(tag), \(bits) bit")
                }
                var asbd = AudioStreamBasicDescription(
                    mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
                    mFormatFlags: (float ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) | kAudioFormatFlagIsPacked,
                    mBytesPerPacket: align, mFramesPerPacket: 1, mBytesPerFrame: align, mChannelsPerFrame: channels,
                    mBitsPerChannel: bits, mReserved: 0)
                fmt = AVAudioFormat(streamDescription: &asbd)
            }
            i += 8 + len + (len & 1)
        }
        if d.count >= 65_536 { throw SpeechError("\(url.lastPathComponent): no audio data in the first 64 KB") }
        return false
    }
}

/// Cuts 16 kHz mono audio into utterances at pauses. Pure, so it is tested without a model.
enum Utterances {
    static let frame = 480                       // 30 ms
    /// RMS above this is speech. ponytail: a fixed level (about -50 dBFS); make it follow the noise floor if a
    /// noisy mic keeps every utterance at the 30 s cap.
    static let threshold: Float = 0.003
    static let pauseFrames = 16                  // about 0.5 s of quiet ends an utterance
    static let pad = 3_200                       // 0.2 s kept around the speech
    static let maxSeconds = 30.0
    static let maxFrames = Int(maxSeconds * 16_000) / frame
    static let cutWindow = 166                   // a long utterance is cut at its quietest 30 ms in the last 5 s

    /// The ranges of `s` that hold speech, in order and not overlapping, and how many leading samples are done
    /// with. Unless `final`, an utterance still running at the end is left for the next call.
    static func cut(_ s: [Float], final: Bool) -> (spans: [Range<Int>], done: Int) {
        let frames = final ? (s.count + frame - 1) / frame : s.count / frame
        let level = (0..<frames).map { f -> Float in
            let r = s[f * frame..<min(s.count, (f + 1) * frame)]
            return (r.reduce(0) { $0 + $1 * $1 } / Float(r.count)).squareRoot()
        }
        var spans: [Range<Int>] = []
        var open: Int?   // start sample of the utterance being read
        var last = 0     // its last speech frame
        func close(at end: Int) {
            if let o = open, end > o { spans.append(o..<end) }
            open = nil
        }
        for f in 0..<frames {
            if level[f] > threshold {
                if open == nil { open = max(spans.last?.upperBound ?? 0, f * frame - pad) }
                last = f
            } else if open != nil, f - last >= pauseFrames {
                close(at: min(s.count, (last + 1) * frame + pad))
            }
            if let o = open, (f + 1) * frame - o >= maxFrames * frame {
                let lo = max(o / frame + 1, f - cutWindow)
                let q = (lo...f).min { level[$0] < level[$1] }!
                close(at: q * frame)
                open = q * frame  // the next utterance starts right at the cut, so no word is heard twice
            }
        }
        if final {
            close(at: min(s.count, (last + 1) * frame + pad))
            return (spans, s.count)
        }
        return (spans, open ?? max(spans.last?.upperBound ?? 0, frames * frame - pad))
    }
}
