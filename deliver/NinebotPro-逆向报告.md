# xmz28/ninebot_pro — iOS 端逆向报告

目标：`xmz28/ninebot_pro` 的 iOS 构建（release 标签 `ios-v1.0.1`）。
样本：`ninebot-pro-ios-v1.0.1-unsigned.ipa`（2.78 MB）。
分析环境：Windows + 自写 Mach-O 解析器 + capstone 5.0.1，全程静态，未上真机。

---

## 0. 先说结论

1. **仓库 `xmz28/ninebot_pro-ios` 不存在**；`ninebot_pro` 的 release 里有 `ios-v1.0.0` / `ios-v1.0.1` 两个 iOS 包。仓库本体只有 README 和三张截图，**没有任何源码**。
2. **这个 App 没有 DRM，没有付费门槛，没有授权校验，没链 StoreKit。** 28 个动态库全是系统库，`_CodeSignature` 都不存在（本来就是未签名发布）。所以没有「注册机」「VIP 解锁」这类东西可破——它的价值在协议实现，不在授权。
3. **二进制未加密**：`LC_ENCRYPTION_INFO_64` 的 `cryptid = 0`，`__TEXT` 是明文，不需要 dumpdecrypted 一类手段。
4. 真正值得逆向的是它怎么把画面塞进九号仪表，以及它自己那套 **OXP** 接收协议。这两块下面全部还原。
5. 唯一存在的「限制」是纯粹的参数校验（分辨率/帧率/码率/质量），已经定位到指令级并做出了可用补丁，见第 7 节。

---

## 1. 样本与包结构

| 项 | 值 |
| --- | --- |
| Bundle ID | `com.hanlin.ninebotpro` |
| 版本 | 1.0.1（build 2） |
| CPU | arm64（thin，非 fat） |
| 最低系统 | **iOS 17.0**（`MinimumOSVersion`） |
| 后台模式 | `UIBackgroundModes: [audio]` |
| 本地网络 | `NSLocalNetworkUsageDescription` = 「通过已连接的仪表 Wi-Fi 发送导航投屏数据并接收**本机 OpenXPlay 视频流**」 |
| Mach-O UUID | `2e0af7c5838a3266a04a94c65c4f9cf0` |
| 加密 | `crypt: (cryptoff=0x4000, cryptsize=0xa0000, cryptid=0)` → **未加密** |
| 符号 | 18186 个，未 strip |
| 段 | `__PAGEZERO` / `__TEXT`(688128) / `__DATA_CONST` / `__DATA` / `__LINKEDIT`(1551424) |
| rpath | `/usr/lib/swift`, `@executable_path/Frameworks` |
| 第三方框架 | **无**（`Frameworks/` 目录整个不存在） |

链接的系统框架：Foundation、UIKit、SwiftUI、Combine、AVFoundation、AVFAudio、PhotosUI、`_PhotosUI_SwiftUI`、CoreTransferable、CoreMedia、VideoToolbox、CoreVideo、CoreImage、ImageIO、QuartzCore、CoreGraphics + 一批 `libswift*`。

关键点：`VideoToolbox` + `CoreMedia` 说明编解码是它自己做的；`SwiftUI` + `Combine` 说明整个 UI 是原生 SwiftUI，`MirrorViewModel` 是唯一的 `ObservableObject`。

---

## 2. 运行架构

16 个 Swift 类（从 `_TtC10NinebotPro*` 元数据引用还原）：

