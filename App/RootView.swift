import SwiftUI
import UIKit

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

    var iconFilled: String {
        switch self {
        case .image: return "photo.stack.fill"
        case .video: return "film.stack.fill"
        }
    }
}

/// 底部浮动胶囊导航：材质底 + 边缘高光 + 选中块随切换滑动。
/// iOS 26 起系统 TabBar 会自带 Liquid Glass；这里用手写材质条保证 iOS 17+ 观感一致，
/// 且不依赖 iOS 18/26 才有的 API，避免 SDK 差异导致编译失败。
@MainActor
struct GlassTabBar: View {
    @Binding var selection: AppTab
    @Namespace private var namespace
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                button(for: tab)
            }
        }
        .padding(5)
        .background(background)
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.55), .white.opacity(0.08), .white.opacity(0.22)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.7
                )
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(.black.opacity(0.12), lineWidth: 0.5)
                .blendMode(.overlay)
        )
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        .padding(.horizontal, 58)
        .padding(.bottom, 2)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: selection)
    }

    private func button(for tab: AppTab) -> some View {
        let isSelected = selection == tab
        return Button {
            if selection != tab {
                selection = tab
                Haptics.tap()
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: isSelected ? tab.iconFilled : tab.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                Text(tab.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, isSelected ? 18 : 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background {
                if isSelected {
                    Capsule(style: .continuous)
                        .fill(selectedFill)
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(.white.opacity(0.34), lineWidth: 0.6)
                        )
                        .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
                        .matchedGeometryEffect(id: "selection", in: namespace)
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
    }

    private var selectedFill: some ShapeStyle {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.30), Color.accentColor.opacity(0.16)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    @ViewBuilder
    private var background: some View {
        let shape = Capsule(style: .continuous)
        if reduceTransparency {
            shape.fill(.regularMaterial)
        } else {
            shape
                .fill(.ultraThinMaterial)
                .overlay(
                    shape.fill(
                        LinearGradient(
                            colors: [.white.opacity(0.18), .clear, .white.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                )
        }
    }
}

@MainActor
enum Haptics {
    static func tap() {
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.prepare()
        generator.impactOccurred(intensity: 0.7)
    }
}

@MainActor
struct RootView: View {
    @State private var tab: AppTab = .image

    var body: some View {
        Group {
            switch tab {
            case .image:
                ContentView()
            case .video:
                VideoView()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            GlassTabBar(selection: $tab)
                .padding(.top, 6)
                .padding(.bottom, 4)
        }
        .background(Color(.systemBackground))
    }
}

#Preview {
    RootView()
}
