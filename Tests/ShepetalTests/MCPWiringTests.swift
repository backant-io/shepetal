import XCTest
import ShepetalCore
@testable import Shepetal

/// F86 and F64 wiring. Settings cannot be rendered in a test, so the rows are pinned by source; `--mcp` is checked
/// on the real binary, because an MCP client breaks on any byte on stdout that is not JSON-RPC, and only the
/// process shows that. The binary runs on a temp SHEPETAL_HOME and never touches the clipboard or windows.
final class MCPWiringTests: XCTestCase {
    func testSettingsShowsTheAIAppsRowsAndTheExportButton() throws {
        let settings = try AppSource.body(of: "private struct SettingsTab: View {", in: try AppSource.code("Hub.swift"))
        XCTAssertTrue(settings.contains("AIAppsSettings()"), "F86: the opt-in toggle and Copy setup for AI apps")
        XCTAssertTrue(settings.contains("DataExportButton(history: model.pipeline.history, meetings: meetings)"), "F64: Export my data…")
        XCTAssertTrue(try AppSource.code("Hub.swift").contains("SettingsTab(model: model, meetings: meetings.store, input: input)"),
                      "the export reads the same meeting store as the Meetings tab")
    }

    func testMcpIsDispatchedBeforeAppKit() throws {
        let main = try AppSource.code("main.swift")
        let mcp = try XCTUnwrap(main.range(of: "if args.contains(MCPServer.flag) { MCPServer.main() }"), "--mcp is not dispatched")
        let appKit = try XCTUnwrap(main.range(of: "NSApplication.shared"))
        XCTAssertLessThan(mcp.lowerBound, appKit.lowerBound, "no menu bar app, Dock icon or window for an MCP client's process")
    }

    func testTheBinaryAnswersOnlyJSONRPCOnStdout() throws {
        // Without the dispatch the binary would start the menu bar app; never launch that from a test.
        guard try AppSource.code("main.swift").contains("MCPServer.main()") else { return XCTFail("--mcp is not dispatched") }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-bin-\(UUID().uuidString)")
        try AudioStore.makeOwnerOnlyDirectory(home)
        defer { try? FileManager.default.removeItem(at: home) }
        let t0 = Date(timeIntervalSince1970: 1_792_508_400)
        let store = try MeetingStore(path: home.appendingPathComponent("meetings.sqlite"))
        try store.save(Meeting(id: "m1", app: "Zoom", startedAt: t0, endedAt: t0.addingTimeInterval(600), meAudioPath: "", othersAudioPath: ""))
        try store.setSummary(Summary(overview: "We decided to ship on Friday."), for: "m1")

        let requests = [#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#,
                        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                        #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
                        #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_meeting","arguments":{"id":"m1"}}}"#]
        func run(_ extra: [String]) throws -> [[String: Any]] {
            let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("shepetal")
            let p = Process()
            p.executableURL = binary
            p.arguments = ["--mcp"] + extra
            p.environment = ["SHEPETAL_HOME": home.path, "HOME": home.path]
            let stdin = Pipe(), stdout = Pipe()
            p.standardInput = stdin
            p.standardOutput = stdout
            p.standardError = FileHandle.nullDevice
            try p.run()
            stdin.fileHandleForWriting.write(Data((requests.joined(separator: "\n") + "\n").utf8))
            try stdin.fileHandleForWriting.close()  // EOF ends the server
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { if p.isRunning { p.terminate() } }
            let out = stdout.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationReason, .exit, "the server must exit when stdin closes")
            XCTAssertEqual(p.terminationStatus, 0)
            let text = String(decoding: out, as: UTF8.self)
            XCTAssertTrue(text.hasSuffix("\n"))
            return try text.split(separator: "\n").map { line in
                try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], "not JSON on stdout: \(line)")
            }
        }
        func toolText(_ reply: [String: Any]) -> (String, Bool) {
            let r = reply["result"] as? [String: Any]
            return ((r?["content"] as? [[String: Any]])?.first?["text"] as? String ?? "", r?["isError"] as? Bool ?? false)
        }

        let off = try run([])
        XCTAssertEqual(off.map { $0["id"] as? Int }, [1, 2, 3], "one reply per request, none for the notification")
        XCTAssertEqual(((off[0]["result"] as? [String: Any])?["serverInfo"] as? [String: Any])?["name"] as? String, "shepetal")
        XCTAssertEqual(((off[1]["result"] as? [String: Any])?["tools"] as? [Any])?.count, 4)
        XCTAssertEqual(toolText(off[2]).0, MCPServer.turnOn, "off by default")
        XCTAssertTrue(toolText(off[2]).1)

        // The argument domain turns the setting on for this process only; nothing is written to defaults.
        let on = try run(["-\(MCPServer.enabledKey)", "YES"])
        XCTAssertTrue(toolText(on[2]).0.contains("We decided to ship on Friday."))
        XCTAssertFalse(toolText(on[2]).1)
    }
}