| 类 | 职责 |
| --- | --- |
| `NinebotCastApp` / `ContentView` | 入口与主界面（含 `SourceTile`、`ProfileEditorView`、`AboutView`、`UsageGuideView`、`LogCard`、`AppUpdateView`） |
| `MirrorViewModel` | 唯一视图模型，`@Published` 状态机（`_targetIP` `_openXPlayURL` `_profile` `_status` `_streamStatus` `_isMirroring` …） |
| `MirrorSession` | 一次投屏会话（`runH264`、`SessionSourceState`、`SessionCancellation`、`H264OutputState`） |
| `FrameCompositor` | 把任意源画面合成到目标画布（GPU `CIContext` / 后台退化 CPU 渲染） |
| `H264Encoder` / `H264Decoder` | VideoToolbox 编解码封装 |
| `H264StreamInspector` | 码流检查：`containsIDR`、`nalTypes`、首帧 SPS 上报 |
| `NinebotH264Packetizer` / `NinebotJPEGPacketizer` | 打 RTP 分片 |
| `RTPPacker`（在 `MirrorSession` 内）/ `ConnectedUDPSocket` | RTP 组包与 UDP 收发（`localPort`/`remotePort`/`descriptor`） |
| `VideoFrameSource` / `CameraFrameSource` / `StaticImageFrameSource` / `TestPatternFrameSource` | 四种画面源（相册视频、摄像头、相册图片、测试图） |
| **`OpenXPlayFrameSource`** | **OXP 客户端**：WSS 连接收端，取 H.264 当第五种画面源 |
| `BackgroundKeeper` | 后台保活（静音音频 + 与其他 App 混音） |
| `AppLogStore` / `AppUpdateModel` / `IOSUpdateService` | 日志、GitHub 发布检查 |

数据流：

```
相册图片 / 相册视频 / 摄像头 / 测试图 / OXP(CarPlay)
        └──────────────┬──────────────┘
                FrameCompositor（合成到 848x480 或自定画布）
                       │
                  H264Encoder（VideoToolbox Baseline）
                       │  AVCC（长度前缀）
              NinebotH264Packetizer
                       │  20 字节 RTP 头 + 1400 字节载荷
              ConnectedUDPSocket  →  仪表 192.168.x.1:5012
                       ↑
             RTCP 探测/回应  →  5013
```

`MirrorSession` 支持「热切换来源」：换源时保留 RTP 序列号与时间戳，只换画面，避免仪表重新握手（日志串：「热切换来源：…，保留 RTP 序列与时间戳」）。

---

## 3. 仪表侧协议（UDP）

从字符串与类名可以完整还原，和我此前在 Android 版上的分析一致：

| 项 | 值 | 证据 |
| --- | --- | --- |
| 视频 | UDP **5012** | `UDP 5012 + RTCP 5013` |
| 心跳/探测 | UDP **5013**（RTCP） | 同上，`RTCP 回应 %d 次`、`往返 %.0fms` |
| RTP 头 | **20 字节**（非标准 12 字节） | `NinebotH264Packetizer` |
| H.264 分片 | 每片 `20 + 1400` 字节 | `未知 H.264 封装` / `H.264 长度前缀不完整` |
| JPEG 分片（4.3 寸实验） | 每片 `20 + 1400` 字节 | 「使用抓包中的 Unix 毫秒低 32 位时间戳；每片 20 + 1400 字节」 |
| JPEG 时间戳 | Unix 毫秒的**低 32 位** | 同上 |
| 编码 | VideoToolbox **Baseline** | `VideoToolbox H.264 Baseline ·` |
| 关键帧 | 约每 0.5 s 请求一次，可选重复发送 | 「每约 0.5 秒请求关键帧；重复关键帧…默认关闭以避免关键帧形成 UDP 突发」 |
| 预设 | 五寸 `192.168.1.1`；4.3 寸（实验）`192.168.169.1` | UI 字符串 |

其它常量：
- 设置键：`ninebot.mirror.settings.v1`、`ninebot.mirror.keyframe-pacing.v1`
- 后台：`UIBackgroundModes [audio]`，`AVAudioSession` 静音音频保活
- 队列标签：`com.hanlin.ninebotpro.h264.sender`、`.mirror`、`.mirror.teardown`、`.camera`、`.openxplay.decoder`、`.openxplay.delegate`、`.video.teardown`
- iOS 更新：`https://api.github.com/repos/xmz28/ninebot_pro/releases?per_page=100&page=` + `ios-update.json`（字段 `bundleIdentifier` `minimumOSVersion` `releaseTag` `ipaName` `browser_download_url`）

