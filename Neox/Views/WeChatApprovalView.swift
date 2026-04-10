import SwiftUI

/// Shows pending guardrail approvals and lets the owner approve, edit, or reject drafts.
struct WeChatApprovalView: View {
    @ObservedObject var guardrails: WeChatGuardrails

    @State private var editingId: String?
    @State private var editedText: String = ""

    var body: some View {
        Group {
            if guardrails.pendingApprovals.isEmpty {
                ContentUnavailableView("No Pending Approvals", systemImage: "checkmark.shield", description: Text("All clear"))
            } else {
                List {
                    ForEach(guardrails.pendingApprovals) { approval in
                        approvalRow(approval)
                    }
                }
            }
        }
        .navigationTitle("Approvals")
    }

    @ViewBuilder
    private func approvalRow(_ approval: WeChatGuardrails.PendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(approval.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(approval.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if editingId == approval.id {
                TextEditor(text: $editedText)
                    .frame(minHeight: 60)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))

                HStack {
                    Button("Cancel") {
                        editingId = nil
                    }
                    Spacer()
                    Button("Send Edited") {
                        Task {
                            await guardrails.approveEdited(approvalId: approval.id, editedDraft: editedText)
                            editingId = nil
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text(approval.draft)
                    .font(.body)
                    .padding(8)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)

                HStack(spacing: 12) {
                    Button(role: .destructive) {
                        guardrails.reject(approvalId: approval.id)
                    } label: {
                        Label("Reject", systemImage: "xmark")
                    }

                    Button {
                        editedText = approval.draft
                        editingId = approval.id
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }

                    Spacer()

                    Button {
                        Task { await guardrails.approve(approvalId: approval.id) }
                    } label: {
                        Label("Approve", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
