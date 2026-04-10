import Foundation
import CopilotSDK

/// Thread-safe container for the current contact ID (updated by router on each message).
final class ContactIdRef: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

/// Manages guardrail enforcement and approval flow for WeChat Assistant mode.
/// When the agent detects sensitive content, it calls `request_approval` tool instead of replying directly.
/// The router holds the draft and sends a push notification to the owner.
@MainActor
final class WeChatGuardrails: ObservableObject {

    struct PendingApproval: Identifiable, Sendable {
        let id: String
        let projectId: String
        let contactId: String
        let draft: String
        let reason: String
        let timestamp: Date
    }

    /// Pending approvals waiting for owner action.
    @Published private(set) var pendingApprovals: [PendingApproval] = []

    private weak var weChatService: WeChatService?

    init(weChatService: WeChatService) {
        self.weChatService = weChatService
    }

    /// Queue a draft for owner approval. Returns the approval ID.
    func requestApproval(
        projectId: String,
        contactId: String,
        draft: String,
        reason: String
    ) -> String {
        let approval = PendingApproval(
            id: UUID().uuidString,
            projectId: projectId,
            contactId: contactId,
            draft: draft,
            reason: reason,
            timestamp: Date()
        )
        pendingApprovals.append(approval)
        NSLog("[Guardrails] Approval requested for project '%@': %@", projectId, reason)
        return approval.id
    }

    /// Owner approves the draft — send it to WeChat.
    func approve(approvalId: String) async {
        guard let index = pendingApprovals.firstIndex(where: { $0.id == approvalId }) else { return }
        let approval = pendingApprovals.remove(at: index)
        await weChatService?.sendToContact(approval.contactId, message: approval.draft, watermark: true)
    }

    /// Owner edits and approves — send edited version.
    func approveEdited(approvalId: String, editedDraft: String) async {
        guard let index = pendingApprovals.firstIndex(where: { $0.id == approvalId }) else { return }
        let approval = pendingApprovals.remove(at: index)
        await weChatService?.sendToContact(approval.contactId, message: editedDraft, watermark: true)
    }

    /// Owner rejects — discard the draft.
    func reject(approvalId: String) {
        pendingApprovals.removeAll { $0.id == approvalId }
    }

    /// Build the `request_approval` tool definition for project agent sessions.
    /// `contactIdRef` is a thread-safe container that the router updates with the current contact.
    static func buildTool(guardrails: WeChatGuardrails, projectId: String, contactIdRef: ContactIdRef) -> ToolDefinition {
        ToolDefinition(
            name: "request_approval",
            description: "Request owner approval before sending a sensitive reply. Use when guardrails are triggered — e.g. money transfer, legal commitment, scheduling on behalf of owner, sharing personal info.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "draft": .object([
                        "type": .string("string"),
                        "description": .string("The draft reply to send if approved"),
                    ]),
                    "reason": .object([
                        "type": .string("string"),
                        "description": .string("Why this needs approval (which guardrail was triggered)"),
                    ]),
                ]),
                "required": .array([.string("draft"), .string("reason")]),
            ]),
            handler: { args in
                guard case .object(let dict) = args,
                      case .string(let draft) = dict["draft"],
                      case .string(let reason) = dict["reason"] else {
                    return "Error: 'draft' and 'reason' are required string parameters"
                }

                let cid = contactIdRef.value ?? "unknown"
                let approvalId = await guardrails.requestApproval(
                    projectId: projectId,
                    contactId: cid,
                    draft: draft,
                    reason: reason
                )

                return "Approval requested (id: \(approvalId)). Owner will review. Draft is held — do NOT send a direct reply."
            }
        )
    }
}
