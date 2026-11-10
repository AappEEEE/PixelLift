import SwiftUI

@MainActor
struct RootView: View {
    @State private var tab: Int = 0

    var body: some View {
        TabView(selection: $tab) {
            ContentView()
                .tabItem { Label("图片", systemImage: "photo.on.rectangle.angled") }
                .tag(0)
            VideoView()
                .tabItem { Label("视频", systemImage: "film") }
                .tag(1)
        }
    }
}
