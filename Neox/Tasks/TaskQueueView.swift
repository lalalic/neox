import SwiftUI

struct TaskQueueView: View {
    var body: some View {
        NavigationStack {
            List {
                Text("No tasks yet")
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Tasks")
        }
    }
}
