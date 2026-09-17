import AVFoundation
import AVKit
import SwiftUI

struct CaptureTourCard: View {
    @ObservedObject var tours: CaptureTourStore
    @Binding var showingRunner: Bool

    var body: some View {
        if let session = tours.session, session.state != "completed" {
            Section("Capture Tour") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(session.manifest.title).font(.headline)
                    Text("Shot \(min(session.currentIndex + 1, session.manifest.shots.count)) / \(session.manifest.shots.count)")
                        .font(.subheadline).foregroundStyle(.secondary)
                    HStack {
                        Button(session.state == "pending" ? "Start" : "Resume") { tours.begin(); showingRunner = true }
                            .buttonStyle(.borderedProminent)
                        Button("Cancel", role: .destructive) { tours.cancel() }.buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

struct CaptureTourRunnerView: View {
    @ObservedObject var tours: CaptureTourStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = CaptureRecorder()
    @State private var takeCount = 0
    @State private var reviewURL: URL?
    @State private var warning = ""

    var body: some View {
        NavigationStack {
            Group {
                if let session = tours.session, session.state == "completed" {
                    completion(session)
                } else if let session = tours.session, session.currentIndex < session.manifest.shots.count {
                    shotView(session, shot: session.manifest.shots[session.currentIndex])
                } else {
                    ContentUnavailableView("No active tour", systemImage: "film")
                }
            }
            .navigationTitle(tours.session?.manifest.title ?? "Capture Tour")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
        }
        .task { await prepareCamera() }
        .onChange(of: recorder.isRecording) { _, recording in if !recording, let url = recorder.lastURL { reviewURL = url } }
        .onChange(of: recorder.qualityWarning) { _, value in if !value.isEmpty { warning = value } }
        .onDisappear { if recorder.isRecording { recorder.stop() } }
    }

    @ViewBuilder private func shotView(_ session: CaptureTourSession, shot: CaptureShot) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack { Text("Shot \(session.currentIndex + 1) of \(session.manifest.shots.count)").font(.subheadline.bold()); Spacer(); Text(shot.title).font(.subheadline) }
                ZStack {
                    CapturePreview(session: recorder.session).frame(height: 360).clipShape(RoundedRectangle(cornerRadius: 18))
                    RoundedRectangle(cornerRadius: 100).stroke(.white.opacity(0.75), style: StrokeStyle(lineWidth: 2, dash: [8])).frame(width: 220, height: 290)
                    VStack { Spacer(); Text(guidance(for: shot)).font(.callout.bold()).padding(8).background(.black.opacity(0.55)).clipShape(Capsule()).foregroundStyle(.white).padding(.bottom, 12) }
                }
                if let script = shot.script, !script.isEmpty { Text(script).font(.title3).multilineTextAlignment(.center).padding(.horizontal) }
                if let instruction = shot.instruction, !instruction.isEmpty { Text(instruction).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                if let target = shot.targetDurationS { ProgressView(value: min(recorder.elapsed / max(target, 0.1), 1)).tint(recorder.elapsed >= target ? .green : .accentColor); Text("\(recorder.elapsed, specifier: "%.1f") / \(target, specifier: "%.0f")s") .font(.caption.monospacedDigit()) }
                else { Text("\(recorder.elapsed, specifier: "%.1f")s").font(.caption.monospacedDigit()) }
                if !warning.isEmpty { Label(warning, systemImage: "info.circle").font(.caption).foregroundStyle(.orange) }
                if let reviewURL { reviewView(reviewURL, session: session, shot: shot) }
                else {
                    Button { recordOrStop() } label: { Label(recorder.isRecording ? "Stop" : "Record", systemImage: recorder.isRecording ? "stop.fill" : "record.circle").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).tint(recorder.isRecording ? .red : .accentColor)
                }
            }.padding()
        }
    }

    @ViewBuilder private func reviewView(_ url: URL, session: CaptureTourSession, shot: CaptureShot) -> some View {
        VStack(spacing: 10) {
            VideoPlayerView(url: url).frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 14))
            HStack {
                Button("Retake") { reviewURL = nil; warning = ""; takeCount += 1 }
                Button("Skip") { finishShot(session, shot: shot, status: "skipped", url: nil) }
                Button("Accept") { finishShot(session, shot: shot, status: "accepted", url: url) }.buttonStyle(.borderedProminent)
            }
        }
    }

    private func completion(_ session: CaptureTourSession) -> some View {
        VStack(spacing: 16) { Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green); Text("Tour complete").font(.title2.bold()); Text("\(session.results.filter { $0.status == "accepted" }.count) accepted · \(session.results.filter { $0.status == "skipped" }.count) skipped").foregroundStyle(.secondary); Button("Done") { dismiss() }.buttonStyle(.borderedProminent) }.padding()
    }

    private func prepareCamera() async { guard let shot = currentShot else { return }; await recorder.prepare(camera: shot.camera, orientation: shot.orientation, lens: shot.lens, quality: shot.quality) }
    private var currentShot: CaptureShot? { guard let s = tours.session, s.currentIndex < s.manifest.shots.count else { return nil }; return s.manifest.shots[s.currentIndex] }
    private func recordOrStop() { if recorder.isRecording { recorder.stop() } else { let url = ServerController.shared.exportsDir.appendingPathComponent("tour-\(UUID().uuidString).mov"); recorder.start(to: url) } }
    private func guidance(for shot: CaptureShot) -> String { if recorder.isRecording { return shot.targetDurationS.map { recorder.elapsed >= $0 ? "Target reached — keep recording or stop" : "Recording" } ?? "Recording" }; return shot.framing?.guide?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Set up your shot" }

    private func finishShot(_ session: CaptureTourSession, shot: CaptureShot, status: String, url: URL?) {
        var updated = session
        updated.results.removeAll { $0.shotID == shot.id }
        updated.results.append(CaptureResult(shotID: shot.id, status: status, takeCount: takeCount + 1, actualDurationS: recorder.elapsed, createdAt: Date(), mediaReference: url.map { "/files/\($0.lastPathComponent)" }, qualityWarnings: warning.isEmpty ? [] : [warning]))
        updated.currentIndex += 1; updated.state = updated.currentIndex >= updated.manifest.shots.count ? "completed" : "ready"
        tours.update(updated); reviewURL = nil; takeCount = 0; warning = ""
        if updated.state != "completed" { let next = updated.manifest.shots[updated.currentIndex]; Task { await recorder.prepare(camera: next.camera, orientation: next.orientation, lens: next.lens, quality: next.quality) } }
    }
}

struct VideoPlayerView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> AVPlayerViewController { let vc = AVPlayerViewController(); vc.player = AVPlayer(url: url); vc.player?.play(); return vc }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}
}
