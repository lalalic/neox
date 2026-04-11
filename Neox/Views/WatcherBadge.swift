import SwiftUI

/// Compact badge showing the number of active background watcher sessions.
struct WatcherBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "eye.fill")
                .font(.system(size: 9))
            Text("\(count)")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.green.opacity(0.15), in: Capsule())
        .foregroundStyle(.green)
    }
}
