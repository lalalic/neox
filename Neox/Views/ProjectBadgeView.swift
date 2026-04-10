import SwiftUI

/// Compact toolbar button showing the active project name.
/// Tapping opens the project picker sheet.
struct ProjectBadgeView: View {
    let currentProject: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: currentProject != nil ? "folder.fill" : "folder")
                    .font(.caption)
                if let name = currentProject {
                    Text(name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                currentProject != nil
                    ? Color.blue.opacity(0.12)
                    : Color.secondary.opacity(0.08),
                in: Capsule()
            )
            .foregroundStyle(currentProject != nil ? .blue : .secondary)
        }
    }
}
