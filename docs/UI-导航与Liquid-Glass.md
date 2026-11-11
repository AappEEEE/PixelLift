# 底部导航：为什么改用系统 `TabView`

## 你指出的问题

之前那条底部导航是我手写的「浮动胶囊条」：

- `Capsule` + `.ultraThinMaterial` 当玻璃底
- 三条白色 `LinearGradient` 描边当边缘高光
- `.matchedGeometryEffect` 让选中块滑动
- 手加 `.shadow` 和 `UIImpactFeedbackGenerator` 触感

看起来像玻璃，但它不是 Apple 的 Liquid Glass：

| 维度 | 系统 Liquid Glass | 手写材质条 |
|---|---|---|
| 材质与模糊半径 | 由系统按背景内容实时计算（含颜色提取） | 固定 `ultraThinMaterial`，与背景无关 |
| 高光 | 随设备姿态/内容自适应，按压时有形变 | 静态渐变，永远朝左上 |
| 与滚动内容的联动 | 滚动时自动出现「边缘效果」（内容在玻璃下柔化） | 无，只能靠 `safeAreaInset` 硬留白 |
| 形状与安全区 | 由系统按设备、方向、无障碍设置决定 | 我写死 `padding(.horizontal, 58)` |
| 无障碍 | 自动处理对比度、降低透明度、VoiceOver | 需要我自己兜 `accessibilityReduceTransparency` |
| 未来适配 | 跟随系统升级 | 系统改设计后立刻「不像」 |

所以这不是「实现得不够精细」，而是**方向错了**：Liquid Glass 是系统拥有的图层，App 不应该手绘它。

## 现在的做法

`App/RootView.swift` 改成和参考项目（Project m3u8 的 `Sources/App/RootView.swift`）同一套写法：

```swift
TabView(selection: $tab) {
    ContentView()
        .tabItem { Label("图片", systemImage: "photo.on.rectangle.angled") }
        .tag(AppTab.image)

    VideoView()
        .tabItem { Label("视频", systemImage: "film.stack") }
        .tag(AppTab.video)
}
.tint(.accentColor)
```

删掉了：`GlassTabBar`、`Haptics`、`matchedGeometryEffect`、`safeAreaInset(edge: .bottom)` 自绘条。
内容页本来就各自 `NavigationStack` + `ScrollView`，系统会自动处理标签栏占位与滚动边缘效果。

## 关键前提：必须用 iOS 26 SDK 编译

只把 `TabView` 写对还不够。App 用**旧 SDK** 链接时，iOS 26 会走「兼容外观」，标签栏仍是老样式，看不到 Liquid Glass。

因此 CI 增加了选工具链的步骤（`.github/workflows/ios.yml`）：

```yaml
for candidate in /Applications/Xcode_26.3.app /Applications/Xcode_26.2.app \
                 /Applications/Xcode_26.1.app /Applications/Xcode_26.1.1.app \
                 /Applications/Xcode_26.0.app /Applications/Xcode_26.0.1.app ; do
  if [ -d "$candidate" ]; then sudo xcode-select -s "$candidate"; break; fi
done
```

`macos-15` 镜像自带 Xcode 26.0–26.3（默认仍是 16.4），脚本按从新到旧挑第一个存在的。

结果：

- **iOS 26+**：标签栏由系统按 Liquid Glass 渲染（半透明玻璃、内容滚动时的边缘效果、按压高光形变、无障碍自动适配）。
- **iOS 17–18**：回落经典标签栏，行为一致，不会因为调了 26 才有的 API 而崩溃。
- 代码里**没有**任何 `glassEffect` / `GlassEffectContainer` 调用，所以即使 CI 退回到 Xcode 16 也仍能编译——只是拿不到新外观。

## 什么情况下才该自己画

只有当需要「浮在内容上方的自定义控件」时才用 iOS 26 的显式 API：

```swift
if #available(iOS 26.0, *) {
    controls.glassEffect(.regular.tint(.accentColor).interactive(), in: .capsule)
}
```

而且这些控件必须放进 `GlassEffectContainer`，系统才能正确合并相邻玻璃、算共享的背景模糊。
本 App 目前没有这类元素（所有面板都是内容卡片，用 `.thinMaterial` 即可，HIG 也不建议把内容卡片做成玻璃），所以没有引入。

## 验收

- 装最新 IPA，在 iOS 26 设备上左右滑动切换两个标签：应看到系统标签栏，玻璃底透出后面内容。
- 滚动内容页，标签栏应出现系统的滚动边缘效果（内容在栏下柔化），而不是我手写的固定描边。
- 打开「设置 → 辅助功能 → 显示与文字大小 → 降低透明度」，标签栏应变成不透明底。
