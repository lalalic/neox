import ActivityKit
import SwiftUI
import WidgetKit

struct NeoxLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NeoxActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 6) {
                Text("N").font(.headline).bold()
                Text(detail(context.state)).lineLimit(1)
                if let progress = context.state.progress { ProgressView(value: progress) }
            }
            .padding()
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text("N").font(.headline).bold()
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.activeTaskCount == 0 ? "Online" : "\(context.state.activeTaskCount)")
                        .font(.title2.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading) {
                        Text(detail(context.state)).lineLimit(1)
                        if let progress = context.state.progress { ProgressView(value: progress) }
                    }
                }
            } compactLeading: {
                    Text("N").bold()
            } compactTrailing: {
                Text(context.state.activeTaskCount == 0 ? "✓" : "\(context.state.activeTaskCount)")
                    .monospacedDigit()
            } minimal: {
                Text("N").bold()
            }
        }
    }

    private func detail(_ state: NeoxActivityAttributes.ContentState) -> String {
        state.title ?? (state.activeTaskCount == 0 ? "MCP server online" : (state.activeTaskCount == 1 ? "1 task running" : "\(state.activeTaskCount) tasks running"))
    }
}

@main
struct NeoxLiveActivityBundle: WidgetBundle {
    var body: some Widget { NeoxLiveActivityWidget() }
}
