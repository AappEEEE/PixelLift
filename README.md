# PixelLift

**iOS 视频画质增强工具**（本地运行、零上传、零订阅）。

目标能力：AI 超分、AI 补帧、慢动作、动态模糊、SDR→HDR。
**当前第一个 Release 只包含图片处理（AI 超分）**，视频管线在后续版本。

- 原生 **4×** AI 重建（Real-ESRGAN 现成权重转 Core ML，零训练）
- 倍率：**1.5× / 2× / 2.5× / 3× / 4× / 6× / 8×** + 自定义宽度
- 两种模型档：照片/实拍、动漫/插画
- **批量处理**：相册多选（最多 20 张）或从「文件」无限导入，逐张独立进度
- 暂停 / 继续 / 取消，分块推理实时进度
- 导出 PNG / JPEG，或一键全部存入相册
- 不需要任何特殊 entitlement → 免费 Apple ID 自签即可安装

## 路线

| 版本 | 内容 | 状态 |
|---|---|---|
| **v0.1.x** | 图片 AI 超分（本文档描述的 M1） | 已发布 |
| v0.2 | 视频通路：4K/HDR 直通、分片暂停续传 | 计划 |
| v0.3 | AI 补帧（`VTFrameRateConversion`）+ 慢动作 + 音频重定时 | 计划 |
| v0.4 | 视频超分 + 光流时域融合抗闪 | 计划 |
| v0.5 | 动态模糊（Metal 快门角度） | 计划 |
| v0.6 | SDR→HDR（HDRTVNet / ExpandNet 转 Core ML） | 计划 |

## 构建

推送到 `main` 即自动构建，产物：

- GitHub Actions Artifacts：`PixelLift-unsigned-ipa`
- GitHub Releases：`PixelLift-unsigned.ipa`（每次构建一个新 tag）

详见 [docs/构建与装机.md](docs/构建与装机.md)。

## 目录

```
App/             SwiftUI + Core ML 推理
Models/          Core ML 模型（CI 生成，不入库）
scripts/         Real-ESRGAN → Core ML 转换脚本
.github/         Actions：构建 + 发布 Release
project.yml      XcodeGen 工程描述
```

## 许可证

本仓库代码：自用无限制。
`RealESRGANGeneral` / `RealESRGANAnime` 权重来自 [xinntao/Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN)，**BSD 3-Clause**，需保留版权声明。商用请自行核对条款。
