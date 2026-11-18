"""CarWithin /stream 握手与拆帧逻辑验证（对应 Sources/CarWithinSource.swift）。

本地没有 Xcode，没法编译 Swift，但协议逻辑可以在这里 1:1 复现并跑通：

  1. 假 CarWithin 服务器严格复刻它的门禁——没收到 ready 就一个字都不发；
  2. 模拟 ninebot_pro 的客户端（只发自己的 hello）：必须复现「永远卡在请求画面」；
  3. 模拟 CarWithinSource 的客户端（先发 ready + display）：必须拿到 hello / format / 视频帧；
  4. avcC 解析：nalLengthSize 与 SPS/PPS 必须还原正确；
  5. 二进制帧拆包：tag / 时间戳偏移 / 关键帧判定必须和 Swift 里一致。

用法：python test_carwithin_logic.py
"""

import base64
import json
import socket
import struct
import sys
import threading
import time

import ninebot_bridge as bridge

PORT = 9922
GUID = bridge.GUID
OP_CONT, OP_TEXT, OP_BIN, OP_CLOSE, OP_PING, OP_PONG = 0, 1, 2, 8, 9, 0xA

# 一段形状合法（内容不必真能被解码）的 SPS / PPS
SPS = bytes([0x67, 0x42, 0x00, 0x1E, 0x95, 0xA8, 0x28, 0x0B, 0x7B, 0x20])
PPS = bytes([0x68, 0xCE, 0x3C, 0x80])
IDR = bytes([0x65, 0x88, 0x84, 0x00, 0x21, 0xFF, 0xAB, 0xCD])
DELTA = bytes([0x41, 0x9A, 0x02, 0x18, 0x3C])

checks = []


def check(name, ok, detail=""):
    checks.append(bool(ok))
    print("  %-46s %s %s" % (name, "PASS" if ok else "FAIL", detail))
    return ok


# ---------------------------------------------------------------- avcC

def build_avcc(sps, pps, nal_length=4):
    body = b"\x01" + bytes([0x42, 0x00, 0x1E])
    body += bytes([0xFC | ((nal_length - 1) & 0x03)])     # 低 2 位 = 长度字节数-1
    body += bytes([0xE0 | 1])                             # numSPS = 1
    body += struct.pack(">H", len(sps)) + sps
    body += bytes([1])                                    # numPPS = 1
    body += struct.pack(">H", len(pps)) + pps
    return body


def parse_avcc(record):
    """和 Swift 里 makeH264FormatDescription 的逻辑逐行对应。"""
    if len(record) < 7 or record[0] != 1:
        return None
    nal_length = (record[4] & 0x03) + 1
    index = 5
    sps_count = record[index] & 0x1F
    index += 1
    sets = []
    for _ in range(sps_count):
        if index + 1 >= len(record):
            return None
        length = (record[index] << 8) | record[index + 1]
        index += 2
        if length <= 0 or index + length > len(record):
            return None
        sets.append(record[index:index + length])
        index += length
    if index >= len(record):
        return None
    pps_count = record[index]
    index += 1
    for _ in range(pps_count):
        if index + 1 >= len(record):
            return None
        length = (record[index] << 8) | record[index + 1]
        index += 2
        if length <= 0 or index + length > len(record):
            return None
        sets.append(record[index:index + length])
        index += length
    if len(sets) < 2:
        return None
    return nal_length, sets


def split(packet):
    """和 Swift handleBinary 一一对应，含时间戳提取。"""
    tag = packet[0]
    timed = tag in (4, 5)
    kind = tag - 4 if timed else tag
    offset = 9 if timed else 1
    stamp = None
    if timed and len(packet) >= 9:
        value = 0
        for i in range(8):
            value = (value << 8) | packet[1 + i]
        if 0 < value < (1 << 63):
            stamp = value
    return timed, kind, packet[offset:], stamp


def sniff_nal_length(avcc):
    """和 Swift sniffNalLength 一一对应：能严格切完才认。"""
    for size in (4, 2, 1, 3):
        index, count, ok = 0, 0, True
        while index + size <= len(avcc):
            length = int.from_bytes(avcc[index:index + size], "big")
            index += size
            if length <= 0 or index + length > len(avcc):
                ok = False
                break
            index += length
            count += 1
        if ok and count > 0 and index == len(avcc):
            return size
    return None


