import SwiftUI
import UIKit
import AVFoundation
import PhotosUI

/// 以 NinebotPro 的组织方式重做主界面：
/// 仪表 → 画面源 → 参数 → 控制 → 状态 → 自检 → 日志。
///
/// 投屏引擎沿用已经验证过的那套（CastEngine / RTPPacker / H264Encoder），
/// 参数模型换成逆向出来的 StreamProfile，画面源保留了 CarWithin 的 CarPlay 直取。
struct NinebotProHomeView: View {

    @StateObject private var engine = CastEngine()
    @StateObject private var logStore = AppLogStore()

    // 仪表
    @AppStorage("nbp.host") private var host = "192.168.1.1"
    @AppStorage("nbp.preset") private var presetIndex = 0

    // 画面源
    @AppStorage("nbp.carwithin") private var carwithinHost = "127.0.0.1:9888"
    @State private var photoItem: PhotosPickerItem?
    @State private var videoItem: PhotosPickerItem?
    @State private var cameraPosition: AVCaptureDevice.Position = .back

    // CarWithin 探测
    @State private var probeResults: [CarWithinProbe.Result] = []
    @State private var probing = false

    // 参数
    @State private var profile = StreamProfile()
    @State private var validationMessage = ""

    // 控制
    @AppStorage("nbp.pingOnly") private var pingOnly = false
    @AppStorage("nbp.dupKey") private var duplicateKeyframes = false
    @AppStorage("nbp.chunk1400") private var chunk1400 = true
    @AppStorage("nbp.halfRes") private var halfResolution = false

    // 自检
    @State private var checks: [SelfCheck.Result] = []

