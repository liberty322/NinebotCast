# NinebotCast（iOS 复刻 ninebot_pro 投屏）

复刻 [xmz28/ninebot_pro](https://github.com/xmz28/ninebot_pro) 的 iOS 端投屏：把测试图/相册/摄像头/屏幕画面投到九号电动车仪表。

原仓库只分发 Android APK（无源码），本项目按其 README 公开的协议参数从零重写 iOS 版。

## 同类项目调研（2026-11-15）

| 项目 | 路线 | 对本项目的价值 |
|---|---|---|
| [xmz28/ninebot_pro](https://github.com/xmz28/ninebot_pro) | Android APK，UDP 5012/5013 + RTP | 初始协议参照（20 字节头 / PT 32 / 毫秒时间戳 / 1380 分片） |
| [Xiaolangs/ninebot-cast-tweak](https://github.com/Xiaolangs/ninebot-cast-tweak) | iOS 九号出行 6.10.9 Ghidra 逆向 + 越狱 tweak | **最有价值**：投屏导航不是镜像屏幕，而是手机自绘 HUD（240×320 / 25fps / **500 kbps** / gop 10 / MTU 1400）；`RTPStandard==2` 才带视频专用扩展头；**RTCP APP 心跳 = 子类型 5、参数 [0,2]**；还有 BLE 与 KCP 两条备用通道 |
| [KaruMono/NinebotEnhance](https://github.com/KaruMono/NinebotEnhance) | Android LSPosed 模块，接管九号自己的编码发送链路 | **已在 M5P（车型 14103，仪表 848×480，Wi-Fi Direct H.264）实测**；并明确「是否开机由九号自己的巡航逻辑检查」——仪表必须先进投屏接收态 |
| [xmz28/ForzaDash](https://github.com/xmz28/ForzaDash) | ESP32 USB/Wi-Fi CAN 注入仪表（0x170/0x210/0x212） | 与视频投屏无关，但证明仪表数据面可注入，可作后续「速度/功率叠加」参考 |
| [OpenXPlay/OpenXPlay](https://github.com/OpenXPlay/OpenXPlay) | CarPlay 转发到安卓车机 | 只解释作者视频里 8443 那套 Web 接收端，不经九号仪表通道 |

据此修正的实现：心跳改官方 `APP subtype 5 / [0,2]`（保留计数变体兜底）、分片 1400/1380 可切换、gop 10、新增 848×480 25fps 800kbps 预设。

## CarPlay 直投（v0.21.0 新增）

### 为什么原来要开两个 App

| App | 干什么 | 问题 |
|---|---|---|
| ninebot_pro（iOS） | 把画面打包成 RTP 丢给仪表 UDP 5012 | 走的是自家 OXP 客户端，只认 OXP 那套 `hello` → `format` → 二进制帧 |
| CarWithin | 把 CarPlay 画面用 WebSocket 发出来 | 只认浏览器那套 `ready` → `display` → 然后才推流 |

两边用的都是 WebSocket + JSON + 二进制帧，但**握手完全对不上**：

- ninebot_pro 连上 CarWithin 的 `/stream` 后，直接发自己的 `hello`，然后就在等 `format`；
- CarWithin 在收到 WebSocket 升级请求后**什么都不发**，它在等接收端先自报家门：

```jsonc
{"type":"ready","decoder":"mse","viewer":"<uuid>","audioClock":false}
{"type":"display","w":848,"h":480,"dpr":1,"sw":848,"sh":480,"hz":60,"h265":false,"fullscreen":false,"ua":"..."}
```

没有 `ready`，CarWithin 不进推流状态，`hello` / `format` / 视频帧一个都不发。所以 ninebot_pro 的日志永远停在
`openxplay websocket已连接，正在请求h.264画面`——TCP 层连着，应用层互相等对方先开口，死锁。

### 这个版本怎么修的

`Sources/CarWithinSource.swift` 是一个从零写的 CarWithin 客户端，接进 NinebotCast 原有的投屏管线：

1. **握手**：WebSocket 建立后立刻发 `ready`（`decoder=mse`，`audioClock=false`）+ `display`（上报仪表分辨率、`h265=false`），
   收到 `hello` 后再补发一次 `display`（CarWithin 靠这个重选编码器）；
2. **保活**：每秒 `{"type":"ping","t0":<微秒>}`，并处理 `pong`；
3. **解析 `format`**：`description` 是 base64 的 `avcC`，解出 SPS/PPS → `CMVideoFormatDescriptionCreateFromH264ParameterSets`
   → `VTDecompressionSession`（顺带兼容 `hvcC`/HEVC，万一 CarWithin 坚持发 H.265）；
4. **拆帧**：`[0]` 是 tag，`3` 音频丢弃，`4`/`5` 表示带 8 字节时间戳的视频（`kind = tag-4`），body 从 `[9]` 或 `[1]` 起；
   `kind==1` 即关键帧。body 本身就是 AVCC 长度前缀 NAL，直接塞 `CMBlockBuffer` 解码，不用转 Annex-B；
5. **等关键帧**：`format` 到达或解码报错时发 `{"type":"keyframe","reason":"..."}`（限速 1 秒 1 次），避免花屏；
6. **上屏**：解出的 `CVImageBuffer` 经 CIImage 旋转 + aspect-fill 铺满 848×480，3 块 buffer 轮换，
   交给原来的 `produceFrame()` → VideoToolbox → RTP → UDP 5012。

断线自动 3 秒重连，状态实时显示在「画面来源 → CarPlay」卡片下面。

### 用法

1. iPhone 上开 CarWithin，进 CarPlay；
2. 打开本 App，「画面来源」选 **CarPlay**，填 CarWithin 的地址（默认 `192.168.1.x:9888`，HTTPS 端口 9889 要写 `https://` 前缀）；
3. 填仪表 IP，点「开始投屏」。

> iOS 上 CarPlay 的画面只有 CarWithin 拿得到（第三方 App 没有 CarPlay 视频出口），所以 CarWithin 仍要在后台跑，
> 但**不用再切回 ninebot_pro 了**，仪表投屏由这一个 App 完成。

## 版本记录

| 版本 | 变更 |
|------|------|
| 0.21.0 (21) | **CarPlay 直投**：内置 `CarWithinSource`，自己完成 CarWithin 要求的 `ready`/`display` 握手，解析 `format`（base64 avcC）建 `VTDecompressionSession`，按 9 字节/1 字节头拆二进制帧，1 Hz `ping` 保活，解码失败自动请求关键帧，断线 3 秒重连。画面走原有 RTP 管线投到仪表，**不再需要 ninebot_pro 同时运行**；「画面来源」新增 CarPlay 卡片（地址持久化、状态实时显示） |
| 0.20.0 (20) | **自动投屏**：开启后每 4 秒用 RTCP 心跳探一次仪表（轻量 UDP，不做 TCP 扫描），一旦仪表回包（说明已进入接收态）就按上次设置自动开始，不用再点按钮。**关于「第一步」**：让仪表进入接收态只能由九号官方 App 经 BLE 私有协议 + 序列号派生密钥的加密握手触发（新固件还要云端 token），没有官方凭证无法替代——这一步必须手动，之后全自动 |
| 0.19.0 (19) | **摄像头默认 90°**（摄像头与其它来源各自记忆方向）；**延迟再降**：摄像头渲染由「定时器轮询」改为**帧到即渲染**（少一层等待，最高砍掉一整帧间隔）；**画质提升**：新增画质一键档（流畅 10fps/400k · 均衡 15fps/800k · **清晰 20fps/1.2M（默认）** · 极致 25fps/2M）；仪表 IP / 预设 / 画质 / 分片等设置持久化，下次打开自动带出（IP 为空时自动填网关） |
| 0.18.0 (18) | **降延迟**：编码器 MaxFrameDelayCount=0（不许攒帧）+ DataRateLimits 1.25 倍均值限幅（大 I 帧不再挤占发送队列）；发送 pacer 改**自适应加速**（有积压时 2→10 包/ms 追平，平时保持匀速）；积压 >120 包直接丢整帧不再入队；状态卡显示主动丢帧数 |
| 0.17.0 (17) | **运动画面卡顿的系统性优化**：① RTP 发送改为**限流**（每毫秒最多 2 包，避免运动画面几十个包突发把仪表网卡打丢）② 编码**背压**（在飞帧 ≥3 直接跳过本拍，防止延迟越滚越大）③ 发送独立 `videoQueue`，编码回调不再 sync 到控制队列 ④ 积压超 900 包自动丢弃旧帧（宁卡不延迟）⑤ 界面新增**帧率 / 码率 / GOP / 分辨率**可调（默认 15fps / 600kbps）⑥ 实时显示**实测 fps / 帧均 KB / 待发积压**，并每 5 秒写一行统计日志 ⑦ 默认关闭关键帧重发 |
| 0.16.0 (16) | **摄像头流畅化**：渲染（720p→仪表尺寸）移出发送线程——采集回调只存原始帧，独立渲染线程按投屏帧率出成品（画面没动自动跳过，静态场景近零 CPU），发送端只编码不渲染；与视频源同架构。v0.15 实测摄像头已通（权限流程修复生效），但渲染+编码同线程导致掉帧 |
| 0.15.0 (15) | **摄像头闪退真凶修复**（诊断日志定位）：`startRunning` 落在 `beginConfiguration`/`commitConfiguration` 之间触发 NSGenericException——v0.14 用 `defer` 把 commit 拖到了函数末尾，改为显式先 commit 再 startRunning；**视频解码 v3**：解码线程改为跟随视频自身 PTS 时间戳节奏（原速播放），读出端要原生 420YpCbCr 跳过每帧 BGRA 软件转换；摄像头渲染也改 3 缓冲轮换（不再每帧分配）；UI 重做为卡片式（渐变底 + 白卡片 + 图标方块来源选择 + 大数字指标 + 底部固定渐变大按钮），找 IP 工具移入 sheet |
| 0.14.0 (14) | **视频不再卡**：解码移出发送线程（独立解码线程 + 3 缓冲轮换，发送端零等待）；**摄像头修复闪退**：先走 requestAccess 权限流程再配置 session，每步打诊断日志；**图片预览确认制**：选图后大图预览（按当前方向渲染出仪表实际画面）+「确认投这张图」；**视频确认制**；UI 重排：来源/方向改分段选择器，扫描工具/高级设置/诊断/协议要点全部折叠收纳，开始/停止改大按钮 |
| 0.13.0 (13) | **图片改铺满（aspect-fill）+ 方向可旋转 0/90/180/270**；新增**视频投屏**（相册选视频，AVAssetReader 循环解码、按投屏帧率取帧）与**摄像头投屏**（前后置，取最新帧；退后台系统会停采集，画面停在最后一帧但流不断）；后台保活增加音频中断/媒体服务重置自动恢复 |
| 0.12.0 (12) | 新增**相册图片投屏**：PhotosPicker 选图 → 等比缩放居中补黑 → 按帧率持续重发；可一键清除回到测试图。视频/摄像头投屏排后续版本 |
| 0.11.0 (11) | **里程碑：仪表开始回 pong（往返 11-15ms）**，确认 192.168.1.1 = 仪表、5013 通、官方心跳格式正确。新增后台保活：静音 AVAudioEngine + 禁止锁屏，退后台不再断流（UIBackgroundModes=audio 真正生效） |
| 0.10.0 (10) | **修真凶**：九号出行在后台会占住本机 UDP 5012/5013，导致我们的连接 failed、send 静默丢弃（帧数在涨但一个包都没发出去）。现在端口被占自动降级为临时端口重连，并在状态区提示「强退九号出行」；日志记录实际本地端口 |
| 0.9.0 (9) | 心跳改官方格式（RTCP APP 子类型 5、参数 [0,2]，同时保留计数变体）；RTP 分片 1400/1380 可切；关键帧间隔 gop 10；新增 848×480 25fps 800kbps（官方 HUD 参数）预设；界面提示改为「必须先进巡航接收态 + 把官方 App 切后台」 |
| 0.8.0 (8) | 端口不再只赌 8443：TCP 扫 8443/80/443/5000/8080/8000/9000 并显示每台开了哪些；RTCP 扫描加广播探测；新增「体检当前 IP」（端口+RTCP+pong 原文）；①网关 ②体检 ③扫段 三步引导 |
| 0.7.0 (7) | 扫描排除本机（热点下手机是 .3，自己 ping 自己被误判成仪表）；新增 TCP 8443 端口扫描找仪表；pong 只认 85 CC 00 04 头（实测仪表回包字段与 APK 假设不同）；新增「填入网关 .1」 |
| 0.6.0 (6) | 专属头像 App 图标；版本号大字放界面顶部（防装错旧包）；产物按版本命名 |
| 0.5.0 (5) | 防闪退加固：修 `CMBlockBuffer` 越界读、VT 回调 refcon 悬垂、后台线程碰 UIKit；串行队列自锁改为 specific-key 派发；新增文件诊断日志（闪退后下次启动可查）、网段扫描找仪表 IP、「只发 ping」隔离开关 |
| 0.4.0 (4) | 协议对齐 APK 逆向：20 字节扩展头 / PT 32 / 毫秒时间戳 / 1380 分片 / 每帧带 SPS/PPS |
| 0.3.0 | 首次可运行的骨架（标准 RTP 12 字节头） |

## 当前进度（骨架版）

- [x] VideoToolbox H.264 硬编码（Annex-B 输出，关键帧自动带 SPS/PPS）
- [x] 标准 RTP 打包（RFC 6184，Single NALU + FU-A 分片）
- [x] UDP 视频通道 5012 / 控制保活 5013（Network.framework）
- [x] KCP 通道（七寸预设，C 源码直编译）
- [x] 测试图源（色条 + 移动滑块 + 帧计数，验证仪表出画面）
- [ ] RTP 参数与仪表抓包核对（payload type / 时钟 / SSRC）
- [ ] 5013 心跳与控制包字节格式（当前为占位字节）
- [ ] 七寸 KCP conv / ACK 通路核对
- [ ] 相册、摄像头、ReplayKit 屏幕采集
- [ ] 4.3寸 JPEG 模式

## 投屏预设（来自原项目 README）

| 预设 | 分辨率 | 编码与传输 | 帧率 | 码率 |
|------|--------|-----------|------|------|
| 五寸（KZ110 已验证） | 848×480 | H.264 / RTP | 20 | 2000 kbps |
| 七寸（待实测） | 1024×600 | H.264 / RTP+KCP | 25 | 2000 kbps |
| 4.3寸（测试） | 480×272 | JPEG / RTP | 10 | — |

## 使用

1. Actions 构建出未签名 IPA（artifact：`NinebotCast-unsigned-ipa`），自签/免费签名安装。
2. 在仪表或官方 App 中开启投屏模式，iPhone 在 设置 > Wi-Fi **手动连接**仪表热点（iOS 没有 Wi-Fi Direct 公开 API，无法像 Android 那样自动组网）。
3. 打开 App，选预设、填仪表 IP，点"开始投屏（测试图）"。

## 已知 iOS 平台限制

- 无 Wi-Fi Direct API：只能手动连热点，连仪表 IP 发 UDP。
- 后台投屏：App 带 background audio 模式可部分保活；摄像头后台会被系统强制停止（同原版 iOS 行为）。
- 免费签名 7 天过期，需定期重签。

## 构建

本地无 Mac 时走 GitHub Actions（macos-14 + xcodegen + xcodebuild archive 不签名打包）。

本地构建：

```bash
xcodegen generate
xcodebuild archive -project NinebotCast.xcodeproj -scheme NinebotCast \
  -configuration Release -destination "generic/platform=iOS" \
  -archivePath build/NinebotCast.xcarchive CODE_SIGNING_ALLOWED=NO
```

## 协议

本项目代码 MIT。KCP 来自 [skywind3000/kcp](https://github.com/skywind3000/kcp)（其自带许可证）。与九号公司无官方关联。
