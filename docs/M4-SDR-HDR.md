# PixelLift 视频 SDR → HDR（HLG）

## 当前实现

- 入口位于视频页；可开关 HLG，并提供 0–100% 高光肩部强度滑杆。
- SDR 源帧处理为：解码到 RGB8 → sRGB/BT.709 EOTF → 在线性光域计算亮度并作可调高光肩部 → 线性 Rec.709/BT.709 primaries 转线性 Rec.2020 → 分量级 BT.2100 HLG OETF → 按 BT.2020 coefficients 生成 Y′CbCr 4:2:0 video-range P010（10-bit 左对齐）→ HEVC。
- 输出标注 BT.2020 primaries / matrix + BT.2100 HLG transfer；SDR 路径继续用 8-bit BGRA 和 Rec.709 metadata。
- SDR reference white 映射至 HLG 场景参考白 0.75。亮度肩部以 `u = clamp((Y−0.70)/0.30, 0, 1)`、`k = u²(3−2u)` 定义，`Y' = Y + strength × 0.30 × k²`，使低于 70% 线性亮度的暗部/中间调保持不动。之后线性 Rec.2020 各 RGB 分量分别施加 HLG OETF，再计算非线性 BT.2020 Y′CbCr。固定 4×4 Bayer dithering 在空间上打散 10-bit 量化边界，避免时域随机噪声。
- 为控制转码热量和内存，开启 HDR 时输出限制在约 1920 长边 / 2.1MP，且尺寸必须为偶数（应用输出规划会保持偶数）。

## “HDR”能力边界

这是一条实际逐像素重映射 + 10-bit HLG 编码的 SDR→HDR 兼容链路，而非只写 HDR 标签。但输入本身是 8-bit SDR，HDR 转换是 display-referred 推导；不能恢复相机未记录或原片已裁剪的高光纹理，也没有神经网络进行场景理解/重打光。高光强度是可控、连续的全局 luma shoulder，画面可能因输入、运动模糊、源片曝光而观感不同。

## 本机检查

```powershell
python scripts/verify_hdr_math.py
```

数值测试覆盖 HLG 曲线有限和单调、白点/矩阵中性、亮度档位单调、黑色不抬升、P010 legal range。GitHub Actions `xcodebuild archive` 负责 Swift 编译和 IPA 产出。若 CI 产出的 IPA 构建成功，只代表源码/API 编译及打包成功，不等同于已验证导出的实际视频 bit depth、HLG 色彩元数据、设备编码器兼容性或主观效果。

## 仍需人工真机验收

当前开发机为 Windows，没有 Swift/Xcode 和 HDR 显示设备。CI 编译成功只能证明 API/类型可构建，不能证明具体 iPhone 的 P010→HEVC Main10 encoder 支持情况、硬件编码速度、照片 App/播放器对 HLG 元数据的解释和实际观感。用支持 HDR 的 iPhone 拍摄一段有天空/灯光/肤色/暗部的 SDR 视频，导出 HDR，检查：

1. Photos 预览与系统分享后 HDR 标签/显示是否稳定；
2. HLG 高光是否自然、肤色/白墙是否偏色、暗部是否压黑；
3. SDR 屏幕上回放是否明显发灰/发暗；
4. 对照强度 0/50/100% 及原视频，观察高光延展与暗部保留；
5. 长视频热量、输出码率、音轨透传、暂停/取消和保存相册。

任何一项失败，都先调节映射或把 HDR toggle 默认关闭；严禁将仅有元数据的 8-bit SDR 文件描述成 HDR 输出。
