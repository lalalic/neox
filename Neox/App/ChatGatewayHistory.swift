import Foundation

/// The iPhone owns the display transcript. The Neo Models outbox stores only
/// pending operational request state, never a server-side chat_feed history.
@MainActor
final class ChatGatewayHistory {
    private struct Snapshot: Codable {
        var importedLegacy: Bool
        var items: [Record]
    }
    private struct Record: Codable {
        var id: String
        var kind: String
        var text: String
        var at: String
        var status: String?
        var level: String?
        var jobID: String?
        var repository: String?
        var jobId: String? { jobID }
        var wire: [String: Any] {
            var result: [String: Any] = ["id":id,"kind":kind,"text":text,"at":at]
            if let status {result["status"]=status}
            if let level {result["level"]=level}
            if let jobID {result["jobId"]=jobID}
            if let repository {result["repository"]=repository}
            return result
        }
        init(_ item: ChatGatewayItem) {
            id=item.id;kind=item.kind;text=item.text;at=item.at;status=item.status
            level=item.level;jobID=item.jobID;repository=item.repository
        }
    }
    private let file: URL
    private var state: Snapshot
    var items: [ChatGatewayItem] { state.items.compactMap { try? ChatGatewayItem(wire:$0.wire) } }
    var hasImportedLegacy: Bool {state.importedLegacy}

    init(file: URL? = nil) {
        self.file=file ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("neo-orchestrator-history-v1.json")
        if let data=try? Data(contentsOf:self.file),let decoded=try? JSONDecoder().decode(Snapshot.self,from:data) {
            state=decoded
        }else {state=Snapshot(importedLegacy:false,items:[])}
    }
    private func persist() throws {
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        let data=try JSONEncoder().encode(state)
        try data.write(to:file,options:[.atomic,.completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:file.path)
    }
    private func upsert(_ item:ChatGatewayItem) throws {
        let record=Record(item)
        if let index=state.items.firstIndex(where:{$0.id==item.id}) {state.items[index]=record}
        else {state.items.append(record)}
        try persist()
    }
    func importLegacyOnce(_ legacy:[ChatGatewayItem]) throws {
        // Merge legacy reports by stable ID until REST cutover. Never remove
        // phone-owned messages when the legacy server returns a short page.
        for item in legacy {
            if let index = state.items.firstIndex(where: { $0.id == item.id }) {
                if state.items[index].kind != "owner" { state.items[index] = Record(item) }
            } else {
                state.items.append(Record(item))
            }
        }
        state.importedLegacy=true
        try persist()
    }
    func owner(_ message:QueuedChatMessage) throws {
        let at=ISO8601DateFormatter().string(from:message.createdAt)
        let display=message.text+(message.attachments ?? []).map{"\nAttachment: "+$0.name}.joined()
        let item=try ChatGatewayItem(wire:["id":"owner:"+message.id,"kind":"owner","text":display,"at":at,"status":"pending"])
        try upsert(item)
    }
    func markSubmitted(_ requestID:String) throws {
        guard let index=state.items.firstIndex(where:{$0.id=="owner:"+requestID}) else{return}
        if state.items[index].status=="submitted" {return}
        state.items[index].status="submitted"
        try persist()
    }
    func update(requestID:String,status:String,message:[String:Any]?) throws {
        let reportID="report:"+requestID
        let index=state.items.firstIndex(where:{$0.id==reportID})
        let existing=index.map{state.items[$0]}
        let terminal=["completed","failed"].contains(status)
        if let msg=message,let text=msg["text"] as? String {
            // A single durable Assistant bubble owns this stable request ID;
            // duplicate SSE/pending records update it, never append fragments.
            let at=existing?.at ?? ISO8601DateFormatter().string(from:Date())
            let item=try ChatGatewayItem(wire:["id":reportID,"kind":"report","text":text,"at":at,
               "status":status,"level":msg["level"] as? String ?? "info",
               "jobId":msg["jobId"] as? String ?? ""])
            try upsert(item)
            return
        }
        if terminal {
            // Control-only handoff has no owner-visible assistant text.
            // Remove its transient placeholder without displaying raw control.
            if let index,["processing","uncertain"].contains(existing?.status ?? "") {
                state.items.remove(at:index)
                try persist()
            }
            return
        }
        if (status=="processing" || status=="uncertain") &&
           !["completed","failed"].contains(existing?.status ?? "") {
            let text=status=="uncertain" ? "Waiting for confirmation…" : "Processing…"
            // No extra bubbles for a retransmitted cursor/status.
            let at=existing?.at ?? ISO8601DateFormatter().string(from:Date())
            let item=try ChatGatewayItem(wire:["id":reportID,"kind":"report",
                 "text":text,"at":at,"status":status,"level":"info"])
            try upsert(item)
        }
    }
}
