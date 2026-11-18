import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// CarWithin 直播源：把 CarPlay 画面直接接进投屏管线。
///
/// 为什么需要这个文件
/// ------------------
/// CarWithin 的 `/stream` WebSocket 只在收到接收端的
///   {"type":"ready","decoder":"mse","viewer":"<uuid>","audioClock":false}
///   {"type":"display","w":848,"h":480,...}
/// 之后才开始推流；之后服务器先发
///   {"type":"hello","page":N,...}
///   {"type":"format","codec":"avc1.…","description":"<base64 avcC>","width":…,"height":…}
/// 再推二进制帧，帧格式为：
///   [0]     tag：3=音频，4/5=带 8 字节时间戳的视频，其它=裸视频
///   [1..8]  时间戳（我们不用，PTS 自己按帧序生成，避免端序踩坑）
///   [9..]   AVCC 长度前缀的 NAL 单元（lengthSize 见 avcC[hvcC] 第 5 字节）
///
/// 仪表只吃 H.264，所以上报 display 时 h265 固定 false；万一 CarWithin 仍然
/// 发 HEVC（hvc1），这里也做了一条 HEVC 解码分支，不至于直接黑屏。
final class CarWithinSource: NSObject {

    // MARK: - 配置

    private let hostPort: String
    private let targetWidth: Int
    private let targetHeight: Int
    private let rotation: Int
    private let reportHz: Int
    private let onStatus: (String) -> Void

    // MARK: - 运行状态

    private let lock = NSLock()
    private var latestBuffer: CVPixelBuffer?
    private var destBuffers: [CVPixelBuffer] = []
    private var destIndex = 0
    private var _running = false

    private var urlSession: URLSession?
    private var task: URLSessionWebSocketTask?
    private var pingTimer: DispatchSourceTimer?
    private var retryItem: DispatchWorkItem?
    private var connectionState = "未连接"

    private let decodeQueue = DispatchQueue(label: "ninebotcast.carwithin.decode")
    private let ciContext = CIContext(options: nil)

    // MARK: - 解码状态

    private var decoder: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var nalLengthSize = 4
    private var isHEVC = false
    private var awaitingKeyframe = true
    /// MSE 模式下 CarWithin 的 format 不带 description，只能从关键帧里的 SPS/PPS 现取
    private var awaitingInBandSets = false
    private var lastPTS: CMTime = .invalid
    private var lastKeyframeRequest: Double = 0
    private var lastDecodeErrorLog: Double = 0
    private var suppressedDecodeErrors = 0
    private var framesIn = 0
    private var framesOut = 0
    private var audioPackets = 0
    private var reportedSize = CGSize.zero
    private var sentDisplay = false
    /// 只为诊断：记录前若干帧的原始头部，用来区分「没收到数据」和「收到了但解不出来」
    private var binaryLogCount = 0

    // MARK: - 初始化

    init(hostPort: String,
         targetWidth: Int,
         targetHeight: Int,
         rotation: Int,
         hz: Int,
         onStatus: @escaping (String) -> Void) {
        self.hostPort = hostPort.trimmingCharacters(in: .whitespacesAndNewlines)
        self.targetWidth = max(16, targetWidth)
        self.targetHeight = max(16, targetHeight)
        self.rotation = rotation
        self.reportHz = max(1, hz)
        self.onStatus = onStatus
        super.init()
    }

