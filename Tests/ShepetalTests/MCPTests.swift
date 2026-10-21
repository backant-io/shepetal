import XCTest
import ShepetalCore
@testable import Shepetal

/// F86: `shepetal --mcp` lets an AI app the user set up read meetings and dictations. What matters: an MCP client
/// can connect (initialize, tools/list), it gets the stored text back, it gets nothing while Settings is off, the
/// server never changes or creates the user's databases, and every reply is one line of JSON-RPC (anything else on
/// stdout breaks the client). Runs on temp SQLite files; never touches the clipboard, windows or the running app.
final class MCPTests: XCTestCase {
    private var root: URL!
    private var enabled = true
    private let t0 = Date(timeIntervalSince1970: 1_792_508_400)  // 2026-10-20 15:00 UTC

    private lazy var older = Meeting(id: "m-old", app: "Zoom", startedAt: t0, endedAt: t0.addingTimeInterval(30 * 60),
                                     meAudioPath: "/m/old/Me.wav", othersAudioPath: "/m/old/Others.wav")
    private lazy var newer = Meeting(id: "m-new", app: "Google Meet (Chrome)", startedAt: t0.addingTimeInterval(86_400),
                                     endedAt: t0.addingTimeInterval(86_400 + 42 * 60),
                                     meAudioPath: "/m/new/Me.wav", othersAudioPath: "/m/new/Others.wav")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString)")
        try AudioStore.makeOwnerOnlyDirectory(root)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func seed() throws {
        let store = try MeetingStore(path: root.appendingPathComponent("meetings.sqlite"))
        try store.save(older)
        try store.append([Segment(speaker: .others, start: 3, end: 6, text: "Budget review for the offsite.")], to: older.id)
        try store.save(newer)
        try store.append([Segment(speaker: .others, start: 4, end: 9, text: "Shall we ship the beta on Friday?"),
                          Segment(speaker: .me, start: 247, end: 251, text: "Yes, I will send the notes.")], to: newer.id)
        try store.setSummary(Summary(overview: "The beta ships on Friday.", decisions: ["Ship the beta on Friday"],
                                     actionItems: [ActionItem(owner: "Pavel", task: "Send the notes", due: "tomorrow")]),
                             for: newer.id)
        let history = try History(path: root.appendingPathComponent("history.sqlite"))
        try history.add(HistoryEntry(id: "d1", createdAt: t0, outcome: .inserted, audioPath: "/a/d1.wav", durationMs: 2000,
                                     text: "Please pay the invoice by Monday.", app: "Mail"))
        try history.add(HistoryEntry(id: "d2", createdAt: t0.addingTimeInterval(60), outcome: .inserted, audioPath: "/a/d2.wav",
                                     durationMs: 1500, text: "Lunch at noon?", app: "Slack"))
    }

    private func server() -> MCPServer { MCPServer(root: root, enabled: { [unowned self] in enabled }) }

    private func send(_ s: MCPServer, _ id: Int, _ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        let line = String(decoding: try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params]),
                          as: UTF8.self)
        let reply = try XCTUnwrap(s.handle(line), "no reply to \(method)")
        XCTAssertFalse(reply.contains("\n"), "a reply must be exactly one line")
        let msg = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        XCTAssertEqual(msg["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(msg["id"] as? Int, id)
        return msg
    }

    /// The text of a tools/call result, and whether it is a tool error.
    private func tool(_ s: MCPServer, _ name: String, _ args: [String: Any] = [:]) throws -> (text: String, isError: Bool) {
        let result = try XCTUnwrap(try send(s, 7, "tools/call", ["name": name, "arguments": args])["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "text")
        return (try XCTUnwrap(content.first?["text"] as? String), result["isError"] as? Bool ?? false)
    }

    func testInitializeAndToolsListAreWhatAnMCPClientExpects() throws {
        let s = server()
        let initialize = try XCTUnwrap(try send(s, 1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:],
                                                                     "clientInfo": ["name": "test", "version": "1"]])["result"] as? [String: Any])
        XCTAssertEqual(initialize["protocolVersion"] as? String, "2025-06-18", "a version we know is echoed back")
        XCTAssertNotNil((initialize["capabilities"] as? [String: Any])?["tools"], "without the tools capability no client lists tools")
        XCTAssertEqual((initialize["serverInfo"] as? [String: Any])?["name"] as? String, "shepetal")
        let unknown = try XCTUnwrap(try send(s, 2, "initialize", ["protocolVersion": "1999-01-01"])["result"] as? [String: Any])
        XCTAssertEqual(unknown["protocolVersion"] as? String, MCPServer.protocolVersions.last, "an unknown version gets our latest")

        XCTAssertNil(s.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#), "a notification gets no reply")
        XCTAssertNil(s.handle(#"{"jsonrpc":"2.0","method":"ping"}"#), "no id, no reply, even for a method we know")
        XCTAssertNil(s.handle("   "))
        XCTAssertEqual((try send(s, 3, "ping")["result"] as? [String: Any])?.count, 0)

        let tools = try XCTUnwrap((try send(s, 4, "tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }),
                       ["list_meetings", "search_meetings", "get_meeting", "search_dictations"], "read-only tools only")
        for t in tools {
            let schema = try XCTUnwrap(t["inputSchema"] as? [String: Any], "\(t["name"] ?? "")")
            XCTAssertEqual(schema["type"] as? String, "object")
            XCTAssertFalse((t["description"] as? String ?? "").isEmpty)
        }
        let get = try XCTUnwrap(tools.first { $0["name"] as? String == "get_meeting" })
        XCTAssertEqual((get["inputSchema"] as? [String: Any])?["required"] as? [String], ["id"])
    }

    func testSearchAndGetReturnTheStoredText() throws {
        try seed()
        let s = server()
        let all = try tool(s, "list_meetings")
        XCTAssertFalse(all.isError)
        XCTAssertEqual(all.text, "- \(MeetingFormat.headline(newer)) (id: m-new)\n- \(MeetingFormat.headline(older)) (id: m-old)",
                       "newest first, each with its id, so the client can get it")
        XCTAssertEqual(try tool(s, "list_meetings", ["limit": 1]).text, "- \(MeetingFormat.headline(newer)) (id: m-new)")

        XCTAssertEqual(try tool(s, "search_meetings", ["query": "BUDGET"]).text, "- \(MeetingFormat.headline(older)) (id: m-old)",
                       "the transcript is searched, in any case")
        XCTAssertEqual(try tool(s, "search_meetings", ["query": "ships on friday"]).text, "- \(MeetingFormat.headline(newer)) (id: m-new)",
                       "the summary is searched")
        XCTAssertEqual(try tool(s, "search_meetings", ["query": "kangaroo"]).text, "No meeting matches \"kangaroo\".")

        // "What did we decide in my last meeting?": the summary, decisions, action items and transcript.
        let get = try tool(s, "get_meeting", ["id": "m-new"])
        XCTAssertFalse(get.isError)
        let record = try XCTUnwrap(try MeetingStore(path: root.appendingPathComponent("meetings.sqlite")).get("m-new"))
        XCTAssertEqual(get.text, MeetingFormat.markdown(record))
        for part in ["The beta ships on Friday.", "## Decisions\n\n- Ship the beta on Friday",
                     "- [ ] **Pavel**: Send the notes (due tomorrow)", "**Me** (4:07): Yes, I will send the notes."] {
            XCTAssertTrue(get.text.contains(part), part)
        }

        let dictations = try tool(s, "search_dictations", ["query": "invoice"])
        XCTAssertEqual(dictations.text, "- \(MeetingFormat.date(t0, format: "dd.MM.yy HH:mm")) · Mail: Please pay the invoice by Monday.")
        XCTAssertTrue(try tool(s, "search_dictations", ["query": ""]).text.hasPrefix("- \(MeetingFormat.date(t0.addingTimeInterval(60), format: "dd.MM.yy HH:mm")) · Slack: Lunch at noon?\n"),
                      "an empty query lists the latest first")
    }

    func testUnknownIdToolAndMethodAreErrors() throws {
        try seed()
        let s = server()
        let missing = try tool(s, "get_meeting", ["id": "nope"])
        XCTAssertTrue(missing.isError, "the client must not read an unknown id as an empty meeting")
        XCTAssertTrue(missing.text.contains("nope"))

        let method = try XCTUnwrap(try send(s, 5, "resources/list")["error"] as? [String: Any])
        XCTAssertEqual(method["code"] as? Int, -32601)
        let unknownTool = try XCTUnwrap(try send(s, 6, "tools/call", ["name": "delete_meeting", "arguments": ["id": "m-new"]])["error"] as? [String: Any])
        XCTAssertEqual(unknownTool["code"] as? Int, -32602)
        XCTAssertNotNil(try MeetingStore(path: root.appendingPathComponent("meetings.sqlite")).get("m-new"))

        let parse = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(XCTUnwrap(s.handle("{not json")).utf8)) as? [String: Any])
        XCTAssertEqual((parse["error"] as? [String: Any])?["code"] as? Int, -32700)
        XCTAssertTrue(parse["id"] is NSNull)
        XCTAssertNil(s.handle(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#))
    }

    func testSettingOffRefusesEveryToolCallUntilItIsTurnedOn() throws {
        try seed()
        enabled = false
        let s = server()
        for (name, args) in [("list_meetings", [:]), ("search_meetings", ["query": "beta"]), ("get_meeting", ["id": "m-new"]),
                             ("search_dictations", ["query": "invoice"])] as [(String, [String: Any])] {
            let r = try tool(s, name, args)
            XCTAssertTrue(r.isError, name)
            XCTAssertEqual(r.text, MCPServer.turnOn, "\(name) must tell the user where to turn it on")
        }
        XCTAssertTrue(MCPServer.turnOn.contains("Let AI apps read my meetings and dictations"), "names the Settings toggle")
        enabled = true  // the toggle in the running app: read on every call, no restart
        XCTAssertFalse(try tool(s, "search_dictations", ["query": "invoice"]).isError)
        // Off by default: the server's own setting reads the key, which nobody set in this test process.
        XCTAssertEqual(try tool(MCPServer(root: root), "list_meetings").text, MCPServer.turnOn)
    }

    func testTheDatabasesAreNeverChangedOrCreated() throws {
        try seed()
        let files = ["meetings.sqlite", "history.sqlite"].map { root.appendingPathComponent($0) }
        let before = try files.map { try Data(contentsOf: $0) }
        let s = server()
        _ = try send(s, 1, "initialize")
        for (name, args) in [("list_meetings", [:]), ("search_meetings", ["query": "beta"]), ("get_meeting", ["id": "m-new"]),
                             ("get_meeting", ["id": "nope"]), ("search_dictations", ["query": ""])] as [(String, [String: Any])] {
            _ = try tool(s, name, args)
        }
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, before, "the server only reads")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["history.sqlite", "meetings.sqlite"])

        // Before the app ever ran: answers, and creates nothing.
        let empty = root.appendingPathComponent("empty")
        try AudioStore.makeOwnerOnlyDirectory(empty)
        let fresh = MCPServer(root: empty, enabled: { true })
        XCTAssertEqual(try tool(fresh, "list_meetings").text, "No meetings recorded yet.")
        XCTAssertEqual(try tool(fresh, "search_dictations", ["query": ""]).text, "No dictations yet.")
        XCTAssertTrue(try tool(fresh, "get_meeting", ["id": "m-new"]).isError)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: empty.path), [])
    }

    func testEveryReplyIsOneLineOfJSONRPC() throws {
        try seed()
        let store = try MeetingStore(path: root.appendingPathComponent("meetings.sqlite"))
        try store.append([Segment(speaker: .me, start: 300, end: 301, text: "line one\nline two \"quoted\" \\ /path")], to: newer.id)
        let s = server()
        let lines = [#"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{}}"#,
                     #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                     #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
                     #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_meeting","arguments":{"id":"m-new"}}}"#,
                     #"{"jsonrpc":"2.0","id":4,"method":"nope"}"#, "garbage", #"[1,2]"#, #"{"jsonrpc":"2.0","id":5}"#]
        let codes = [nil, nil, nil, -32601, -32700, -32600, -32600]
        var replies: [[String: Any]] = []
        for line in lines {
            guard let reply = s.handle(line) else { continue }
            XCTAssertFalse(reply.contains("\n") || reply.contains("\r"), line)
            replies.append(try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any], line))
        }
        XCTAssertEqual(replies.count, lines.count - 1, "every line but the notification gets exactly one reply")
        XCTAssertEqual(replies.map { "\($0["id"] ?? "missing")" }, ["a", "2", "3", "4", "<null>", "<null>", "5"])
        XCTAssertEqual(replies.map { ($0["error"] as? [String: Any])?["code"] as? Int }, codes)
        let text = (((replies[2]["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("line one\nline two \"quoted\" \\ /path"), "newlines and quotes survive the one-line encoding")
    }

    func testSetupIsTheMcpServersEntryForThisBinary() throws {
        let path = "/Applications/Shepetal.app/Contents/MacOS/Shepetal"
        let config = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(MCPServer.setup(executable: path).utf8)) as? [String: Any])
        let entry = try XCTUnwrap((config["mcpServers"] as? [String: Any])?["shepetal"] as? [String: Any])
        XCTAssertEqual(entry["command"] as? String, path)
        XCTAssertEqual(entry["args"] as? [String], ["--mcp"])
        XCTAssertEqual(MCPServer.flag, "--mcp")
    }
}