    var body: some View {
        NavigationStack {
            Form {
                dashboardSection
                sourceSection
                parameterSection
                controlSection
                statusSection
                selfCheckSection
                logSection
                aboutSection
            }
            .navigationTitle("Ninebot Pro+")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Text(engine.isRunning ? "投屏中" : "待机")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(engine.isRunning ? .green : .secondary)
                }
            }
        }
        .task(id: photoItem) { await loadPhoto() }
        .task(id: videoItem) { await loadVideo() }
        .onAppear {
            // 把 Diag 的每一行都引到日志面板，否则 CarWithin 出问题等于黑盒
            Diag.sink = { [logStore] line in logStore.log(line) }
            logStore.log("启动 \(AppVersion.display)，本机 \(engine.localIPText)")
        }
        .task(id: engine.carwithinStatus) {
            if !engine.carwithinStatus.isEmpty {
                logStore.log("CarWithin 状态：\(engine.carwithinStatus)")
            }
        }
        .task(id: engine.statusText) {
            logStore.log("引擎：\(engine.statusText)")
        }
    }

    // MARK: - 仪表

    private var dashboardSection: some View {
        Section {
            TextField("仪表 IP", text: $host)
                .keyboardType(.decimalPad)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)

            Picker("预设", selection: $presetIndex) {
                ForEach(Array(DashboardPreset.all.enumerated()), id: \.offset) { idx, p in
                    Text(p.title).tag(idx)
                }
            }

            Button {
                host = profile.defaultDashboardIP
                logStore.log("按参数填仪表地址：\(host)")
            } label: {
                Label("按参数填地址（\(profile.defaultDashboardIP)）", systemImage: "arrow.down.to.line")
            }

        } header: {
            Text("仪表")
        } footer: {
            Text("五寸用 192.168.1.1（H.264），4.3 寸实验用 192.168.169.1（JPEG）。先连上仪表的 Wi-Fi。")
        }
    }

    // MARK: - 画面源

    private var sourceSection: some View {
        Section {
            TextField("CarWithin 地址，如 192.168.1.20:9889", text: $carwithinHost)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)

            Button {
                let addr = carwithinHost.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !addr.isEmpty else {
                    validationMessage = "CarWithin 地址为空"
                    return
                }
                engine.useCarWithin(host: addr, rotation: profile.rotation.rawValue)
                logStore.log("画面源 → CarWithin \(addr) rot=\(profile.rotation.rawValue)")
            } label: {
                Label("使用 CarPlay 画面", systemImage: "car.fill")
            }

            if !engine.carwithinStatus.isEmpty {
                Text(engine.carwithinStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Button {
                runProbe()
            } label: {
                if probing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在探测 127.0.0.1 与输入的地址…")
                    }
                } else {
                    Label("探测 CarWithin（找端口 / 验证能否连上）", systemImage: "antenna.radiowaves.left.and.right")
                }
            }
            .disabled(probing)

            if !probeResults.isEmpty {
                ForEach(probeResults) { r in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundColor(r.ok ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.target).font(.caption.monospaced()).bold()
                            Text(r.detail).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
            }

            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("相册图片", systemImage: "photo")
            }

            PhotosPicker(selection: $videoItem, matching: .videos) {
                Label("相册视频", systemImage: "film")
            }

            Picker("摄像头", selection: $cameraPosition) {
                Text("后置").tag(AVCaptureDevice.Position.back)
                Text("前置").tag(AVCaptureDevice.Position.front)
            }
            .pickerStyle(.segmented)

            Button {
                engine.useCamera(position: cameraPosition, rotation: profile.rotation.rawValue)
                logStore.log("画面源 → 摄像头 \(cameraPosition == .back ? "后置" : "前置")")
            } label: {
                Label("使用摄像头", systemImage: "camera")
            }

            Button {
                engine.useTestImage()
                logStore.log("画面源 → 测试图")
            } label: {
                Label("测试图（不接任何源也能验证链路）", systemImage: "square.grid.3x3")
            }
        } header: {
            Text("画面源")
        } footer: {
            Text("CarPlay 必须由 CarWithin 接收；iOS 不向第三方开放 CarPlay 视频出口，所以 CarWithin 要留在后台运行。")
        }
    }

    // MARK: - 参数

    private var parameterSection: some View {
        Section {
            HStack {
                Text("分辨率")
                Spacer()
                Text("\(profile.width)×\(profile.height)")
                    .font(.body.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Stepper("宽 \(profile.width)", value: $profile.width, in: 64...1920, step: 2)
            Stepper("高 \(profile.height)", value: $profile.height, in: 64...1920, step: 2)

            sliderRow(title: "帧率", value: "\(profile.fps) fps",
                      binding: Binding(
                        get: { Double(min(max(profile.fps, 5), 30)) },
                        set: { profile.fps = Int($0.rounded()) }
                      ), range: 5...30, step: 1)

            sliderRow(title: "码率", value: "\(profile.bitrateKbps) kbps",
                      binding: Binding(
                        get: { Double(min(max(profile.bitrateKbps, 250), 8000)) },
                        set: { profile.bitrateKbps = Int($0.rounded()) }
                      ), range: 250...8000, step: 50)

            sliderRow(title: "JPEG 质量", value: "\(profile.jpegQuality)",
                      binding: Binding(
                        get: { Double(min(max(profile.jpegQuality, 30), 95)) },
                        set: { profile.jpegQuality = Int($0.rounded()) }
                      ), range: 30...95, step: 1)

            Picker("旋转", selection: $profile.rotation) {
                ForEach(Rotation.allCases) { r in Text(r.title).tag(r) }
            }
            .pickerStyle(.segmented)

            Picker("缩放", selection: $profile.scaleMode) {
                ForEach(ScaleMode.allCases) { m in Text(m.title).tag(m) }
            }

            Picker("编码", selection: $profile.codec) {
                ForEach(StreamCodec.allCases) { c in Text(c.title).tag(c) }
            }
            .pickerStyle(.segmented)

            if !validationMessage.isEmpty {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        } header: {
            Text("参数")
        } footer: {
            Text("边界与原版一致：宽高 64–1920 偶数、总像素 ≤1920×1080、帧率 5–30、码率 250–8000 kbps、质量 30–95。")
        }
    }

    private func sliderRow(title: String, value: String,
                           binding: Binding<Double>,
                           range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value).font(.body.monospacedDigit()).foregroundColor(.secondary)
            }
            Slider(value: binding, in: range, step: step)
        }
    }

    // MARK: - 控制

    private var controlSection: some View {
        Section {
            Button {
                if engine.isRunning {
                    engine.stop()
                    logStore.log("停止投屏")
                } else {
                    startCasting()
                }
            } label: {
                Label(engine.isRunning ? "停止投屏" : (pingOnly ? "开始（仅 ping）" : "开始投屏"),
                      systemImage: engine.isRunning ? "stop.fill" : "play.fill")
                    .foregroundColor(engine.isRunning ? .red : .accentColor)
            }

            Toggle("仅 RTCP 探测（不编码不发画面）", isOn: $pingOnly)
            Toggle("重复关键帧", isOn: $duplicateKeyframes)
            Toggle("分片 1400（关掉用 1380）", isOn: $chunk1400)
            Toggle("分辨率减半（救卡顿）", isOn: $halfResolution)

            Text(engine.statusText)
                .font(.caption)
                .foregroundColor(.secondary)
        } header: {
            Text("投屏控制")
        }
    }

    // MARK: - 状态

    private var statusSection: some View {
        Section("状态") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                metric("\(engine.sentFrames)", "帧已发送")
                metric("\(engine.sentPackets)", "包已发送")
                metric("\(engine.measuredFps)", "实测 fps")
                metric("\(engine.avgFrameKB)", "帧均 KB")
                metric(engine.rtcpPongCount > 0 ? "\(max(0, engine.lastRTTMs))" : "—", "往返 ms")
                metric("\(engine.rtcpPongCount)", "心跳回应")
                metric("\(engine.backlogPackets)", "待发积压")
                metric("\(engine.droppedFrames)", "主动丢帧")
            }
            if !engine.dashboardReport.isEmpty {
                Text(engine.dashboardReport).font(.caption).foregroundColor(.secondary)
            }
            if engine.rtcpPongCount > 0 {
                Text("仪表在线，已回应 \(engine.rtcpPongCount) 次心跳")
                    .font(.caption).foregroundColor(.green)
            }
        }
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 自检

    private var selfCheckSection: some View {
        Section {
            Button {
                checks = SelfCheck.runAll()
                let failed = checks.filter { !$0.passed }.count
                logStore.log("自检完成：\(checks.count) 项，失败 \(failed) 项")
            } label: {
                Label("运行本地自检", systemImage: "checkmark.seal")
            }

            ForEach(checks) { r in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: r.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(r.passed ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.name).font(.subheadline)
                        Text(r.detail).font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
        } header: {
            Text("自检")
        } footer: {
            Text("不接仪表也能跑：校验参数边界、RTP 20 字节头/分片/标志位/时间戳、RTCP 包格式。")
        }
    }

    // MARK: - 日志

    private var logSection: some View {
        Section {
            ForEach(logStore.entries.suffix(12).reversed()) { e in
                Text(e.text)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
            }
            ShareLink(item: logStore.exportText) {
                Label("导出日志", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                logStore.clear()
            } label: {
                Label("清空日志", systemImage: "trash")
            }
        } header: {
            Text("日志（最近 12 条）")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("版本", value: AppVersion.display)
            LabeledContent("本机 IP", value: engine.localIPText)
            LabeledContent("参数", value: profile.summary)
        } header: {
            Text("关于")
        } footer: {
            Text("投屏协议与参数边界取自 NinebotPro 1.0.1 的静态逆向；CarPlay 由 CarWithin 接收后经 WebSocket 取流。")
        }
    }

    // MARK: - 动作

    /// 探测 CarWithin：找出它到底监听在哪个端口，并验证从本机能不能连上
    private func runProbe() {
        probing = true
        probeResults = []
        logStore.log("开始探测 CarWithin，输入「\(carwithinHost)」")
        Task {
            let results = await CarWithinProbe.run(rawHost: carwithinHost)
            await MainActor.run {
                probeResults = results
                probing = false
                let hits = results.filter { $0.ok }
                if hits.isEmpty {
                    logStore.log("探测：没有发现任何 HTTP 服务。确认 CarWithin 正在运行且停在接收页，再试。")
                } else {
                    for h in hits { logStore.log("探测命中 \(h.target) → \(h.detail)") }
                    if hits.count == 1 {
                        carwithinHost = hits[0].target
                        logStore.log("已自动填入 \(hits[0].target)")
                    }
                }
            }
        }
    }

    private func startCasting() {
        validationMessage = ""
        let validated: StreamProfile
        do {
            validated = try profile.validated()
        } catch {
            validationMessage = error.localizedDescription
            logStore.log("参数校验失败：\(validationMessage)")
            return
        }

        let idx = min(max(presetIndex, 0), DashboardPreset.all.count - 1)
        let base = DashboardPreset.all[idx]
        let preset = DashboardPreset(
            id: base.id,
            title: base.title,
            width: validated.width,
            height: validated.height,
            fps: Int32(validated.fps),
            bitrate: UInt32(validated.bitrateKbps * 1000),
            codec: base.codec,
            rtpPayloadType: base.rtpPayloadType,
            kcpConv: base.kcpConv)

        logStore.log("开始投屏 \(validated.summary) → \(host)")
        engine.start(preset: preset,
                     host: host,
                     duplicateKeyframes: duplicateKeyframes,
                     packetSize: chunk1400 ? 1400 : 1380,
                     gop: 10,
                     pingOnly: pingOnly,
                     fpsOverride: validated.fps,
                     bitrateOverride: UInt32(validated.bitrateKbps * 1000),
                     resolutionDivisor: halfResolution ? 2 : 1)
    }

    private func loadPhoto() async {
        guard let item = photoItem else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                validationMessage = "图片读取失败"
                return
            }
            engine.usePhoto(image, rotation: profile.rotation.rawValue)
            logStore.log("画面源 → 相册图片 \(Int(image.size.width))×\(Int(image.size.height))")
        } catch {
            validationMessage = "图片读取失败：\(error.localizedDescription)"
        }
    }

    private func loadVideo() async {
        guard let item = videoItem else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                validationMessage = "视频读取失败"
                return
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("picked-\(Int(Date().timeIntervalSince1970)).mov")
            try data.write(to: url)
            engine.useVideo(url: url, rotation: profile.rotation.rawValue)
            logStore.log("画面源 → 相册视频 \(data.count / 1024) KB")
        } catch {
            validationMessage = "视频读取失败：\(error.localizedDescription)"
        }
    }
}