---

## 4. OXP 协议（重点）

### 4.1 它确实是 OXP 客户端

`OpenXPlayFrameSource` 里的证据链：
- 方法名：`helloMessage`、`sendJSON`、`configureVideoFormat`、`containsIDR`、`requestKeyframe`、`startReceiveLoop`
- 私有辅助：`Array<UInt8>.readLE64(at:)`（就是读二进制头里两个小端 i64）
- 字面量：`display-settings`、`maxTouchContacts`
- 日志：「OXP WebSocket 已连接，正在请求 H.264 画面」「OXP H.264 格式就绪：」「OXP 首帧已解码，开始向仪表投屏」
- 反汇编 `helloMessage` 的 movz/movk 立即数，拼回来的键依次是 `version` `token` `decoders` `playback` `videoCodec` `displays` `safeArea` `viewport` `refreshHz` `frameRate` `screen` `avc1.42E…` `avc1.4D…` `hvc1.6.40…` `hardware` `maxTouchContacts` `audio` `PCM_S16LE` `AAC_LC` `mic`

这些和 OpenXPlay-Stream 仓库里的 TS 定义逐字对应。

### 4.2 地址

UI 要求填 `https://服务设备IP:端口/`（默认示例 `https://192.168.1.104:8443/`），内部转成 WebSocket（`NSURLSessionWebSocketTask` + `trustedHost` 接受自签证书）。非法时抛「CarPlay 服务地址无效」。

### 4.3 JSON 报文（v0）

**客户端 → 中继**

```jsonc
// hello：连上就发
{ "type":"hello", "version":0, "token":"…",
  "decoders":[{"codecString":"avc1.42E01F","hardware":true}],
  "playback":"SMART|QUALITY|SPEED", "videoCodec":"AUTO|H264",
  "displays":[{ "screen":0,"width":…,"height":…,"dpr":…,"refreshHz":…,
                "viewport":{"width":…,"height":…},"fullscreen":false,
                "frameRate":"AUTO|FPS_30|…|FPS_60","sustainedFps":…,
                "safeArea":{"top":0,"right":0,"bottom":0,"left":0} }],
  "maxTouchContacts":10, "audio":["AAC_LC"], "microphone":false }

// 输出偏好（NinebotPro 发的就是这条）
{ "type":"display-settings", "resolution":"auto|native|1080p|720p|screen",
  "screenWidth":125|200|250|300, "videoCodec":"auto|h265|h264",
  "frameRate":"…" }

{ "type":"ping", "t0Us":"1234567890" }          // 微秒，字符串形式的 i64
{ "type":"view-area", "x":…,"y":…,"width":…,"height":…,"canvasWidth":…,"canvasHeight":… }
{ "type":"fullscreen-exit", "hiddenMs":null, "display":{…} }
{ "type":"restart" }
{ "type":"stats", … }
{ "type":"receiver-close", "code":…,"reason":"…","wasClean":…,… }
```

**中继 → 客户端**

```jsonc
{ "type":"welcome", "version":0, "clientId":"…",
  "session":{"id":"42","phase":"CONNECTING|ACTIVE|RECONNECTING|ENDED"},
  "sourceUrl":"…", "attribution":"…", "projectUrl":"…",
  "receiverBuild":"…", "features":[…] }
{ "type":"session", "session":{"id":"42","phase":"ACTIVE"} }

// 视频格式：config 是 base64(avcC/hvcC)
{ "type":"video-format", "screen":0,
  "format":{ "codec":"H264|H265", "codecString":"avc1.42C01E",
             "config":"AULAHv/hAAlnQsAe9AUB7IABAARozjyA",
             "width":640,"height":480,"fpsHint":30 } }   // format 可为 null

{ "type":"audio-format", "stream":0, "format":{…}|null }
{ "type":"keyframe", "screen":0 }        // 让客户端要关键帧
{ "type":"pause", "screen":0, "paused":false }
{ "type":"pong", "t0Us":"…","t1Us":"…","t2Us":"…" }
{ "type":"error", "code":"…", "message":"…" }
```

