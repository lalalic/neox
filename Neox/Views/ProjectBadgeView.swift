import SwiftUI

/// Compact toolbar badge showing the active project name.
/// Used as the label for a Menu with primaryAction in the toolbar.
struct ProjectBadgeLabel: View {
    let currentProject: String?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: currentProject != nil ? "folder.fill" : "folder")
                .font(.caption)
            if let name = currentProject {
                Text(name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            currentProject != nil
                ? Color.blue.opacity(0.15)
                : Color.secondary.opacity(0.12),
            in: Capsule()
        )
        .foregroundStyle(currentProject != nil ? .blue : .primary)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }
}
