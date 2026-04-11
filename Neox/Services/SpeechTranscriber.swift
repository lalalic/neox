import Speech

/// Transcribes audio files using Apple's on-device Speech framework.
/// Supports MP3, WAV, M4A, CAF formats returned by WeChat Web voice endpoint.
final class SpeechTranscriber: @unchecked Sendable {

    /// Transcribe an audio file at the given URL.
    /// Returns the transcribed text, or nil if transcription fails.
    func transcribe(fileURL: URL, locale: Locale = Locale(identifier: "zh-Hans")) async -> String? {
        // Request authorization if needed (one-time)
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard status == .authorized else {
            NSLog("[SpeechTranscriber] Not authorized: %d", status.rawValue)
            return nil
        }

        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            // Fallback to default locale
            guard let fallback = SFSpeechRecognizer(), fallback.isAvailable else {
                NSLog("[SpeechTranscriber] No recognizer available")
                return nil
            }
            return await doTranscribe(recognizer: fallback, fileURL: fileURL)
        }

        return await doTranscribe(recognizer: recognizer, fileURL: fileURL)
    }

    private func doTranscribe(recognizer: SFSpeechRecognizer, fileURL: URL) async -> String? {
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false

        return await withCheckedContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    NSLog("[SpeechTranscriber] Error: %@", error.localizedDescription)
                }
                if let result, result.isFinal {
                    let text = result.bestTranscription.formattedString
                    NSLog("[SpeechTranscriber] Transcribed: %@", String(text.prefix(100)))
                    continuation.resume(returning: text.isEmpty ? nil : text)
                } else if error != nil {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
