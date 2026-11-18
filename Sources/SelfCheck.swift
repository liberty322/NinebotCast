import Foundation

/// 对应 NinebotPro 里的 `CodecSelfCheck`：不依赖仪表的本地字节级自检。
///
/// 原版有 H.264 编码自检和 JPEG-RTP 自检，这里做的是同一类事——
/// 把打包器的输出逐字段拆开核对，位置错一个字节就能立刻发现，
/// 不用等仪表黑屏才猜。
struct SelfCheck {

    struct Result: Identifiable {
        let id = UUID()
        let name: String
        let passed: Bool
        let detail: String
    }

    /// RTP 打包器自检（20 字节头 / 分片 / 标志位 / 时间戳 / 帧标识）
    static func runRTP(chunkSize: Int = 1400) -> [Result] {
        var out: [Result] = []

        // 造一帧 3.5 个分片的假数据，方便检查首/中/尾包的标志差异
        let frameLen = chunkSize * 3 + 700
        let payload = Data((0..<frameLen).map { UInt8($0 & 0xFF) })
        let timestampMs: UInt32 = 0x1234_5678
        var packer = RTPPacker(chunkSize: chunkSize)
        let packets = packer.packetizeFrame(payload, timestampMs: timestampMs, isKeyframe: true)

        // 1. 分片数
        let expectCount = (frameLen + chunkSize - 1) / chunkSize
        out.append(Result(
            name: "分片数量",
            passed: packets.count == expectCount,
            detail: "期望 \(expectCount) 包，实际 \(packets.count) 包（每片 \(chunkSize) 字节）"))

        guard !packets.isEmpty else { return out }

        // 2. 每包固定 20 字节头，且头部常量正确
        var headerOK = true
        var headerNote = ""
        for (i, p) in packets.enumerated() {
            let isLast = i == packets.count - 1
            let wantPT: UInt8 = (isLast ? 0x80 : 0x00) | 32
            if p.count != 20 + min(chunkSize, frameLen - i * chunkSize) {
                headerOK = false; headerNote = "第 \(i) 包长度 \(p.count) 不符"; break
            }
            if p[0] != 0x90 { headerOK = false; headerNote = "第 \(i) 包 [0]=\(String(format: "%02x", p[0]))，应为 90"; break }
            if p[1] != wantPT { headerOK = false; headerNote = "第 \(i) 包 [1]=\(String(format: "%02x", p[1]))，应为 \(String(format: "%02x", wantPT))"; break }
            if p[15] != 1 { headerOK = false; headerNote = "第 \(i) 包 [15]=\(p[15])，应为 1"; break }
            if p[16] != 0 { headerOK = false; headerNote = "第 \(i) 包 [16]=\(p[16])，应为 0"; break }
            for k in 8...14 where p[k] != 0 {
                headerOK = false; headerNote = "第 \(i) 包 [\(k)] 非零"; break
            }
            if !headerOK { break }
        }
        out.append(Result(name: "20 字节包头常量", passed: headerOK,
                          detail: headerOK ? "V=2/X=1、PT=32、[15]=1、[16]=0、[8..14]=0 全部正确"
                                           : headerNote))

        // 3. 时间戳 BE32
        var tsOK = true
        for p in packets where p[4] != UInt8((timestampMs >> 24) & 0xFF)
            || p[5] != UInt8((timestampMs >> 16) & 0xFF)
            || p[6] != UInt8((timestampMs >> 8) & 0xFF)
            || p[7] != UInt8(timestampMs & 0xFF) {
            tsOK = false; break
        }
        out.append(Result(name: "时间戳 BE32", passed: tsOK,
                          detail: tsOK ? "全部等于 \(timestampMs) 毫秒" : "存在包时间戳不匹配"))

        // 4. 帧标识 BE16(1024 | ts&1023)
        let wantTag = UInt16(1024 + Int(timestampMs & 1023))
        var tagOK = true
        for p in packets {
            let got = UInt16(p[18]) << 8 | UInt16(p[19])
            if got != wantTag { tagOK = false; break }
        }
        out.append(Result(name: "帧标识", passed: tagOK,
                          detail: tagOK ? "全部为 \(wantTag)（1024 | 时间戳低 10 位）" : "存在不一致"))

        // 5. 首/中/尾包标志位 + 关键帧位
        var flagOK = true
        var flagNote = ""
        for (i, p) in packets.enumerated() {
            let isFirst = i == 0
            let isLast = i == packets.count - 1
            let want: UInt8 = (isFirst ? 0x10 : 0x00) | 0x01 | (isLast ? 0x08 : 0x00)
            if p[17] != want {
                flagOK = false
                flagNote = "第 \(i) 包 [17]=\(String(format: "%02x", p[17]))，应为 \(String(format: "%02x", want))"
                break
            }
        }
        out.append(Result(name: "首/尾/关键帧标志", passed: flagOK,
                          detail: flagOK ? "首包 0x11、尾包 0x09、中间 0x01" : flagNote))

        // 6. 负载无损
        var reassembled = Data()
        for p in packets { reassembled.append(p.subdata(in: 20..<p.count)) }
        let payloadOK = reassembled == payload
        out.append(Result(name: "负载重组", passed: payloadOK,
                          detail: payloadOK ? "\(frameLen) 字节逐字节一致" : "重组后与原帧不一致"))

        return out
    }

    /// RTCP 控制包自检（5013 心跳格式）
    static func runRTCP() -> [Result] {
        var out: [Result] = []
        let hb = RTCP.heartbeat()
        let hbOK = hb.count == 20 && hb[0] == 0x85 && hb[1] == 0xCC && hb[3] == 4 && hb[19] == 2
        let hbNote = hbOK
            ? "20 字节，85 CC 00 04 …，尾部 02"
            : "字段不符：\(hb.map { String(format: "%02x", $0) }.joined(separator: " "))"
        out.append(Result(name: "RTCP 心跳包", passed: hbOK, detail: hbNote))

        let ping = RTCP.ping(counter: 0x01020304)
        let pingOK = ping.count == 20 && ping[0] == 0x85 && ping[12] == 0x04 && ping[13] == 0x03
        let pingNote = pingOK ? "20 字节，计数器 LE32 落在 [12..15]" : "计数器位置不符"
        out.append(Result(name: "RTCP ping 包", passed: pingOK, detail: pingNote))
        return out
    }

    /// 参数校验自检：把 StreamProfile 的边界跑一遍
    static func runProfile() -> [Result] {
        var out: [Result] = []
        let cases: [(String, StreamProfile, Bool)] = [
            ("848×480 / 20fps / 2000kbps", StreamProfile(), true),
            ("63×480（宽过小）", StreamProfile(width: 63), false),
            ("848×481（高为奇数）", StreamProfile(height: 481), false),
            ("1921×1080（宽过大）", StreamProfile(width: 1921), false),
            ("1920×1080（像素上限）", StreamProfile(width: 1920, height: 1080, fps: 30,
                                                  bitrateKbps: 8000, jpegQuality: 95), true),
            ("帧率 31（越界）", StreamProfile(fps: 31), false),
            ("码率 249（越界）", StreamProfile(bitrateKbps: 249), false),
            ("质量 96（越界）", StreamProfile(jpegQuality: 96), false),
        ]
        for (name, p, shouldPass) in cases {
            let passed = (try? p.validated()) != nil
            out.append(Result(name: name,
                              passed: passed == shouldPass,
                              detail: passed ? "通过校验" : "被拒绝（与原版一致）"))
        }
        return out
    }

    static func runAll() -> [Result] {
        runProfile() + runRTP() + runRTCP()
    }
}
