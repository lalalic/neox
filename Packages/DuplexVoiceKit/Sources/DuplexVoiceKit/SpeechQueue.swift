import Foundation

/// One queue per assistant reply. Messages are validated in producer sequence,
/// synthesized in sentence order, and played FIFO. `completed` is not delivered
/// until output playback has drained. An interruption invalidates late output.
public actor SpeechQueue {
    private let synthesis: any SpeechSynthesisProvider
    private let output: any SpeechAudioOutput
    private let language: String
    private var merger: SentenceMerger
    private var nextSequence = 1
    private var seen: [Int: String] = [:]
    private var pending: [String] = []
    private var worker: Task<Void, Never>?
    private var terminal = false
    private var cancelled = false
    private var finished = false
    private var failure: Error?
    private var waiters: [CheckedContinuation<Void, Error>] = []

    public init(synthesis: any SpeechSynthesisProvider,
                output: any SpeechAudioOutput,
                language: String = "en-US",
                maximumPhraseCharacters: Int = 180) {
        self.synthesis = synthesis
        self.output = output
        self.language = language
        self.merger = SentenceMerger(maximumCharacters: maximumPhraseCharacters)
    }

    public func accept(sequence: Int, text: String) throws {
        if let previous = seen[sequence] {
            guard previous == text else { throw SpeechQueueError.conflictingReplay(sequence: sequence) }
            return
        }
        guard !terminal && !cancelled else { throw SpeechQueueError.alreadyTerminal }
        guard sequence == nextSequence else {
            throw SpeechQueueError.invalidSequence(expected: nextSequence, received: sequence)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpeechQueueError.emptyText
        }
        seen[sequence] = text
        nextSequence += 1
        pending += merger.append(text)
        startWorkerIfNeeded()
    }

    /// Marks the source stream complete and waits for the final audible output.
    public func complete() async throws {
        if !terminal {
            terminal = true
            if let tail = merger.finish() { pending.append(tail) }
            startWorkerIfNeeded()
            resolveIfDrained()
        }
        try await awaitPlayback()
    }

    public func fail(_ reason: String) async {
        guard !finished else { return }
        terminal = true
        failure = SpeechQueueError.upstream(reason)
        pending.removeAll()
        worker?.cancel()
        await output.stop()
        resolveWaiters()
    }

    /// User interruption stops playback and clears only this reply's queue.
    /// It does not cancel the upstream model request; hosts reject late events
    /// by their own request/turn generation identifier.
    public func interrupt() async {
        guard !cancelled && !finished else { return }
        cancelled = true
        terminal = true
        pending.removeAll()
        worker?.cancel()
        await output.stop()
        resolveWaiters()
    }

    public func isPlaybackFinished() -> Bool { finished }

    private func awaitPlayback() async throws {
        if cancelled { throw SpeechQueueError.cancelled }
        if let failure { throw failure }
        if finished { return }
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !pending.isEmpty, !cancelled, failure == nil else { return }
        worker = Task { await drain() }
    }

    private func drain() async {
        while !pending.isEmpty && !cancelled && failure == nil {
            let phrase = pending.removeFirst()
            do {
                try Task.checkCancellation()
                try await output.play(synthesis.synthesize(phrase, language: language))
                try Task.checkCancellation()
            } catch {
                if !cancelled { failure = error }
                pending.removeAll()
                break
            }
        }
        worker = nil
        resolveIfDrained()
    }

    private func resolveIfDrained() {
        if cancelled || failure != nil || (terminal && pending.isEmpty && worker == nil) {
            finished = !cancelled && failure == nil
            resolveWaiters()
        } else if worker == nil {
            startWorkerIfNeeded()
        }
    }

    private func resolveWaiters() {
        let results = waiters
        waiters.removeAll()
        for continuation in results {
            if cancelled { continuation.resume(throwing: SpeechQueueError.cancelled) }
            else if let failure { continuation.resume(throwing: failure) }
            else { continuation.resume() }
        }
    }
}
