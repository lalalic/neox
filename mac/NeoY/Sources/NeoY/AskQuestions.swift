import Foundation

/// Native MCP App for asking a human one or more clarification questions.
///
/// The initial tool call returns the widget payload so an MCP Apps host can
/// render it. The answer is submitted by the app-only companion tool. MCP
/// Apps hosts currently deliver `ui/message` as a new conversation turn; they
/// do not resume the already-completed `ask_questions` call, so the answer is
/// returned by the submission call and message separately.
enum AskQuestions {
    static let toolName = "ask_questions"
    static let submitToolName = "ask_questions.submit"
    static let cancelToolName = "ask_questions.cancel"
    static let resourceURI = "ui://widget/neoy-ask-questions-v1.html"
    static let mimeType = MCPServer.mcpAppMimeType
    static let sessionTTL: TimeInterval = 10 * 60

    private static let sessions = AskQuestionSessions()

    @MainActor
    static func register(on server: MCPServer) {
        server.setRemoteAllowedResourceURIs([resourceURI])
        let resourceMeta: JSONValue = .object([
            "ui": .object([
                "prefersBorder": .bool(true),
                "csp": .object([
                    "connectDomains": .array([]),
                    "resourceDomains": .array([]),
                ]),
            ]),
        ])

        let askDescriptor: JSONValue = .object([
            "name": .string(toolName),
            "description": .string("Ask a human for clarification using one or more Markdown questions."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "prompt": .object([
                        "type": .string("string"),
                        "description": .string("Markdown containing the question or questions to answer."),
                    ]),
                ]),
                "required": .array([.string("prompt")]),
                "additionalProperties": .bool(false),
            ]),
            "_meta": .object([
                "ui": .object(["resourceUri": .string(resourceURI)]),
                "ui/resourceUri": .string(resourceURI),
                "openai/outputTemplate": .string(resourceURI),
            ]),
        ])
        server.registerFederatedTool(descriptor: askDescriptor, name: toolName, protected: true) { arguments in
            try await createSession(arguments: arguments)
        }

        let submitDescriptor: JSONValue = .object([
            "name": .string(submitToolName),
            "description": .string("Submit the answer from the ask_questions app."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "session_id": .object(["type": .string("string")]),
                    "answer": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("session_id"), .string("answer")]),
                "additionalProperties": .bool(false),
            ]),
            "_meta": .object(["ui": .object(["visibility": .array([.string("app")])])]),
        ])
        server.registerFederatedTool(descriptor: submitDescriptor, name: submitToolName, protected: true) { arguments in
            try await submit(arguments: arguments)
        }

        let cancelDescriptor: JSONValue = .object([
            "name": .string(cancelToolName),
            "description": .string("Cancel an unanswered ask_questions session."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object(["session_id": .object(["type": .string("string")])]),
                "required": .array([.string("session_id")]),
                "additionalProperties": .bool(false),
            ]),
            "_meta": .object(["ui": .object(["visibility": .array([.string("app")])])]),
        ])
        server.registerFederatedTool(descriptor: cancelDescriptor, name: cancelToolName, protected: true) { arguments in
            try await cancel(arguments: arguments)
        }

        server.registerFederatedResource(
            descriptor: .object([
                "uri": .string(resourceURI),
                "name": .string("NeoY Ask Questions"),
                "mimeType": .string(mimeType),
                "_meta": resourceMeta,
            ]),
            uri: resourceURI
        ) { _ in try resourceResult() }
    }

    private static func createSession(arguments: JSONValue) async throws -> String {
        guard case .object(let object) = arguments,
              case .string(let prompt)? = object["prompt"],
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AskQuestionsError.invalidPrompt
        }
        let sessionID = UUID().uuidString
        await sessions.create(id: sessionID, prompt: prompt)
        return try result([
            "content": [["type": "text", "text": "Clarification requested."]],
            "structuredContent": [
                "session_id": sessionID,
                "prompt": prompt,
                "prompt_html": AskQuestions.renderMarkdown(prompt),
                "status": "waiting_for_answer",
                "continuation": "The app submission is a new MCP turn; it does not resume this completed tool call.",
            ],
            "_meta": [
                "ui": ["resourceUri": resourceURI],
                "ui/resourceUri": resourceURI,
                "openai/outputTemplate": resourceURI,
            ],
        ])
    }

    private static func submit(arguments: JSONValue) async throws -> String {
        guard case .object(let object) = arguments,
              case .string(let sessionID)? = object["session_id"],
              case .string(let answer)? = object["answer"] else { throw AskQuestionsError.invalidSubmission }
        let record = try await sessions.submit(id: sessionID, answer: answer)
        return try result([
            "content": [["type": "text", "text": "Answer submitted."]],
            "structuredContent": [
                "session_id": record.id,
                "answer": record.answer,
                "status": "submitted",
                "continuation": "The initiating ask_questions call is already complete. Continue from this submission result or ui/message.",
            ],
        ])
    }

    private static func cancel(arguments: JSONValue) async throws -> String {
        guard case .object(let object) = arguments,
              case .string(let sessionID)? = object["session_id"] else { throw AskQuestionsError.invalidSubmission }
        try await sessions.cancel(id: sessionID)
        return try result([
            "content": [["type": "text", "text": "Clarification cancelled."]],
            "structuredContent": ["session_id": sessionID, "status": "cancelled"],
        ])
    }

    static func resourceResult() throws -> String {
        try result([
            "ttlMs": 0,
            "cacheScope": "private",
            "contents": [[
                "uri": resourceURI,
                "mimeType": mimeType,
                "text": html,
                "_meta": ["ui": ["prefersBorder": true, "csp": ["connectDomains": [], "resourceDomains": []]]],
            ]],
        ])
    }

    static func renderMarkdown(_ markdown: String) -> String {
        let escaped = markdown
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
        var output = ""
        var inList = false
        for line in escaped.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                if !inList { output += "<ul>"; inList = true }
                output += "<li>\(inlineMarkdown(String(trimmed.dropFirst(2))))</li>"
            } else {
                if inList { output += "</ul>"; inList = false }
                if trimmed.isEmpty { continue }
                let hashes = trimmed.prefix { $0 == "#" }.count
                if hashes > 0, trimmed.dropFirst(hashes).first == " " {
                    let level = min(hashes, 3)
                    output += "<h\(level)>\(inlineMarkdown(String(trimmed.dropFirst(hashes + 1))))</h\(level)>"
                } else {
                    output += "<p>\(inlineMarkdown(trimmed))</p>"
                }
            }
        }
        if inList { output += "</ul>" }
        return output
    }

    private static func inlineMarkdown(_ value: String) -> String {
        var result = ""
        var bold = false
        var index = value.startIndex
        while index < value.endIndex {
            if value[index...].hasPrefix("**") {
                result += bold ? "</strong>" : "<strong>"
                bold.toggle()
                index = value.index(index, offsetBy: 2)
            } else if value[index] == "`" {
                index = value.index(after: index)
            } else {
                result.append(value[index])
                index = value.index(after: index)
            }
        }
        if bold { result += "</strong>" }
        return result
    }

    static let html = """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>body{font:15px system-ui,sans-serif;margin:0;color:#17202a;background:#fff}main{max-width:720px;margin:auto;padding:18px}.prompt{line-height:1.5}.prompt h1,.prompt h2,.prompt h3{margin:0 0 8px}.prompt p{margin:8px 0}.prompt ul{padding-left:22px}textarea{box-sizing:border-box;width:100%;min-height:140px;margin:14px 0 8px;padding:10px;border:1px solid #8c959f;border-radius:6px;font:inherit;resize:vertical}button{border:0;border-radius:6px;padding:9px 14px;background:#0969da;color:#fff;font:inherit;cursor:pointer}button:disabled{opacity:.55}#status{min-height:1.4em;color:#656d76}</style></head>
    <body><main><section id="prompt" class="prompt" aria-live="polite">Loading question…</section><label for="answer">Answer</label><textarea id="answer" placeholder="Type your answer…"></textarea><button id="submit">Submit answer</button><button id="cancel" type="button">Cancel</button><div id="status" role="status"></div></main>
    <script>
    const promptEl=document.getElementById('prompt'),answerEl=document.getElementById('answer'),submitEl=document.getElementById('submit'),cancelEl=document.getElementById('cancel'),statusEl=document.getElementById('status');let nextId=1;const pending=new Map();let sessionId=null,done=false;
    function send(message){window.parent.postMessage(message,'*')}function rpc(method,params){const id=nextId++;send({jsonrpc:'2.0',id,method,params});return new Promise((resolve,reject)=>pending.set(id,{resolve,reject}))}
    window.addEventListener('message',event=>{if(event.source!==window.parent)return;const m=event.data;if(!m||typeof m!=='object'||m.jsonrpc!=='2.0')return;if(m.id!==undefined&&pending.has(m.id)){const p=pending.get(m.id);pending.delete(m.id);m.error?p.reject(new Error(m.error.message||'MCP request failed')):p.resolve(m.result);return}if(m.method==='ui/notifications/tool-result'){const r=m.params?.result||m.params||{},d=r.structuredContent||r.structured_content||{};if(typeof d.prompt_html==='string'){sessionId=d.session_id;promptEl.innerHTML=d.prompt_html}}});
    async function init(){try{await rpc('ui/initialize',{protocolVersion:'2026-01-26',appInfo:{name:'NeoY Ask Questions',version:'1.0.0'},appCapabilities:{}});send({jsonrpc:'2.0',method:'ui/notifications/initialized'})}catch(e){statusEl.textContent='MCP App host unavailable.'}}
    async function finish(method,args,label){if(done||!sessionId)return;done=true;submitEl.disabled=true;cancelEl.disabled=true;statusEl.textContent=label+'…';try{await rpc('tools/call',{name:method,arguments:args});await rpc('ui/message',{role:'user',content:[{type:'text',text:JSON.stringify(args)}]});statusEl.textContent=label+'.'}catch(e){done=false;submitEl.disabled=false;cancelEl.disabled=false;statusEl.textContent=e.message||'Unable to submit.'}}
    submitEl.onclick=()=>finish('ask_questions.submit',{session_id:sessionId,answer:answerEl.value},'Submitted');cancelEl.onclick=()=>finish('ask_questions.cancel',{session_id:sessionId},'Cancelled');init();
    </script></body></html>
    """

    private static func result(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return "mcpresult:" + data.base64EncodedString()
    }

    struct SessionRecord: Sendable { let id: String; let prompt: String; let answer: String? }

    actor AskQuestionSessions {
        private var records: [String: SessionRecord] = [:]
        func create(id: String, prompt: String) {
            purgeExpired()
            records[id] = SessionRecord(id: id, prompt: prompt, answer: nil)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(AskQuestions.sessionTTL))
                await self?.expire(id: id)
            }
        }
        func submit(id: String, answer: String) throws -> SessionRecord {
            purgeExpired()
            guard let record = records[id] else { throw AskQuestionsError.sessionUnavailable }
            guard record.answer == nil else { throw AskQuestionsError.alreadySubmitted }
            let updated = SessionRecord(id: record.id, prompt: record.prompt, answer: answer)
            records[id] = updated
            return updated
        }
        func cancel(id: String) throws {
            guard records.removeValue(forKey: id) != nil else { throw AskQuestionsError.sessionUnavailable }
        }
        private func expire(id: String) { records.removeValue(forKey: id) }
        private func purgeExpired() { /* individual expiry tasks bound memory and lifetime */ }
    }

    private enum AskQuestionsError: LocalizedError {
        case invalidPrompt, invalidSubmission, sessionUnavailable, alreadySubmitted
        var errorDescription: String? {
            switch self {
            case .invalidPrompt: return "prompt must be a non-empty Markdown string"
            case .invalidSubmission: return "session_id and answer are required"
            case .sessionUnavailable: return "ask_questions session is unavailable or expired"
            case .alreadySubmitted: return "ask_questions session already has a submission"
            }
        }
    }
}