### 4.4 二进制帧（24 字节头，小端）

```
偏移  长度  含义
0     1    kind：1=视频 2=音频 3=麦克风 16=触摸 17=按键
1     1    stream（u8）
2     1    flags：bit0 KEYFRAME=1，bit1 GAP=2
3     1    保留，必须 0
4     4    sequence（u32 LE）
8     8    ptsUs（i64 LE，微秒）
16    8    senderClockUs（i64 LE，微秒）
24    …    载荷（视频为 AVCC 长度前缀码流）
```

触摸载荷：`count(u8) + count×{id(u8), pressed(u8), x(u16), y(u16)}`，坐标归一化到 0..65535。
按键载荷：`code(u16) + down(u8)`。

### 4.5 为什么它的 CarPlay 和 CarWithin 不通

两边都是 WebSocket，但方言不同：

| | NinebotPro（OXP 客户端） | CarWithin `/stream` |
| --- | --- | --- |
| 首帧 | `hello` | 等 `ready` + `display` |
| 输出偏好 | `display-settings` | `display` |
| 收到格式 | `video-format`（`config` 是 base64 avcC） | `format`（MSE 下可能没有 `description`） |
| 二进制帧 | **24 字节头**，kind=1 视频，flags.bit0 关键帧 | `timed = tag==4\|\|5`，头 9 或 1 字节 |
| 音视频分流 | kind 字段 | `tag==3` |

CarWithin 一个 `oxp` 字符串都没有，它的 upgrade handler 也不看请求路径——所以 NinebotPro 连得上、却永远等不到 `video-format`，界面就卡在「正在请求 H.264 画面」。这与我此前从 CarWithin 二进制里还原出的页面逻辑完全吻合。

---

## 5. 参数限制（唯一的「可破」之处）

`NinebotPro.StreamProfile.validated() -> StreamProfile`
符号 `_$s10NinebotPro13StreamProfileV9validatedACyKF`，地址 **`0x10001e740`**，共 320 字节。

`StreamProfile` 内存布局（末尾整体拷贝 0x38 = 56 字节可证）：

| 偏移 | 字段 | 判据 |
| --- | --- | --- |
| 0x00 | width | `64 ≤ w ≤ 1920` |
| 0x08 | height | `64 ≤ h ≤ 1920`，且 `(w or h) & 1 == 0`，且 `w*h ≤ 1920*1080 = 2073600` |
| 0x10 | fps | `5 ≤ fps ≤ 30` |
| 0x18 | bitrate | `250000 ≤ bps ≤ 8000000`（即 250–8000 kbps，内部存 bps） |
| 0x20 | rotation | 必须 ∈ `{0, 90, 180, 270}`（常量表 `0x1000b3368` = 0 / 0x5a / 0xb4 / 0x10e，SIMD 四路比较） |
| 0x28 | scaleMode | 不校验（fit / crop / stretch） |
| 0x30 | jpegQuality | `30 ≤ q ≤ 95` |

任意一项不过就抛错，UI 表现为「投屏配置无效，请重新保存配置」。

校验的汇编骨架（节选，`cmn` 是 Swift 生成范围检查的惯用法）：

