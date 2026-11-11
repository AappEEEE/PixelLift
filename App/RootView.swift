import SwiftUI

/// 两个主标签页。
enum AppTab: Int, CaseIterable, Hashable {
    case image
    case video

    var title: String {
        switch self {
        case .image: return "图片"
        case .video: return "视频"
        }
    }

    var icon: String {
        switch self {
        case .image: return "photo.on.rectangle.angled"
        case .video: return "film.stack"
        }
    }
}

/// 根视图：直接使用系统 `TabView` + `.tabItem`。
///
/// 之前这里是手写的浮动胶囊条（`.ultraThinMaterial` + 渐变描边 + matchedGeometryEffect），
/// 那只是"看起来像玻璃"，不是 Apple 的 Liquid Glass：材质、模糊半径、边缘高光、
/// 与滚动内容的联动都由系统控制，手绘无法对齐，反而不符合 HIG。
///
/// iOS 26 起系统 TabBar 会自动采用 Liquid Glass（含滚动边缘效果、按压的高光形变、
/// 标签合并/最小化），所以正确做法是让系统自己画——这也是 Project m3u8 里同一套写法。
/// 部署目标仍是 iOS 17：低于 26 的系统上就是标准 TabBar，行为一致且不需要任何
/// 仅在 Xcode 26 SDK 里存在的 API（`glassEffect` / `GlassEffectContainer` 在
/// 我们 CI 的 Xcode 16 上直接编译不过）。
@MainActor
struct RootView: View {
    @State private var tab: AppTab = .image

    var body: some View {
        TabView(selection: $tab) {
            ContentView()
                .tabItem { Label(AppTab.image.title, systemImage: AppTab.image.icon) }
                .tag(AppTab.image)

            VideoView()
                .tabItem { Label(AppTab.video.title, systemImage: AppTab.video.icon) }
                .tag(AppTab.video)
        }
        .tint(.accentColor)
    }
}

#Preview {
    RootView()
}
