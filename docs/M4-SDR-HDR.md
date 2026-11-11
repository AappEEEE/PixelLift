# PixelLift 视频 SDR → HDR（HLG）

## 当前实现

- 入口位于视频页；可开关 HLG，并提供 0–100% 高光肩部强度滑杆。
- SDR 源帧处理为：解码到 RGB8 → sRGB/BT.709 EOTF → 在线性光域计算亮度并作可调高光肩部 → 线性 Rec.709/BT.709 primaries 转线性 Rec.2020 → 分量级 BT.2100 HLG OETF → 按 BT.2020 coefficients 生成 Y′CbCr 4:2:0 video-range P010（10-bit 左对齐）→ HEVC。
- 输出标注 BT.2020 primaries / matrix + BT.2100 HLG transfer；SDR 路径继续用 8-bit BGRA 和 Rec.709 metadata。
- SDR reference white 映射至 HLG 场景参考白 0.75。亮度肩部以 `u = clamp((Y−0.70)/0.30, 0, 1)`、`k = u²(3−2u)` 定义，`Y' = Y + strength × 0.30 × k²`，使低于 70% 线性亮度的暗部/中间调保持不动。之后线性 Rec.2020 各 RGB 分量分别施加 HLG OETF，再计算非线性 BT.2020 Y′CbCr。固定 4×4 Bayer dithering 在空间上打散 10-bit 量化边界，避免时域随机噪声。
- 输出上限沿用 SDR 的 4K / 830 万像素：P010 单帧缓冲只有同尺寸 BGRA 的一半（4K 约 12MB），瓶颈在 AI 推理与逐像素换算，不在编码器。尺寸必须为偶数（4:2:0 色度），规划里会自动取偶。
- 码率按 0.12 bpp × 像素数 × 输出帧率估算（4K30 约 30 Mbps），下限 8 Mbps。若真机出现编码器拒绝或不支持 Main10，需要回退到 8-bit SDR 输出并在 UI 明确提示。

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


## 设备兼容性与回退

AVAssetWriterInput 在输出配置非法时会抛 ObjC 异常（Swift 的 do/catch 接不住，表现为直接闪退）。真机上已经踩到过一次：AVVideoAllowWideColorKey 的值必须是 NSNumber，放进去就崩。现在的做法：

1. HDR 只设 AVVideoColorPropertiesKey 的 primaries / transfer / matrix 三项，SDR 完全不设色彩属性（BGRA 里带 YCbCrMatrix 是非法组合）。
2. 所有 AVAssetWriterInput 的创建都包在 PLTryCatch（ObjC @try/@catch）里，抛异常就回退 SDR 并提示「已自动回退到 SDR」。
3. 即使创建成功，writer.canAdd 为 false 也会再回退一次；两次都失败才报错。
4. P010 像素池取不到时给出明确文案，而不是笼统的「帧写入失败」。

## 稳定性与性能修复（v0.1.37）

一轮静态审查（无真机）后修掉的运行时问题，逐条对应到代码：

1. **输出尺寸单一出口**：plan() 返回前统一把宽高取偶并夹到 ≥2，writer / adaptor / P010 / makeFrame 全吃这一份，杜绝奇数或 0 尺寸导致 AVAssetWriterInput 抛异常、或 makeFrame 与 CGContext 尺寸不一致造成的堆越界。
2. **adaptor 也进异常护栏**：AVAssetWriterInputPixelBufferAdaptor 的字典 init 同样会抛 ObjC 异常，现在包在 PLTryCatch 里，失败给明确文案。
3. **任何路径退出都收尾**：defer 里 cancelReading + （未成功时）cancelWriting + 删临时文件，避免 reader 悬空读取、半个 mp4 留在 tmp。
4. **编码器失败不再死循环**：等 isReadyForMoreMediaData 的循环里检查 writer.status == .failed。
5. **音频包时间戳钳位**：跨片起点的包平移后 PTS 为负会被 writer 拒收，现在钳到 0；被丢弃的包会计数并在结束时提示。
6. **视频结束后抽干音轨**：以前视频先读完就 markAsFinished，音轨比视频长时末尾掉音，现在补一段 drain。
7. **丢帧不再装作没事**：makeFrame 连续失败 8 帧直接中止并报错，而不是静默丢帧让补帧插到错误位置。
8. **分片拼接严格化**：缺片 / 空片直接报错（以前静默跳过，用户会拿到缺一段的视频却显示完成）；export.timeRange 改用 comp.duration；末片按剩余时长截断。
9. **P010 抖动零分配**：4×4 Bayer 表提成 SDRToHDR.bayer4 静态表，逐像素不再新建数组（4K 一帧原本 830 万次小对象分配）。
10. **4K 缓冲按需分配**：ccum（动态模糊）与 stableA/B（抗闪烁）只在开启时分配，4K SDR 快速放大少占 100MB+。
11. **载入不再卡主线程**：load() 的文件搬移挪到后台队列，且优先 moveItem（源本来就是选择器给的临时副本），省掉一次全量写盘——4K60 一分钟素材原本会让主线程阻塞十几秒，有看门狗风险。
12. **Core ML 输出契约校验**：inferTile 读 o.shape 并校验 [1,3,1024,1024] + count，类型只接受 float32/float16/double；不符或量化模型直接抛错走插值，不再裸指针越界。