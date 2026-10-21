import AppKit
import ShepetalCore
import SwiftUI

/// `shepetal --mcp` (F86): a local MCP server over stdio, so an AI app on this Mac can search and read the user's
/// meetings and dictations. JSON-RPC 2.0, one message per line, Foundation only. It only reads meetings.sqlite and
/// history.sqlite under the data dir, never creates them, and answers no tool call until Settings turns it on.
final class MCPServer {
    static let flag = "--mcp"
    /// Settings' "Let AI apps read my meetings and dictations". Off by default.
    static let enabledKey = "mcpEnabled"
    static let protocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
    static let turnOn = "shepetal is not sharing meetings or dictations with AI apps. Ask the user to turn on "
        + "\"Let AI apps read my meetings and dictations\" in shepetal: Open shepetal > Settings."

    private let root: URL
    private let enabled: () -> Bool

    init(root: URL = Paths.root, enabled: @escaping () -> Bool = { UserDefaults.standard.bool(forKey: MCPServer.enabledKey) }) {
        self.root = root
        self.enabled = enabled
    }

    /// Serves stdin until it closes. Anything else that prints goes to stderr: stdout carries only JSON-RPC.
    static func main() -> Never {
        let out = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        let server = MCPServer()
        while let line = readLine() {
            if let reply = server.handle(line) { out.write(Data((reply + "\n").utf8)) }
        }
        exit(0)
    }

    /// One request line in, one response line out; nil for a notification or a blank line.
    func handle(_ line: String) -> String? {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(line.utf8), options: .fragmentsAllowed) else {
            return Self.encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let msg = parsed as? [String: Any] else {  // batches are gone from MCP since 2025-06-18
            return Self.encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Invalid Request"]])
        }
        let id = msg["id"]
        guard let method = msg["method"] as? String else {
            // A response from the client (we send no requests) needs no answer.
            if id != nil, msg["result"] != nil || msg["error"] != nil { return nil }
            return Self.encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": -32600, "message": "Invalid Request"]])
        }
        let params = msg["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            result = ["protocolVersion": Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions.last!,
                      "capabilities": ["tools": [:] as [String: Any]],
                      "serverInfo": ["name": "shepetal", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"],
                      "instructions": "The user's meetings (summary, decisions, action items, transcript) and dictations, "
                        + "recorded and kept on this Mac by shepetal. Read-only."]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": Self.tools]
        case "tools/call":
            guard let name = params["name"] as? String, Self.tools.contains(where: { $0["name"] as? String == name }) else {
                return reply(id, error: -32602, "Unknown tool: \(params["name"] ?? "none")")
            }
            result = call(name, params["arguments"] as? [String: Any] ?? [:])
        default:
            return reply(id, error: -32601, "Method not found: \(method)")
        }
        guard let id else { return nil }  // a notification (no id) is never answered
        return Self.encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func reply(_ id: Any?, error code: Int, _ message: String) -> String? {
        guard let id else { return nil }
        return Self.encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private static func encode(_ object: [String: Any]) -> String {
        // No pretty printing: one message per line. Newlines inside strings are escaped.
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
    }

    static let tools: [[String: Any]] = {
        func tool(_ name: String, _ description: String, _ properties: [String: [String: Any]], required: [String] = []) -> [String: Any] {
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any]]
        }
        let limit: [String: Any] = ["type": "integer", "minimum": 1, "maximum": 100, "description": "How many, newest first (default 20)"]
        return [
            tool("list_meetings", "The user's recorded meetings, newest first: app, date (DD.MM.YY), length and id.", ["limit": limit]),
            tool("search_meetings", "Meetings whose app, transcript or summary contains the query (any case), newest first.",
                 ["query": ["type": "string"], "limit": limit], required: ["query"]),
            tool("get_meeting", "One meeting as Markdown: overview, key points, decisions, action items with owners, and the transcript.",
                 ["id": ["type": "string", "description": "An id from list_meetings or search_meetings"]], required: ["id"]),
            tool("search_dictations", "The user's dictations whose text contains the query (any case), newest first, with date and app. An empty query lists the latest.",
                 ["query": ["type": "string"], "limit": limit], required: ["query"]),
        ]
    }()

