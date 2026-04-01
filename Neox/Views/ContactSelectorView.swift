import SwiftUI
import WebKitAgent

/// Multi-select contact picker presented as a sheet.
struct ContactSelectorView: View {
    @ObservedObject var weChatService: WeChatService
    let project: String?
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var bindings: WeChatContactBindings {
        weChatService.getBindings(for: project)
    }

    private var boundIDs: Set<String> {
        Set(bindings.contacts.map(\.id))
    }

    private var filteredContacts: [WeChatContact] {
        let all = weChatService.contacts
        if searchText.isEmpty { return all }
        let query = searchText.lowercased()
        return all.filter {
            $0.name.lowercased().contains(query) ||
            ($0.remarkName?.lowercased().contains(query) ?? false) ||
            ($0.nickName?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if weChatService.contacts.isEmpty {
                    Section {
                        if weChatService.isOnline {
                            ProgressView("Loading contacts…")
                        } else {
                            Label("WeChat is offline", systemImage: "wifi.slash")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section {
                        Toggle("Routing Active", isOn: Binding(
                            get: { bindings.routingActive },
                            set: { _ in weChatService.toggleRouting(for: project) }
                        ))
                    }

                    Section(header: Text("Bound (\(bindings.contacts.count))")) {
                        ForEach(bindings.contacts) { contact in
                            ContactRow(contact: contact, isBound: true)
                                .onTapGesture { unbind(contact) }
                        }
                    }

                    Section(header: Text("All Contacts")) {
                        ForEach(filteredContacts) { contact in
                            let isBound = boundIDs.contains(contact.id)
                            ContactRow(
                                contact: contact,
                                isBound: isBound
                            )
                            .onTapGesture {
                                if isBound {
                                    unbind(WeChatContactBindings.BoundContact(
                                        id: contact.id,
                                        name: contact.name,
                                        isRoom: contact.isRoom
                                    ))
                                } else {
                                    bind(contact)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search contacts")
            .navigationTitle(project ?? "Main Chat Contacts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Bind / Unbind

    private func bind(_ contact: WeChatContact) {
        var b = bindings
        guard !b.contacts.contains(where: { $0.id == contact.id }) else { return }
        b.contacts.append(WeChatContactBindings.BoundContact(
            id: contact.id,
            name: contact.name,
            isRoom: contact.isRoom
        ))
        weChatService.setBindings(b, for: project)
    }

    private func unbind(_ contact: WeChatContactBindings.BoundContact) {
        var b = bindings
        b.contacts.removeAll { $0.id == contact.id }
        weChatService.setBindings(b, for: project)
    }
}

// MARK: - Contact Row

private struct ContactRow: View {
    let contact: any Identifiable & ContactDisplayable
    let isBound: Bool

    var body: some View {
        HStack {
            if contact.isRoom {
                Image(systemName: "person.3.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            } else {
                Image(systemName: "person.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            Text(contact.displayName)
                .lineLimit(1)
            Spacer()
            if isBound {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Protocol to unify display across WeChatContact and BoundContact.
protocol ContactDisplayable {
    var displayName: String { get }
    var isRoom: Bool { get }
}

extension WeChatContact: ContactDisplayable {
    var displayName: String { remarkName ?? nickName ?? name }
}

extension WeChatContactBindings.BoundContact: ContactDisplayable {
    var displayName: String { name }
}
