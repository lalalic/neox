import SwiftUI

/// Local audio runs only while this sheet is visible. Chat still owns all
/// history and transport; leaving the sheet stops the microphone and speaker.
struct ChatVoiceSheet: View {
    @ObservedObject var voice: ChatVoiceConversation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 22) {
            HStack {
                Text("Voice conversation").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("neoChatVoiceDone")
            }
            Spacer()
            Image(systemName: voice.phase == .speaking ? "waveform" : "waveform.circle.fill")
                .font(.system(size: 70))
                .foregroundStyle(voice.phase == .error ? Color.red : Color.accentColor)
                .accessibilityHidden(true)
            Text(voice.phase.rawValue.capitalized)
                .font(.headline)
                .accessibilityIdentifier("neoChatVoiceState")
            if !voice.transcript.isEmpty {
                Text(voice.transcript)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("neoChatVoiceTranscript")
            }
            if !voice.assistantText.isEmpty {
                Text(voice.assistantText)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .lineLimit(8)
                    .accessibilityIdentifier("neoChatVoiceReply")
            }
            if let error = voice.errorText {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Spacer()
            if voice.phase == .speaking {
                Button("Interrupt") { voice.interruptReply() }
                    .accessibilityIdentifier("neoChatVoiceInterrupt")
            }
            Text("Listening remains active while the assistant speaks. Speak to interrupt.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .presentationDetents([.large])
        .accessibilityIdentifier("neoChatVoiceSheet")
    }
}
