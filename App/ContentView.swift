// ContentView —— 占位首页（见 docs/architecture.md）。
import SwiftUI

struct ContentView: View {
    @Environment(\.scanEnvironment) private var scanEnvironment

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "doc.viewfinder")
                    .font(.largeTitle)
                Text(statusText)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .navigationTitle(String(localized: "app.title"))
            #if DEBUG
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            DewarpSelfTestView()
                        } label: {
                            Image(systemName: "waveform.path.ecg")
                        }
                        .accessibilityLabel("去畸变自测（开发用）")
                    }
                }
            #endif
        }
    }

    /// 从消费端反映组合根是否装配成功（G5 契约的消费端来源）。
    private var statusText: String {
        guard scanEnvironment?.pipeline != nil else {
            return String(localized: "pipeline.unavailable")
        }
        return String(localized: "pipeline.ready")
    }
}
