import Foundation

/// NinebotPro 的投屏参数模型。
///
/// 字段与判据全部来自对 NinebotPro 1.0.1 (arm64) 的逆向：
/// `NinebotPro.StreamProfile.validated()` @ 0x10001e740。原版结构布局：
///
///     0x00 width        64 … 1920
///     0x08 height       64 … 1920，且 (w|h)&1 == 0，且 w*h <= 1920*1080
///     0x10 fps          5 … 30
///     0x18 bitrate      250000 … 8000000 bps
///     0x20 rotation     必须是 {0, 90, 180, 270}
///     0x28 scaleMode    不校验
///     0x30 jpegQuality  30 … 95
///
/// 这里保持同样的边界和同样的中文提示，行为与原版一致。

enum ScaleMode: String, CaseIterable, Identifiable {
    case fit, crop, stretch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fit: return "适配（留黑边）"
        case .crop: return "裁剪（铺满）"
        case .stretch: return "拉伸（变形）"
        }
    }
}

enum StreamCodec: String, CaseIterable, Identifiable {
    case h264, jpeg

    var id: String { rawValue }
    var title: String { self == .h264 ? "H.264" : "JPEG（4.3 寸）" }
}

enum Rotation: Int, CaseIterable, Identifiable {
    case r0 = 0, r90 = 90, r180 = 180, r270 = 270

    var id: Int { rawValue }
    var title: String { "\(rawValue)°" }
}

struct StreamProfile: Equatable {
    var width: Int = 848
    var height: Int = 480
    var fps: Int = 20
    var bitrateKbps: Int = 2000
    var rotation: Rotation = .r0
    var scaleMode: ScaleMode = .fit
    var jpegQuality: Int = 80
    var codec: StreamCodec = .h264

    // 原版常量
    static let sideMin = 64
    static let sideMax = 1920
    static let pixelMax = 1920 * 1080          // 0x1fa400
    static let fpsRange = 5...30
    static let bitrateRange = 250...8000        // kbps
    static let qualityRange = 30...95

    enum ValidationError: LocalizedError {
        case size
        case rate
        case rotation

        var errorDescription: String? {
            switch self {
            case .size:
                return "宽高须为 64–1920 之间的偶数，总像素不超过 1920×1080"
            case .rate:
                return "帧率须为 5–30，码率须为 250–8000 kbps，JPEG 质量须为 30–95"
            case .rotation:
                return "旋转角度必须是 0、90、180、270 之一"
            }
        }
    }

    /// 逐项校验，顺序与原版汇编一致：尺寸 → 帧率/码率/质量 → 旋转。
    func validated() throws -> StreamProfile {
        var p = self

        // 原版：sub w-1921 ; cmn #1857 → 等价于 64 <= w <= 1920
        let widthOK = p.width >= Self.sideMin && p.width <= Self.sideMax
        let heightOK = p.height >= Self.sideMin && p.height <= Self.sideMax
        // 原版：and x14, x14, #1 要求两者都是偶数
        let evenOK = (p.width & 1) == 0 && (p.height & 1) == 0
        // 原版：mul 后与 0x1fa400 = 2073600 比较
        let pixelsOK = p.width * p.height <= Self.pixelMax
        guard widthOK, heightOK, evenOK, pixelsOK else {
            throw ValidationError.size
        }

        guard Self.fpsRange.contains(p.fps),
              Self.bitrateRange.contains(p.bitrateKbps),
              Self.qualityRange.contains(p.jpegQuality) else {
            throw ValidationError.rate
        }

        guard Rotation.allCases.contains(p.rotation) else {
            throw ValidationError.rotation
        }

        p.width = Self.evenize(p.width)
        p.height = Self.evenize(p.height)
        return p
    }

    static func evenize(_ v: Int) -> Int { (v / 2) * 2 }

    /// 原版仪表地址：五寸 192.168.1.1，4.3 寸（实验）192.168.169.1
    var defaultDashboardIP: String {
        codec == .jpeg ? "192.168.169.1" : "192.168.1.1"
    }

    var summary: String {
        "\(width)×\(height) · \(fps)fps · \(bitrateKbps)kbps · \(codec.title) · \(rotation.title)"
    }
}