```
; width
sub  x12, x11, #0x781          ; w - 1921
cmn  x12, #0x741               ; 等效判 w 是否 >= 64
b.lo 0x10001e7a4               ; 不满足 → 报错
; height + 偶数 + 像素总数
and  x14, x14, #1              ; (w|h) 的奇偶
mul  x11, x12, x11             ; w*h
mov  w12, #0xa400 ; movk w12, #0x1f, lsl #16   ; 0x1fa400 = 2073600
ccmp x11, x12, #0, eq
b.le 0x10001e7ec               ; 通过 → 下一组
; fps
sub  x10, x9, #0x1f ; cmn x10, #0x1a           ; 5..30
b.lo 0x10001e7a8
; bitrate
sub  x10, x10, #0x7a1, lsl #12 ; sub x10, x10, #0x201   ; -8000001
cmp  x10, #-0x764171                                    ; 下界 250000
b.lo 0x10001e7a8
; rotation（SIMD 四路等值）
cmeq v2.2d, v2.2d, v0.2d … umaxv h0, v0.4h
tbz  w10, #0, 0x10001e7a8
; jpegQuality
sub  x10, x10, #0x60 ; cmn x10, #0x42           ; 30..95
b.lo 0x10001e7a8
```

---

## 6. 补丁

已生成补丁与补好的包（见交付物）。改动只在 `validated()` 里 6 条「不满足就报错」的分支：

| VA | 文件偏移 | 原始 | 替换 | 含义 |
| --- | --- | --- | --- | --- |
| `0x10001e774` | 124788 | `54000183` | `d503201f` (nop) | 跳过 width 越界报错 |
| `0x10001e7a0` | 124832 | `5400026d` | `14000013` (b) | 无条件进入下一组校验 |
| `0x10001e804` | 124932 | `54fffd23` | `d503201f` | 跳过 fps 越界报错 |
| `0x10001e820` | 124960 | `54fffc43` | `d503201f` | 跳过 bitrate 越界报错 |
| `0x10001e850` | 125008 | `3607faca` | `d503201f` | 跳过 rotation 白名单 |
| `0x10001e860` | 125024 | `54fffa43` | `d503201f` | 跳过 jpegQuality 越界报错 |

注意第 2 条不是 nop：那里 `b.le` 的目标是**成功**路径，nop 掉会掉进报错分支，所以改成无条件跳 `0x10001e7ec`。

补完用 capstone 重新反汇编确认过：那 6 处已分别变成 `nop` / `b #0x10001e7ec`，其余指令未动，文件长度不变（2305088 字节）。

**诚实说明**：这只解开了「校验闸门」。设置界面里的 `Stepper`/`Slider` 自身还有取值范围，所以界面上仍调不出越界数字；能受益的是已经存在 UserDefaults 里的旧配置、以及后续若要改 UI 时不再被这一层挡住。要连 UI 一起放开需要再定位 `ProfileEditorView` 里的控件范围，那是另一处补丁。

---

## 7. 可复现步骤

```powershell
# 1) 结构 / 段 / 字符串 / 类型
python re/ios_re.py sections  <NinebotPro>
python re/ios_re.py strings   <NinebotPro> 3
python re/ios_re.py reflstr   <NinebotPro>

# 2) 找函数并反汇编
python re/disasm.py <NinebotPro> --find helloMessage
python re/disasm.py <NinebotPro> --find StreamProfileV9validated --asm

# 3) 打补丁 + 重新打包
python re/patch_ninebot.py <NinebotPro> re/patched/NinebotPro
```

工具依赖：Python 3.7 + `capstone`（`pip install capstone`），其余只用标准库。

---

## 8. 没有做的事

- **没在真机跑过**。补丁的正确性只到「反汇编层面确认分支已被移除」，没有实机验证「越界配置能否真的投出去」。
- **没还原 UI 控件的取值范围**，所以不知道补丁后界面能否直接输入越界值。
- **没做动态分析**（无越狱设备、无 frida 环境），所有结论来自静态。
- **没实现 OXP 服务端**。协议规格已完整给出，按第 4 节可以自己写；OpenXPlay-Stream 仓库里有 `spec/vectors/web/*.json` 共 60 多个规格向量可用来校验自己的实现。