    /// A tool's answer. Failures the AI app should tell the user about come back as isError, not as JSON-RPC errors.
    private func call(_ name: String, _ args: [String: Any]) -> [String: Any] {
        func text(_ s: String, error: Bool = false) -> [String: Any] {
            ["content": [["type": "text", "text": s]], "isError": error]
        }
        guard enabled() else { return text(Self.turnOn, error: true) }
        let query = args["query"] as? String ?? ""
        let limit = min(100, max(1, (args["limit"] as? NSNumber)?.intValue ?? 20))
        do {
            switch name {
            case "list_meetings", "search_meetings":
                let found = try meetings().map { name == "list_meetings" ? try $0.list(limit: limit) : try $0.search(query, limit: limit) } ?? []
                if found.isEmpty { return text(name == "list_meetings" ? "No meetings recorded yet." : "No meeting matches \"\(query)\".") }
                return text(found.map { "- \(MeetingFormat.headline($0)) (id: \($0.id))" }.joined(separator: "\n"))
            case "get_meeting":
                let id = args["id"] as? String ?? ""
                guard let record = try meetings()?.get(id) else {
                    return text("No meeting with id \"\(id)\". list_meetings gives the ids.", error: true)
                }
                return text(MeetingFormat.markdown(record))
            default:  // search_dictations
                let rows = try history()?.search(query, limit: limit).filter { !$0.shownText.isEmpty } ?? []  // Show raw (F48): what Copy and Recent give
                if rows.isEmpty { return text(query.isEmpty ? "No dictations yet." : "No dictation contains \"\(query)\".") }
                return text(rows.map { e in
                    let when = MeetingFormat.date(e.createdAt, format: "dd.MM.yy HH:mm")
                    return "- \(when) · \(e.app.isEmpty ? "unknown app" : e.app): \(e.shownText)"
                }.joined(separator: "\n"))
            }
        } catch {
            return text("shepetal could not read its data: \(error.localizedDescription)", error: true)
        }
    }

    // Opened per call, so data the app writes meanwhile is seen, and only when the file exists: the server never
    // creates a database. ponytail: History and MeetingStore open read-write (no read-only init yet); with the
    // schema this binary knows, opening writes nothing. Add a read-only open to both if that ever changes.
    private func meetings() throws -> MeetingStore? {
        let url = root.appendingPathComponent("meetings.sqlite")
        return FileManager.default.fileExists(atPath: url.path) ? try MeetingStore(path: url) : nil
    }

    private func history() throws -> History? {
        let url = root.appendingPathComponent("history.sqlite")
        return FileManager.default.fileExists(atPath: url.path) ? try History(path: url) : nil
    }

    /// What "Copy setup for AI apps" puts on the clipboard: the `mcpServers` entry Claude Desktop, Cursor and most
    /// MCP clients read.
    static func setup(executable: String = Bundle.main.executablePath ?? "/Applications/Shepetal.app/Contents/MacOS/Shepetal") -> String {
        let config = ["mcpServers": ["shepetal": ["command": executable, "args": [flag]]]]
        let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data ?? Data(), as: UTF8.self)
    }
}

/// Settings rows for F86: the opt-in toggle and the setup button.
struct AIAppsSettings: View {
    @AppStorage(MCPServer.enabledKey) private var enabled = false
    @State private var copied = false

    var body: some View {
        Toggle("Let AI apps read my meetings and dictations", isOn: $enabled)
        Text("An AI app set up with shepetal can search and read your meeting notes and dictations. shepetal answers only on this Mac; what the AI app does with the text is up to that app.")
            .font(.caption).foregroundStyle(.secondary)
        Button(copied ? "Copied: paste it into the AI app's MCP settings" : "Copy setup for AI apps") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(MCPServer.setup(), forType: .string)
            copied = true
        }
    }
}