def parameter_sets(avcc, length_size, hevc=False):
    """和 Swift parameterSets 一一对应。"""
    index, vps, sps, pps = 0, None, None, None
    while index + length_size <= len(avcc):
        length = int.from_bytes(avcc[index:index + length_size], "big")
        index += length_size
        if length <= 0 or index + length > len(avcc):
            return None
        head = avcc[index]
        nal = avcc[index:index + length]
        index += length
        if hevc:
            kind = (head >> 1) & 0x3F
            if kind == 32 and vps is None:
                vps = nal
            elif kind == 33 and sps is None:
                sps = nal
            elif kind == 34 and pps is None:
                pps = nal
        else:
            kind = head & 0x1F
            if kind == 7 and sps is None:
                sps = nal
            elif kind == 8 and pps is None:
                pps = nal
    if sps is None or pps is None:
        return None
    if hevc and vps is not None:
        return [vps, sps, pps]
    return [sps, pps]


# ---------------------------------------------------------------- 假 CarWithin

class MockCarWithin(object):
    """严格按 CarWithin 的门禁发流：ready + display 齐了才发 hello/format/帧。"""

    def __init__(self, port, include_description=True, in_band=False):
        self.port = port
        self.frames = []
        self.lock = threading.Lock()
        self.avcc = build_avcc(SPS, PPS)
        self.include_description = include_description
        self.in_band = in_band
        self.srv = None

    def start(self):
        self.srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.srv.bind(("127.0.0.1", self.port))
        self.srv.listen(8)
        threading.Thread(target=self._accept, daemon=True).start()

    def stop(self):
        try:
            self.srv.close()
        except Exception:
            pass

    def _accept(self):
        while True:
            try:
                sock, _ = self.srv.accept()
            except OSError:
                return
            threading.Thread(target=self._handle, args=(sock,), daemon=True).start()

    def _handshake(self, sock):
        raw = b""
        while b"\r\n\r\n" not in raw:
            chunk = sock.recv(4096)
            if not chunk:
                raise ConnectionError("客户端在握手阶段断开")
            raw += chunk
        key = ""
        for line in raw.decode("latin-1").split("\r\n"):
            if line.lower().startswith("sec-websocket-key:"):
                key = line.split(":", 1)[1].strip()
        if not key:
            raise ConnectionError("没有 Sec-WebSocket-Key")
        accept = base64.b64encode(
            __import__("hashlib").sha1((key + GUID).encode()).digest()).decode()
        sock.sendall((
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Accept: %s\r\n\r\n" % accept).encode())

    def _send_text(self, sock, obj):
        bridge.ws_send(sock, OP_TEXT, json.dumps(obj).encode(), False, self.lock)

    def _send_bin(self, sock, payload):
        bridge.ws_send(sock, OP_BIN, payload, False, self.lock)

    def _handle(self, sock):
        try:
            self._handshake(sock)
            sock.settimeout(10)
            ready = False
            display = None
            while not (ready and display):
                opcode, payload = bridge.ws_read_frame(sock)
                if opcode == OP_CLOSE:
                    return
                if opcode == OP_PING:
                    bridge.ws_send(sock, OP_PONG, payload, False, self.lock)
                    continue
                if opcode != OP_TEXT:
                    continue
                try:
                    msg = json.loads(payload.decode("utf-8", "replace"))
                except ValueError:
                    continue
                if msg.get("type") == "ready":
                    ready = True
                elif msg.get("type") == "display":
                    display = msg
                elif msg.get("type") == "ping":
                    self._send_text(sock, {"type": "pong", "t0": msg.get("t0"), "s": 1})

            # 门禁通过 → 这才开始推流
            self._send_text(sock, {"type": "hello", "page": 21, "perf": {"drop": 0},
                                   "showTouches": False, "audio": False, "securePort": 9889})
            fmt = {
                "type": "format",
                "decoder": "mse",
                "codec": "avc1.42C01E",
                "width": 848,
                "height": 480,
                "name": "CarPlay",
                "duration": 0,
                "timescale": 1,
            }
            # MSE 模式下 CarWithin 的 format 可以不带 description
            if self.include_description:
                fmt["description"] = base64.b64encode(self.avcc).decode()
            self._send_text(sock, fmt)
            ts = 12345
            if self.in_band:
                # 关键帧里自带 SPS/PPS，客户端要能现挑出来
                body_idr = (struct.pack(">I", len(SPS)) + SPS
                            + struct.pack(">I", len(PPS)) + PPS
                            + struct.pack(">I", len(IDR)) + IDR)
            else:
                body_idr = struct.pack(">I", len(IDR)) + IDR
            self._send_bin(sock, bytes([5]) + struct.pack(">Q", ts) + body_idr)
            self._send_bin(sock, bytes([4]) + struct.pack(">Q", ts + 40000)
                           + struct.pack(">I", len(DELTA)) + DELTA)
            self._send_bin(sock, bytes([1]) + body_idr)      # 无时间戳的关键帧
            # 保持连接，回 pong
            while True:
                opcode, payload = bridge.ws_read_frame(sock)
                if opcode == OP_CLOSE:
                    return
                if opcode == OP_TEXT:
                    try:
                        msg = json.loads(payload.decode("utf-8", "replace"))
                    except ValueError:
                        continue
                    if msg.get("type") == "ping":
                        self._send_text(sock, {"type": "pong", "t0": msg.get("t0"), "s": 2})
        except Exception:
            pass
        finally:
            try:
                sock.close()
            except Exception:
                pass


# ---------------------------------------------------------------- 客户端

def ws_connect(port):
    sock = socket.create_connection(("127.0.0.1", port), timeout=5)
    key = base64.b64encode(b"0123456789abcdef").decode()
    sock.sendall((
        "GET /stream HTTP/1.1\r\n"
        "Host: 127.0.0.1:%d\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Key: %s\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n" % (port, key)).encode())
    raw = b""
    while b"\r\n\r\n" not in raw:
        chunk = sock.recv(4096)
        if not chunk:
            raise ConnectionError("服务端在握手阶段断开")
        raw += chunk
    if b"101" not in raw.split(b"\r\n")[0]:
        raise ConnectionError("升级失败：%r" % raw.split(b"\r\n")[0])
    return sock


def send_json(sock, lock, obj):
    bridge.ws_send(sock, OP_TEXT, json.dumps(obj).encode(), True, lock)


def expect_silence(sock, seconds):
    """等一段时间，看服务端有没有主动发东西。"""
    sock.settimeout(seconds)
    try:
        data = sock.recv(1)
        return False if data else True
    except socket.timeout:
        return True
    except OSError:
        return True


def test_old_client(mock):
    """ninebot_pro 的行为：只发自己的 hello，不认 ready/display。"""
    sock = ws_connect(PORT)
    lock = threading.Lock()
    send_json(sock, lock, {"type": "hello", "version": 0, "token": "",
                           "decoders": [{"codecString": "avc1.42E01E", "hardware": True}],
                           "displays": [], "maxTouchContacts": 5})
    silent = expect_silence(sock, 1.5)
    check("旧客户端只发 hello → 服务端始终沉默（复现卡死）", silent)
    sock.close()


def test_ready_only(mock):
    """只发 ready 不发 display：同样拿不到流，证明两个都要。"""
    sock = ws_connect(PORT)
    lock = threading.Lock()
    send_json(sock, lock, {"type": "ready", "decoder": "mse",
                           "viewer": "11111111-1111-1111-1111-111111111111",
                           "audioClock": False})
    silent = expect_silence(sock, 1.5)
    check("只发 ready 不发 display → 仍然沉默", silent)
    sock.close()


def test_new_client(mock):
    """CarWithinSource 的行为：ready + display 齐发。"""
    sock = ws_connect(PORT)
    lock = threading.Lock()
    send_json(sock, lock, {"type": "ready", "decoder": "mse",
                           "viewer": "22222222-2222-2222-2222-222222222222",
                           "audioClock": False})
    send_json(sock, lock, {"type": "display", "w": 848, "h": 480, "dpr": 1,
                           "sw": 848, "sh": 480, "hz": 20, "h265": False,
                           "fullscreen": False, "ua": "NinebotCast/1.0"})
    sock.settimeout(5)

    got = {"hello": False, "format": None, "frames": []}
    deadline = time.time() + 8
    while time.time() < deadline:
        try:
            opcode, payload = bridge.ws_read_frame(sock)
        except (socket.timeout, ConnectionError, OSError):
            break
        if opcode == OP_TEXT:
            msg = json.loads(payload.decode("utf-8", "replace"))
            if msg.get("type") == "hello":
                got["hello"] = True
            elif msg.get("type") == "format":
                got["format"] = msg
        elif opcode == OP_BIN:
            got["frames"].append(payload)
        if got["hello"] and got["format"] and len(got["frames"]) >= 3:
            break

    check("握手后收到 hello", got["hello"])
    fmt = got["format"] or {}
    check("握手后收到 format", bool(fmt))
    check("format 带 avcC description", isinstance(fmt.get("description"), str))

    record = base64.b64decode(fmt.get("description", ""))
    parsed = parse_avcc(record)
    check("avcC 解析成功", parsed is not None)
    if parsed:
        nal_length, sets = parsed
        check("nalLengthSize == 4", nal_length == 4, "得到 %s" % nal_length)
        check("SPS 还原一致", sets[0] == SPS)
        check("PPS 还原一致", sets[1] == PPS)

    check("收到 3 个媒体帧", len(got["frames"]) >= 3, "得到 %d" % len(got["frames"]))

    if len(got["frames"]) >= 3:
        timed, kind, body, stamp = split(got["frames"][0])
        check("帧1 带时间戳", timed)
        check("帧1 判定为关键帧", kind == 1)
        check("帧1 body 对齐 9 字节头", body == struct.pack(">I", len(IDR)) + IDR)
        check("帧1 解析出大端微秒时间戳", stamp == 12345, "得到 %s" % stamp)

        timed, kind, body, stamp = split(got["frames"][1])
        check("帧2 带时间戳", timed)
        check("帧2 判定为普通帧", kind == 0)
        check("帧2 body 对齐 9 字节头", body == struct.pack(">I", len(DELTA)) + DELTA)
        check("帧2 时间戳递增", stamp == 12345 + 40000, "得到 %s" % stamp)

        timed, kind, body, stamp = split(got["frames"][2])
        check("帧3 无时间戳", not timed)
        check("帧3 判定为关键帧（tag=1）", kind == 1)
        check("帧3 body 对齐 1 字节头", body == struct.pack(">I", len(IDR)) + IDR)
        check("帧3 没有时间戳可用", stamp is None)

    # 保活：发 ping 要收到 pong
    send_json(sock, lock, {"type": "ping", "t0": 999})
    sock.settimeout(5)
    pong = False
    deadline = time.time() + 5
    while time.time() < deadline:
        try:
            opcode, payload = bridge.ws_read_frame(sock)
        except (socket.timeout, ConnectionError, OSError):
            break
        if opcode == OP_TEXT:
            msg = json.loads(payload.decode("utf-8", "replace"))
            if msg.get("type") == "pong" and msg.get("t0") == 999:
                pong = True
                break
    check("ping → pong 往返正常", pong)
    sock.close()


def test_inband_client():
    """MSE 模式的真实情况：format 没有 description，SPS/PPS 只在关键帧里。"""
    port = PORT + 1
    mock = MockCarWithin(port, include_description=False, in_band=True)
    mock.start()
    time.sleep(0.4)
    try:
        sock = ws_connect(port)
        lock = threading.Lock()
        send_json(sock, lock, {"type": "ready", "decoder": "mse",
                               "viewer": "33333333-3333-3333-3333-333333333333",
                               "audioClock": False})
        send_json(sock, lock, {"type": "display", "w": 848, "h": 480, "dpr": 1,
                               "sw": 848, "sh": 480, "hz": 20, "h265": False,
                               "fullscreen": False, "ua": "NinebotCast/1.0"})
        sock.settimeout(5)

        fmt, frames = None, []
        deadline = time.time() + 8
        while time.time() < deadline:
            try:
                opcode, payload = bridge.ws_read_frame(sock)
            except (socket.timeout, ConnectionError, OSError):
                break
            if opcode == OP_TEXT:
                msg = json.loads(payload.decode("utf-8", "replace"))
                if msg.get("type") == "format":
                    fmt = msg
            elif opcode == OP_BIN:
                frames.append(payload)
            if fmt is not None and len(frames) >= 3:
                break

        check("无 description 的 format 仍能收到", fmt is not None)
        check("该 format 确实没有 description", "description" not in (fmt or {}),
              "字段=%s" % sorted((fmt or {}).keys()))

        if frames:
            timed, kind, body, stamp = split(frames[0])
            check("带内关键帧判定正确", timed and kind == 1 and stamp == 12345)

            guessed = sniff_nal_length(body)
            check("长度前缀嗅探出 4 字节", guessed == 4, "得到 %s" % guessed)
            if guessed:
                sets = parameter_sets(body, guessed)
                check("从关键帧抠出 2 个参数集", sets is not None and len(sets) == 2)
                if sets:
                    check("抠出的 SPS 正确", sets[0] == SPS)
                    check("抠出的 PPS 正确", sets[1] == PPS)
                    # 用这些参数集重建 avcC，应当和服务器原本那份一致
                    check("用带内参数集能重建可用 avcC",
                          parse_avcc(build_avcc(sets[0], sets[1])) is not None)
        sock.close()
    finally:
        mock.stop()


def main():
    mock = MockCarWithin(PORT)
    mock.start()
    time.sleep(0.4)
    print("假 CarWithin 起在 127.0.0.1:%d" % PORT)
    print("")
    print("[1] 复现原故障：旧客户端（ninebot_pro 的 hello）")
    test_old_client(mock)
    print("[2] 门禁一半：只发 ready")
    test_ready_only(mock)
    print("[3] 新客户端：ready + display")
    test_new_client(mock)
    mock.stop()
    print("[4] MSE 真身：无 description，参数集在关键帧里")
    test_inband_client()
    print("")
    total = len(checks)
    passed = sum(1 for c in checks if c)
    print("结果：%d/%d 通过" % (passed, total))
    sys.exit(0 if passed == total else 1)


if __name__ == "__main__":
    main()