    // MARK: - 对外接口

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _running
    }

    /// 发送线程调用：拿最新解好的帧（没新帧时重复取同一张，画面依然连续）
    func latestFrame() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return latestBuffer
    }

    func start() {
        lock.lock()
        if _running {
            lock.unlock()
            return
        }
        _running = true
        lock.unlock()
        connect()
    }

    func stop() {
        lock.lock()
        _running = false
        let t = task
        let s = urlSession
        lock.unlock()
        retryItem?.cancel()
        retryItem = nil
        pingTimer?.cancel()
        pingTimer = nil
        t?.cancel(with: .goingAway, reason: nil)
        s?.invalidateAndCancel()
        task = nil
        urlSession = nil
        decodeQueue.sync {
            teardownDecoder()
            framesIn = 0
            framesOut = 0
            audioPackets = 0
        }
        lock.lock()
        latestBuffer = nil
        destBuffers.removeAll()
        destIndex = 0
        lock.unlock()
        status("已停止")
    }

    // MARK: - 连接

    private func makeURL() -> URL? {
        var text = hostPort
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("https://") { text = "wss://" + text.dropFirst("https://".count) }
        else if text.hasPrefix("http://") { text = "ws://" + text.dropFirst("http://".count) }
        else if !text.contains("://") { text = "ws://" + text }
        if let url = URL(string: text), url.path.isEmpty || url.path == "/" {
            return URL(string: text + "/stream") ?? url
        }
        return URL(string: text)
    }

    private func connect() {
        guard isRunning else { return }
        guard let url = makeURL() else {
            status("CarWithin 地址无效")
            return
        }
        status("连接 \(url.absoluteString) …")
        Diag.log("CarWithin：连接 \(url.absoluteString)")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        // 浏览器连 /stream 一定带 Origin 和 UA；URLSession 默认两个都不发。
        // CarWithin 的 handleHTTPRequest 里有 rejected 分支，缺头有可能被直接拒掉。
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let originHost = url.host ?? "localhost"
        let originPort = url.port.map { ":\($0)" } ?? ""
        request.setValue("http://\(originHost)\(originPort)", forHTTPHeaderField: "Origin")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) "
                         + "AppleWebKit/605.1.15 (KHTML, like Gecko) NinebotProPlus/1.0.2",
                         forHTTPHeaderField: "User-Agent")
        let ws = session.webSocketTask(with: request)
        ws.maximumMessageSize = 8 * 1024 * 1024
        Diag.log("CarWithin：握手头 Origin=http://\(originHost)\(originPort)")
        lock.lock()
        urlSession = session
        task = ws
        lock.unlock()
        ws.resume()
        receiveNext()
    }

    private func receiveNext() {
        lock.lock()
        let ws = task
        let running = _running
        lock.unlock()
        guard running, let ws else { return }
        ws.receive { [weak self] result in
            guard let self else { return }
            guard self.isRunning else { return }
            switch result {
            case .failure(let error):
                self.handleDisconnect("读取失败：\(error.localizedDescription)")
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleText(text)
                case .data(let data):
                    self.handleBinary(data)
                @unknown default:
                    break
                }
                self.receiveNext()
            }
        }
    }

    private func handleDisconnect(_ reason: String) {
        pingTimer?.cancel()
        pingTimer = nil
        decodeQueue.async { [weak self] in
            guard let self else { return }
            self.teardownDecoder()
        }
        status("断开：\(reason)（3 秒后重连）")
        Diag.log("CarWithin：断开 \(reason)")
        guard isRunning else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.connect()
        }
        retryItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
    }

    // MARK: - 发送

    private func send(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        let ws = task
        lock.unlock()
        guard let ws else { return }
        ws.send(.string(text)) { [weak self] error in
            if let error {
                Diag.log("CarWithin：发送失败 \(error.localizedDescription)")
                self?.handleDisconnect("发送失败")
            }
        }
    }

    /// CarWithin 必须收到 ready 才进推流状态 —— 这就是 ninebot_pro 卡住的原因
    private func sendReady() {
        send([
            "type": "ready",
            "decoder": "mse",
            "viewer": UUID().uuidString.lowercased(),
            "audioClock": false
        ])
        Diag.log("CarWithin：已发送 ready（decoder=mse）")
        status("已握手，请求 H.264 画面…")
    }

    /// 上报接收端尺寸：CarWithin 按这个尺寸编码，对准仪表原生分辨率最省带宽
    private func sendDisplay() {
        guard !sentDisplay else { return }
        sentDisplay = true
        send([
            "type": "display",
            "w": targetWidth,
            "h": targetHeight,
            "dpr": 1,
            "sw": targetWidth,
            "sh": targetHeight,
            "hz": reportHz,
            "h265": false,
            "fullscreen": false,
            "ua": "NinebotCast/1.0 (iPhone; iOS) CarWithinClient"
        ])
        Diag.log("CarWithin：已上报显示 \(targetWidth)x\(targetHeight) h265=false")
    }

    private func startPing() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRunning else { return }
            self.send(["type": "ping", "t0": Int(Date().timeIntervalSince1970 * 1_000_000)])
        }
        timer.resume()
        pingTimer = timer
    }

    /// 每帧强制 IDR 大约是普通帧的 10 倍，最多一秒一次
    private func requestKeyframe(_ reason: String) {
        let now = Date().timeIntervalSince1970
        guard now - lastKeyframeRequest >= 1.0 else { return }
        lastKeyframeRequest = now
        send(["type": "keyframe", "reason": reason])
        Diag.log("CarWithin：请求关键帧（\(reason)）")
    }

    // MARK: - 文本消息

    private func handleText(_ text: String) {
        if !text.contains("\"pong\"") {
            Diag.log("CarWithin ← \(text.prefix(320))")
        }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = object["type"] as? String else {
            return
        }
        switch kind {
        case "hello":
            let page = object["page"] ?? "-"
            let perf = object["perf"] ?? "-"
            Diag.log("CarWithin：hello page=\(page) perf=\(perf)")
            if sentDisplay { resendDisplay() }
        case "format":
            configureFormat(object)
        case "status":
            if let t = object["text"] as? String { Diag.log("CarWithin：status \(t)") }
        case "pong":
            break
        case "error":
            let t = (object["text"] as? String) ?? "未知错误"
            status("CarWithin 报错：\(t)")
            Diag.log("CarWithin：error \(t)")
        default:
            Diag.log("CarWithin：未处理文本 \(kind)")
        }
    }

    /// hello 之后重发一次 display：CarWithin 在 hello 里带 page 版本，重报尺寸让它重新选编码
    private func resendDisplay() {
        send([
            "type": "display",
            "w": targetWidth,
            "h": targetHeight,
            "dpr": 1,
            "sw": targetWidth,
            "sh": targetHeight,
            "hz": reportHz,
            "h265": false,
            "fullscreen": false,
            "ua": "NinebotCast/1.0 (iPhone; iOS) CarWithinClient"
        ])
    }

    private func configureFormat(_ object: [String: Any]) {
        let codec = (object["codec"] as? String) ?? ""
        let w = (object["width"] as? Int) ?? Int((object["width"] as? Double) ?? 0)
        let h = (object["height"] as? Int) ?? Int((object["height"] as? Double) ?? 0)
        reportedSize = CGSize(width: w, height: h)
        let hevc = codec.lowercased().hasPrefix("hvc1") || codec.lowercased().hasPrefix("hev1")

        // CarWithin 的 format 里 description 只有 WebCodecs 才用得上（页面里 formatMSE 完全不读它），
        // 所以走 mse 时它可能根本不发。这种时候改成从关键帧的码流里现取 SPS/PPS。
        if let description = object["description"] as? String,
           !description.isEmpty,
           let record = Data(base64Encoded: description),
           record.count >= 7 {
            Diag.log("CarWithin：format codec=\(codec) \(w)x\(h) record=\(record.count)B hevc=\(hevc)")
            awaitingInBandSets = false
            decodeQueue.async { [weak self] in
                guard let self else { return }
                self.installDecoder(record: record, hevc: hevc)
            }
        } else {
            Diag.log("CarWithin：format 无 description（MSE 模式）codec=\(codec) \(w)x\(h)，改取带内参数集")
            awaitingInBandSets = true
            decodeQueue.async { [weak self] in
                guard let self else { return }
                self.teardownDecoder()
                self.isHEVC = hevc
                self.nalLengthSize = 0
                self.lastPTS = .invalid
                self.requestKeyframe("缺少 avcC，等带 SPS/PPS 的关键帧")
            }
            status("CarWithin 未带解码参数，改从关键帧取 SPS/PPS")
        }
    }

    // MARK: - 二进制帧

    /// 分帧规则抄自 CarWithin 页面里的 onBinaryMSE()：
    ///   const timed = u[0]===4||u[0]===5;
    ///   const kind  = timed ? u[0]-4 : u[0];
    ///   body = u.subarray(timed ? 9 : 1)
    /// 时间戳是 offset 1 起的大端 64 位，单位微秒（packetTimestamp 里 getUint32(0)*2^32+getUint32(4)）。
    private func handleBinary(_ data: Data) {
        guard data.count >= 2 else { return }
        let base = data.startIndex
        let tag = Int(data[base])
        if tag == 3 {
            audioPackets += 1
            return
        }
        let timed = (tag == 4 || tag == 5)
        let kind = timed ? (tag - 4) : tag
        let offset = timed ? 9 : 1
        guard data.count > offset else { return }

        if binaryLogCount < 6 {
            binaryLogCount += 1
            let head = data.prefix(20).map { String(format: "%02x", $0) }.joined(separator: " ")
            Diag.log("CarWithin ← 帧 tag=\(tag) kind=\(kind) len=\(data.count) head=\(head)")
        }

        var stamp: UInt64?
        if timed, data.count >= 9 {
            var value: UInt64 = 0
            for i in 0..<8 {
                value = (value << 8) | UInt64(data[base + 1 + i])
            }
            // 0 表示没有时间戳；超过 Int64 的也不可信
            if value > 0 && value < UInt64(Int64.max) {
                stamp = value
            }
        }

        let body = data.subdata(in: (base + offset)..<data.endIndex)
        guard !body.isEmpty else { return }
        framesIn += 1
        let keyframe = (kind == 1)
        decodeQueue.async { [weak self] in
            self?.decode(body, timestamp: stamp, keyframe: keyframe)
        }
    }

    // MARK: - 解码器

    private func teardownDecoder() {
        if let decoder {
            VTDecompressionSessionWaitForAsynchronousFrames(decoder)
            VTDecompressionSessionInvalidate(decoder)
        }
        decoder = nil
        formatDescription = nil
        awaitingKeyframe = true
    }

    private func installDecoder(record: Data, hevc: Bool) {
        teardownDecoder()
        isHEVC = hevc
        var made: CMVideoFormatDescription?
        if hevc {
            made = Self.makeHEVCFormatDescription(record, &nalLengthSize)
        } else {
            made = Self.makeH264FormatDescription(record, &nalLengthSize)
        }
        guard let fd = made else {
            status("解码参数解析失败（\(hevc ? "hvcC" : "avcC")）")
            Diag.log("CarWithin：\(hevc ? "hvcC" : "avcC") 解析失败 \(record.count)B")
            return
        }
        formatDescription = fd
        let dims = CMVideoFormatDescriptionGetDimensions(fd)
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        var session: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: fd,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session)
        guard sessionStatus == noErr, let session else {
            status("VTDecompressionSession 创建失败 \(sessionStatus)")
            Diag.log("CarWithin：VTDecompressionSession 创建失败 \(sessionStatus)")
            return
        }
        decoder = session
        awaitingKeyframe = true
        suppressedDecodeErrors = 0
        requestKeyframe("format 就绪，等首个关键帧")
        status("已连接 \(Int(dims.width))x\(Int(dims.height)) \(hevc ? "H.265" : "H.264")，等关键帧…")
        Diag.log("CarWithin：解码器就绪 \(dims.width)x\(dims.height) nalLen=\(nalLengthSize) \(hevc ? "HEVC" : "AVC")")
    }

    /// AVCDecoderConfigurationRecord → CMFormatDescription
    private static func makeH264FormatDescription(_ record: Data, _ nalLength: inout Int) -> CMVideoFormatDescription? {
        let bytes = [UInt8](record)
        guard bytes.count >= 7, bytes[0] == 1 else { return nil }
        nalLength = Int(bytes[4] & 0x03) + 1
        var index = 5
        let spsCount = Int(bytes[index] & 0x1F)
        index += 1
        var sets: [Data] = []
        for _ in 0..<spsCount {
            guard index + 1 < bytes.count else { return nil }
            let length = (Int(bytes[index]) << 8) | Int(bytes[index + 1])
            index += 2
            guard length > 0, index + length <= bytes.count else { return nil }
            sets.append(Data(bytes[index..<(index + length)]))
            index += length
        }
        guard index < bytes.count else { return nil }
        let ppsCount = Int(bytes[index])
        index += 1
        for _ in 0..<ppsCount {
            guard index + 1 < bytes.count else { return nil }
            let length = (Int(bytes[index]) << 8) | Int(bytes[index + 1])
            index += 2
            guard length > 0, index + length <= bytes.count else { return nil }
            sets.append(Data(bytes[index..<(index + length)]))
            index += length
        }
        guard sets.count >= 2 else { return nil }
        return Self.makeDescription(parameterSets: sets, nalLength: nalLength, hevc: false)
    }

    /// HEVCDecoderConfigurationRecord → CMFormatDescription
    private static func makeHEVCFormatDescription(_ record: Data, _ nalLength: inout Int) -> CMVideoFormatDescription? {
        let bytes = [UInt8](record)
        guard bytes.count >= 23, bytes[0] == 1 else { return nil }
        nalLength = Int(bytes[21] & 0x03) + 1
        let numArrays = Int(bytes[22])
        var index = 23
        var sets: [Data] = []
        for _ in 0..<numArrays {
            guard index + 2 < bytes.count else { return nil }
            index += 1                             // array_completeness + NAL_unit_type
            let count = (Int(bytes[index]) << 8) | Int(bytes[index + 1])
            index += 2
            for _ in 0..<count {
                guard index + 1 < bytes.count else { return nil }
                let length = (Int(bytes[index]) << 8) | Int(bytes[index + 1])
                index += 2
                guard length > 0, index + length <= bytes.count else { return nil }
                sets.append(Data(bytes[index..<(index + length)]))
                index += length
            }
        }
        guard sets.count >= 2 else { return nil }
        return Self.makeDescription(parameterSets: sets, nalLength: nalLength, hevc: true)
    }

    private static func makeDescription(parameterSets: [Data], nalLength: Int, hevc: Bool) -> CMVideoFormatDescription? {
        var allocated: [UnsafeMutablePointer<UInt8>] = []
        defer { allocated.forEach { $0.deallocate() } }
        for set in parameterSets {
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: pointer, count: set.count)
            allocated.append(pointer)
        }
        let pointers = allocated.map { UnsafePointer<UInt8>($0) }
        let sizes = parameterSets.map { $0.count }
        var description: CMVideoFormatDescription?
        let status: OSStatus
        if hevc {
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: Int32(nalLength),
                extensions: nil,
                formatDescriptionOut: &description)
        } else {
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: Int32(nalLength),
                formatDescriptionOut: &description)
        }
        guard status == noErr else { return nil }
        return description
    }

    private func decode(_ avcc: Data, timestamp: UInt64?, keyframe: Bool) {
        // MSE 模式下 CarWithin 不给 avcC，只能拿关键帧里的 SPS/PPS 现场建 decoder
        if formatDescription == nil {
            guard awaitingInBandSets, keyframe else { return }
            installDecoderFromInBand(avcc)
            guard formatDescription != nil else {
                requestKeyframe("关键帧里没有参数集")
                return
            }
        }
        guard let decoder, let fd = formatDescription else { return }
        if awaitingKeyframe && !keyframe { return }
        if keyframe { awaitingKeyframe = false }

        var blockBuffer: CMBlockBuffer?
        let length = avcc.count
        let created = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard created == kCMBlockBufferNoErr, let bb = blockBuffer else { return }
        let replaced = avcc.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: bb,
                offsetIntoDestination: 0, dataLength: length)
        }
        guard replaced == noErr else { return }

        // CarWithin 的时间戳是微秒，能用就用它，回到源时钟比按帧数硬凑更稳
        let frameDuration = CMTime(value: 1000, timescale: Int32(max(1, reportHz)) * 1000)
        var pts: CMTime
        if let timestamp {
            pts = CMTime(value: Int64(timestamp), timescale: 1_000_000)
        } else {
            pts = CMTime(value: Int64(framesIn) * 1000, timescale: Int32(max(1, reportHz)) * 1000)
        }
        // 解码器要求 PTS 严格递增
        if lastPTS.isValid && CMTimeCompare(pts, lastPTS) <= 0 {
            pts = CMTimeAdd(lastPTS, frameDuration)
        }
        lastPTS = pts

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleSize = length
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            formatDescription: fd,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)
        guard sampleStatus == noErr, let sample = sampleBuffer else { return }

        var infoFlags = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            decoder,
            sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: &infoFlags
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard let self else { return }
            if status != noErr {
                self.noteDecodeError(status)
                return
            }
            guard let imageBuffer else { return }
            self.render(imageBuffer)
        }
        if decodeStatus != noErr { noteDecodeError(decodeStatus) }
    }

    // MARK: - 带内参数集（MSE 模式）

    /// 从关键帧的 AVCC 码流里抠出 SPS/PPS，现场建 CMFormatDescription + 解码会话。
    private func installDecoderFromInBand(_ avcc: Data) {
        let length = nalLengthSize > 0 ? nalLengthSize : (Self.sniffNalLength(avcc) ?? 4)
        guard let sets = Self.parameterSets(in: avcc, lengthSize: length, hevc: isHEVC) else {
            Diag.log("CarWithin：关键帧里没有参数集 nalLen=\(length) 码流=\(avcc.count)B")
            return
        }
        guard let fd = Self.makeDescription(parameterSets: sets, nalLength: length, hevc: isHEVC) else {
            Diag.log("CarWithin：用带内参数集建 formatDescription 失败 hevc=\(isHEVC)")
            return
        }
        nalLengthSize = length
        formatDescription = fd
        let dims = CMVideoFormatDescriptionGetDimensions(fd)
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        var session: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: fd,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session)
        guard sessionStatus == noErr, let session else {
            status("带内参数集建解码器失败 \(sessionStatus)")
            Diag.log("CarWithin：带内参数集 VTDecompressionSession 创建失败 \(sessionStatus)")
            return
        }
        decoder = session
        awaitingKeyframe = false
        awaitingInBandSets = false
        suppressedDecodeErrors = 0
        lastPTS = .invalid
        status("已连接 \(Int(dims.width))x\(Int(dims.height)) \(isHEVC ? "H.265" : "H.264")（带内参数集）")
        Diag.log("CarWithin：带内参数集建解码器成功 \(dims.width)x\(dims.height) nalLen=\(length) 参数集=\(sets.count)")
    }

    /// 猜 AVCC 用几字节长度前缀：只有把整段码流严格切完的那个值才算数。
    private static func sniffNalLength(_ avcc: Data) -> Int? {
        let bytes = [UInt8](avcc)
        for size in [4, 2, 1, 3] {
            var index = 0
            var count = 0
            var ok = true
            while index + size <= bytes.count {
                var length = 0
                for i in 0..<size { length = (length << 8) | Int(bytes[index + i]) }
                index += size
                if length <= 0 || index + length > bytes.count { ok = false; break }
                index += length
                count += 1
            }
            if ok && count > 0 && index == bytes.count { return size }
        }
        return nil
    }

    /// 从 AVCC 码流里挑出参数集。H.264：7=SPS / 8=PPS；HEVC：(b>>1)&0x3F，32=VPS / 33=SPS / 34=PPS。
    private static func parameterSets(in avcc: Data, lengthSize: Int, hevc: Bool) -> [Data]? {
        guard lengthSize >= 1, lengthSize <= 4 else { return nil }
        let bytes = [UInt8](avcc)
        var index = 0
        var vps: Data?
        var sps: Data?
        var pps: Data?
        while index + lengthSize <= bytes.count {
            var length = 0
            for i in 0..<lengthSize { length = (length << 8) | Int(bytes[index + i]) }
            index += lengthSize
            guard length > 0, index + length <= bytes.count else { return nil }
            let head = Int(bytes[index])
            let nal = Data(bytes[index..<(index + length)])
            index += length
            if hevc {
                switch (head >> 1) & 0x3F {
                case 32: if vps == nil { vps = nal }
                case 33: if sps == nil { sps = nal }
                case 34: if pps == nil { pps = nal }
                default: break
                }
            } else {
                switch head & 0x1F {
                case 7: if sps == nil { sps = nal }
                case 8: if pps == nil { pps = nal }
                default: break
                }
            }
        }
        guard let spsSet = sps, let ppsSet = pps else { return nil }
        if hevc, let vpsSet = vps {
            return [vpsSet, spsSet, ppsSet]
        }
        return [spsSet, ppsSet]
    }

    private func noteDecodeError(_ status: OSStatus) {
        let now = Date().timeIntervalSince1970
        suppressedDecodeErrors += 1
        if now - lastDecodeErrorLog > 3 {
            lastDecodeErrorLog = now
            Diag.log("CarWithin：解码错误 \(status)（累计 \(suppressedDecodeErrors) 次）")
        }
        awaitingKeyframe = true
        requestKeyframe("解码失败 \(status)")
    }

    // MARK: - 渲染（旋转 + 铺满）

    private func render(_ imageBuffer: CVImageBuffer) {
        lock.lock()
        if destBuffers.count < 3 {
            if let fresh = FrameRenderer.makeBuffer(width: targetWidth, height: targetHeight) {
                destBuffers.append(fresh)
            }
        }
        guard !destBuffers.isEmpty else {
            lock.unlock()
            return
        }
        destIndex = (destIndex + 1) % destBuffers.count
        let dest = destBuffers[destIndex]
        lock.unlock()

        // CVImageBuffer 就是 CVBuffer，和 CVPixelBuffer 同一个类型别名，
        // 直接用 cvImageBuffer 初始化 CIImage，省掉一次强转
        var image = CIImage(cvImageBuffer: imageBuffer)
        switch rotation {
        case 90: image = image.oriented(.right)
        case 180: image = image.oriented(.down)
        case 270: image = image.oriented(.left)
        default: break
        }
        image = FrameRenderer.aspectFillTransform(image, destWidth: targetWidth, destHeight: targetHeight)
        ciContext.render(image, to: dest,
                         bounds: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
                         colorSpace: CGColorSpaceCreateDeviceRGB())

        lock.lock()
        latestBuffer = dest
        framesOut += 1
        let count = framesOut
        lock.unlock()
        if count == 1 {
            status("收到画面 \(targetWidth)x\(targetHeight) 正在投屏")
            Diag.log("CarWithin：首帧已解出")
        }
    }

    /// 供界面显示的一行状态（线程安全读）
    var statusText: String {
        lock.lock()
        defer { lock.unlock() }
        return connectionState
    }

    /// 诊断用：入帧 / 出帧 / 音频包计数
    var counters: (in: Int, out: Int, audio: Int) {
        let snapshot = decodeQueue.sync { (framesIn, framesOut, audioPackets) }
        return (snapshot.0, snapshot.1, snapshot.2)
    }

    private func status(_ text: String) {
        lock.lock()
        connectionState = text
        lock.unlock()
        onStatus(text)
    }
}

// MARK: - URLSessionWebSocketDelegate

extension CarWithinSource: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        // protocol 是保留字，取值必须加反引号，否则解析器当成声明关键字
        let negotiated = `protocol` ?? ""
        Diag.log("CarWithin：WebSocket 已连接 \(negotiated)")
        sendReady()
        sendDisplay()
        startPing()
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        handleDisconnect("服务端关闭 \(closeCode.rawValue)")
    }

    /// CarWithin 的 HTTPS 端口是自签证书：和浏览器里点「继续访问」等价
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
