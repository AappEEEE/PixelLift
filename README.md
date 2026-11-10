# PixelLift

**iOS 图片 / 视频画质增强工具**（本地运行、零上传、零订阅）。

一个 App 两套能力：图片 AI 超分 + 视频超分 / 补帧 / 慢动作 / 动态模糊 / SDR→HDR（HLG/BT.2020 10-bit）。

## 图片

- 原生 **4×** AI 重建（Real-ESRGAN 现成权重转 Core ML，零训练）
- 倍率：**1.5× / 2× / 2.5× / 3× / 4× / 6× / 8×** + 自定义宽度
- 两种模型档：照片/实拍、动漫/插画
- **批量处理**：相册多选（最多 20 张）或从「文件」无限导入，逐张独立进度
- 暂停 / 继续 / 取消，分块推理实时进度
- 导出 PNG / JPEG，或一键全部存入相册
- AI 重建分辨率自动取「目标尺寸 ÷ 4」，上限长边 2048px，避免先砍细节再放大

## 视频

- 快速放大（CoreGraphics 高质量重采样）或 **AI 逐帧超分**
- **光流补帧**（Vision `VNGenerateOpticalFlowRequest`）→ ×2 / ×4，30fps 变 60/120fps
- **慢动作** 0.5× / 0.25×，中间帧同样由光流合成
- **动态模糊**（多采样叠加，近似快门拖影）
- **SDR→HDR**：可调高光肩部，Rec.709 SDR → HLG/BT.2020 10-bit HEVC（P010）
- 暂停 / 继续 / 取消，进度实时；输出 HEVC `.mp4`，只补帧时音频原样透传
- SDR 输出上限 4K / 830 万像素；HDR 约 1080p / 2.1MP；补帧/慢动作再受算力限制

不需要任何特殊 entitlement → 免费 Apple ID 自签 7 天即可安装。

## 路线

| 版本 | 内容 | 状态 |
|---|---|---|
| **v0.1.x** | 图片 AI 超分（M1） | 已发布 |
| **v0.2** | 视频通路：重采样放大 / AI 逐帧超分（M2） | 已发布 |
| **v0.3** | 光流补帧 + 慢动作 + 动态模糊（M3） | 已发布 |
| **v0.4** | SDR→HDR：HLG/BT.2020 10-bit 输出 + 高光强度控制 | 已实现，待真机画质验收 |
| v0.5 | 分片导出 + 暂停续传（长视频不爆内存） | 计划 |
| v0.6 | 逐帧超分抗闪烁（光流时域融合 + VT 时域降噪） | 计划 |
| v0.6 | 逐帧超分抗闪烁（光流时域融合 + VT 时域降噪） | 计划 |

## 构建

推送到 `main` 即自动构建（GitHub Actions `macos-15`），产物：

- Artifacts：`PixelLift-ipa-v0.1.N`（内含 `PixelLift.ipa` + `PixelLift.ipa.sha256`）
- Releases：`PixelLift.ipa` + `PixelLift.ipa.sha256`（每次构建一个新 tag）

安装与排错见 [docs/构建与装机.md](docs/构建与装机.md)；视频管线见 [docs/M3-视频-补帧与慢动作.md](docs/M3-视频-补帧与慢动作.md)，HDR 算法和真机验收清单见 [docs/M4-SDR-HDR.md](docs/M4-SDR-HDR.md)。

## 目录

```
App/             SwiftUI + Core ML 推理 + 视频管线
Models/          Core ML 模型（CI 生成，不入库）
scripts/         Real-ESRGAN 转换、测试与推送脚本
docs/            可行性、交付说明、构建装机、视频/HDR 管线
.github/         Actions：构建 + 发布 Release
project.yml      XcodeGen 工程描述
```
