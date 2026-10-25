import Foundation
import SwiftUI

/// User intent stored on the phone. This does not start media selection.
struct AutoVlogConsent: Codable, Equatable {
    let masterName: String
    var enabled: Bool
    var lookbackDays: Int
    var maxCandidates: Int

    var hasSafeBounds: Bool {
        (1...30).contains(lookbackDays) && (1...50).contains(maxCandidates)
    }
}

enum AutoVlogAvailability: Equatable {
    case noMaster
    case off
    case pendingMasterSupport

    static func resolve(selectedMaster: String?, consent: AutoVlogConsent?) -> Self {
        guard let selectedMaster, !selectedMaster.isEmpty else { return .noMaster }
        guard let consent, consent.masterName == selectedMaster,
              consent.enabled, consent.hasSafeBounds else { return .off }
        return .pendingMasterSupport
    }
}

@MainActor
final class AutoVlogConsentStore: ObservableObject {
    static let shared = AutoVlogConsentStore()
    private let defaults: UserDefaults
    private let key = "neox.autoVlogConsent.v1"
    @Published private(set) var consent: AutoVlogConsent?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        consent = defaults.data(forKey: key).flatMap {
            try? JSONDecoder().decode(AutoVlogConsent.self, from: $0)
        }
    }

    func consent(for selectedMaster: String?) -> AutoVlogConsent? {
        guard let selectedMaster, consent?.masterName == selectedMaster else { return nil }
        return consent
    }

    func set(enabled: Bool, selectedMaster: String?, lookbackDays: Int, maxCandidates: Int) {
        guard let selectedMaster, !selectedMaster.isEmpty else { return }
        let next = AutoVlogConsent(masterName: selectedMaster, enabled: enabled,
                                   lookbackDays: lookbackDays, maxCandidates: maxCandidates)
        guard next.hasSafeBounds else { return }
        consent = next
        defaults.set(try? JSONEncoder().encode(next), forKey: key)
    }
}

struct AutoVlogSettingsView: View {
    let selectedMaster: String?
    @ObservedObject var settings: AutoVlogConsentStore
    @Environment(\.dismiss) private var dismiss
    @State private var days = 7
    @State private var maximum = 10

    var body: some View {
        NavigationStack {
            Form {
                Section("Neo Master") {
                    Text(selectedMaster ?? "No Master selected")
                    Text("Uses your Home screen selection. This screen cannot change it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Private draft permission") {
                    Toggle("Allow automatic candidate selection", isOn: Binding(
                        get: { settings.consent(for: selectedMaster)?.enabled == true },
                        set: { settings.set(enabled: $0, selectedMaster: selectedMaster,
                                            lookbackDays: days, maxCandidates: maximum) }
                    ))
                    .disabled(selectedMaster == nil)
                    Picker("Recent media", selection: $days) {
                        Text("1 day").tag(1)
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                    }
                    Picker("Maximum candidates", selection: $maximum) {
                        Text("5").tag(5)
                        Text("10").tag(10)
                        Text("20").tag(20)
                    }
                    Text("Only select candidates for a private draft. No public release or GPS sharing is authorized.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Availability") {
                    Text(availabilityText)
                    Text("Automatic selection requires Neo Master support and the phone to be reachable at home. The app does not keep media access running in the background.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Auto Vlog")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
            .onAppear { loadBounds() }
            .onChange(of: days) { _, _ in saveBounds() }
            .onChange(of: maximum) { _, _ in saveBounds() }
        }
    }

    private var availabilityText: String {
        switch AutoVlogAvailability.resolve(selectedMaster: selectedMaster, consent: settings.consent) {
        case .noMaster: "Select a Neo Master on the Home screen."
        case .off: "Off — no automatic media selection."
        case .pendingMasterSupport: "Permission saved on this iPhone. Waiting for Neo Master support; automatic selection is not active."
        }
    }

    private func loadBounds() {
        let existing = settings.consent(for: selectedMaster)
        days = existing?.lookbackDays ?? 7
        maximum = existing?.maxCandidates ?? 10
    }

    private func saveBounds() {
        guard let existing = settings.consent(for: selectedMaster) else { return }
        settings.set(enabled: existing.enabled, selectedMaster: selectedMaster,
                     lookbackDays: days, maxCandidates: maximum)
    }
}
