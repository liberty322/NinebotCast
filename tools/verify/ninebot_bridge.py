#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ninebot_bridge.py —— 把 CarWithin 的浏览器流协议转成 ninebot_pro iOS 能接的方言。

为什么需要它
------------
ninebot_pro iOS 的 CarPlay 通道（OpenXPlayFrameSource）连上 WebSocket 后会：
    1. 发一条自己的 hello
    2. 等服务器推 format + H.264 帧
而 CarWithin 的 /stream 只有在收到浏览器发来的
    {"type":"ready","decoder":"mse","viewer":"<uuid>","audioClock":false}
和
    {"type":"display","w":..,"h":..,"dpr":..,"hz":..,"h265":..,...}
之后才会开始出流。两边互相等，握手就死在那儿 —— 表现就是
"openxplay websocket 已连接，正在请求 H.264 画面" 然后一直卡住。

本脚本做中间人：
    ninebot_pro  --ws-->  [本脚本]  --ws-->  CarWithin /stream
对 CarWithin 它扮演一个"浏览器接收端"，把 ready/display/ping 补齐；
对 ninebot_pro 它扮演服务器，把 CarWithin 吐出来的 hello / format / 二进制帧
原样转发过去。

依赖：只用 Python 标准库。Python 3.7+。

用法
----
    python ninebot_bridge.py --upstream 192.168.1.5:9888
    python ninebot_bridge.py --upstream 192.168.1.5:9888 --listen 0.0.0.0:9000
    python ninebot_bridge.py --upstream 192.168.1.5:9888 --view 848x480 --fps 20 --h265 no

然后把 ninebot_pro 里 CarWithin 的地址从 192.168.1.5:9888 改成 你的电脑IP:9000。

常用开关
--------
--view 848x480     向 CarWithin 上报的接收端分辨率（决定它编码多大）。默认 848x480
--fps 20           期望帧率，只写进日志和 display 的 hz 提示，不强制
--h265 yes|no      上报是否支持 H.265。默认 no（ninebot 那边只吃 H.264）
--h264 yes         强制要求 H.264（默认 yes；CarWithin 会按接收端能力选编码）
--page-remove      转发 format/hello 前删掉 page 字段，避免 ninebot 版本号不匹配
--page-set N       把 page 字段强制改成 N（和 --page-remove 二选一）
--no-audio         丢掉 CarWithin 的音频包（tag=3），只转视频
--pass-client-text 把 ninebot 发来的文本也转给 CarWithin（默认吞掉，避免污染）
--raw              逐帧打印二进制帧头，排查分帧问题用

排查顺序
--------
1. 先只开本脚本，日志里应该出现 "carwithin 已连接" 和 "收到 hello/format"。
2. 再让 ninebot_pro 连上来，日志里会出现 "ninebot 客户端连入" 以及它的第一条文本。
3. 如果 ninebot 那边仍然停在"请求 H.264 画面"，看日志里 format 消息的字段，
   用 --page-remove 或 --page-set 试；再不行把日志发出来对着改字段名。
"""

import argparse
import base64
import hashlib
import json
import os
import socket
import struct
import sys
import threading
import time
import uuid

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
OP_CONT, OP_TEXT, OP_BIN, OP_CLOSE, OP_PING, OP_PONG = 0x0, 0x1, 0x2, 0x8, 0x9, 0xA


# ---------------------------------------------------------------- 基础设施
def log(tag, msg):
    ts = time.strftime("%H:%M:%S")
    sys.stdout.write("[%s] %-9s %s\n" % (ts, tag, msg))
    sys.stdout.flush()


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("对端关闭连接")
        buf += chunk
    return buf


def ws_read_frame(sock):
    """返回 (opcode, payload)。处理了掩码和分片以外的全部长度格式。"""
    b1, b2 = recv_exact(sock, 2)
    fin = b1 >> 7
    opcode = b1 & 0x0F
    masked = b2 >> 7
    length = b2 & 0x7F
    if length == 126:
        length = struct.unpack(">H", recv_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack(">Q", recv_exact(sock, 8))[0]
    mask = recv_exact(sock, 4) if masked else None
    payload = recv_exact(sock, length) if length else b""
    if mask:
        payload = bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload))
    # 分片帧：这里直接拼接，不区分 fin，够用
    if opcode == OP_CONT:
        return OP_CONT, payload
    return opcode, payload


def ws_build_frame(opcode, payload, mask):
    header = bytearray()
    header.append(0x80 | opcode)
    length = len(payload)
    mask_bit = 0x80 if mask else 0x00
    if length < 126:
        header.append(mask_bit | length)
    elif length < 65536:
        header.append(mask_bit | 126)
        header += struct.pack(">H", length)
    else:
        header.append(mask_bit | 127)
        header += struct.pack(">Q", length)
    if mask:
        key = os.urandom(4)
        header += key
        payload = bytes(byte ^ key[i % 4] for i, byte in enumerate(payload))
    return bytes(header) + payload


def ws_send(sock, opcode, payload, mask, lock):
    with lock:
        sock.sendall(ws_build_frame(opcode, payload, mask))


# ---------------------------------------------------------------- 客户端：连 CarWithin
class CarWithinClient(object):
    def __init__(self, host, port, path, on_text, on_binary, on_close):
        self.host = host
        self.port = port
        self.path = path
        self.on_text = on_text
        self.on_binary = on_binary
        self.on_close = on_close
        self.sock = None
        self.send_lock = threading.Lock()
        self.alive = False

    def connect(self):
        sock = socket.create_connection((self.host, self.port), timeout=10)
        sock.settimeout(None)
        key = base64.b64encode(os.urandom(16)).decode()
        req = (
            "GET %s HTTP/1.1\r\n"
            "Host: %s:%d\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Key: %s\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "Origin: http://%s:%d\r\n"
            "User-Agent: Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1\r\n"
            "\r\n" % (self.path, self.host, self.port, key, self.host, self.port)
        )
        sock.sendall(req.encode())
        resp = b""
        while b"\r\n\r\n" not in resp:
            chunk = sock.recv(4096)
            if not chunk:
                raise ConnectionError("CarWithin 在握手阶段关掉了连接")
            resp += chunk
        head = resp.split(b"\r\n\r\n", 1)[0].decode("latin-1")
        if "101" not in head.split("\r\n")[0]:
            raise ConnectionError("CarWithin 没回 101：%s" % head.split("\r\n")[0])
        expect = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        if expect.lower() not in head.lower():
            log("warn", "Sec-WebSocket-Accept 对不上，但先继续")
        self.sock = sock
        self.alive = True
        log("up", "carwithin 已连接 ws://%s:%d%s" % (self.host, self.port, self.path))
        threading.Thread(target=self._reader, daemon=True).start()
        return True

    def _reader(self):
        try:
            while self.alive:
                opcode, payload = ws_read_frame(self.sock)
                if opcode == OP_TEXT:
                    self.on_text(payload.decode("utf-8", "replace"))
                elif opcode == OP_BIN:
                    self.on_binary(payload)
                elif opcode == OP_PING:
                    ws_send(self.sock, OP_PONG, payload, True, self.send_lock)
                elif opcode == OP_CLOSE:
                    log("up", "carwithin 发来 close")
                    break
        except Exception as exc:
            log("up", "读取中断：%s" % exc)
        finally:
            self.alive = False
            self.on_close()

    def send_text(self, text):
        if not self.alive or not self.sock:
            return
        try:
            ws_send(self.sock, OP_TEXT, text.encode("utf-8"), True, self.send_lock)
        except Exception as exc:
            log("up", "发送失败：%s" % exc)

    def close(self):
        self.alive = False
        try:
            if self.sock:
                self.sock.close()
        except Exception:
            pass


# ---------------------------------------------------------------- 服务端：接 ninebot
class NinebotServer(object):
    def __init__(self, bind, on_text, on_binary, on_connect):
        host, port = bind.rsplit(":", 1)
        self.host = host
        self.port = int(port)
        self.on_text = on_text
        self.on_binary = on_binary
        self.on_connect = on_connect
        self.clients = []
        self.lock = threading.Lock()

    def serve_forever(self):
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind((self.host, self.port))
        srv.listen(8)
        log("down", "等待 ninebot_pro 连接：ws://%s:%d/  （在 App 里填 <电脑IP>:%d）"
            % (self.host, self.port, self.port))
        while True:
            sock, addr = srv.accept()
            threading.Thread(target=self._handle, args=(sock, addr), daemon=True).start()

    def _handle(self, sock, addr):
        try:
            req = b""
            while b"\r\n\r\n" not in req:
                chunk = sock.recv(4096)
                if not chunk:
                    return
                req += chunk
            text = req.decode("latin-1")
            first = text.split("\r\n")[0]
            key = ""
            for line in text.split("\r\n"):
                if line.lower().startswith("sec-websocket-key:"):
                    key = line.split(":", 1)[1].strip()
            if not key:
                sock.sendall(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
                sock.close()
                return
            accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
            sock.sendall((
                "HTTP/1.1 101 Switching Protocols\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                "Sec-WebSocket-Accept: %s\r\n\r\n" % accept
            ).encode())
            log("down", "ninebot 客户端连入 %s   请求行：%s" % (addr, first))
            client = {"sock": sock, "lock": threading.Lock(), "addr": addr}
            with self.lock:
                self.clients.append(client)
            self.on_connect(client)
            while True:
                opcode, payload = ws_read_frame(sock)
                if opcode == OP_TEXT:
                    self.on_text(payload.decode("utf-8", "replace"))
                elif opcode == OP_BIN:
                    self.on_binary(payload)
                elif opcode == OP_PING:
                    ws_send(sock, OP_PONG, payload, False, client["lock"])
                elif opcode == OP_CLOSE:
                    break
        except Exception as exc:
            log("down", "连接结束：%s" % exc)
        finally:
            with self.lock:
                self.clients = [c for c in self.clients if c["sock"] is not sock]
            try:
                sock.close()
            except Exception:
                pass
            log("down", "ninebot 客户端断开")

    def broadcast_text(self, text):
        with self.lock:
            targets = list(self.clients)
        for c in targets:
            try:
                ws_send(c["sock"], OP_TEXT, text.encode("utf-8"), False, c["lock"])
            except Exception:
                pass

    def broadcast_binary(self, payload):
        with self.lock:
            targets = list(self.clients)
        for c in targets:
            try:
                ws_send(c["sock"], OP_BIN, payload, False, c["lock"])
            except Exception:
                pass

    def count(self):
        with self.lock:
            return len(self.clients)


# ---------------------------------------------------------------- 主逻辑
def pretty(raw):
    try:
        return json.dumps(json.loads(raw), ensure_ascii=False, separators=(",", ":"))
    except Exception:
        return raw[:400]


class Bridge(object):
    def __init__(self, args):
        self.args = args
        self.down = None
        self.up = None
        self.stats = {"frames": 0, "bytes": 0, "audio": 0, "text": 0, "since": time.time()}

    # --- CarWithin -> ninebot
    def on_up_text(self, raw):
        self.stats["text"] += 1
        log("up->down", pretty(raw))
        # 记住 hello / format，后连进来的客户端要能补一遍
        try:
            kind = json.loads(raw).get("type")
        except Exception:
            kind = None
        if kind in ("hello", "format", "status"):
            self.last_texts = [t for t in self.last_texts if json.loads(t).get("type") != kind]
            self.last_texts.append(raw)
        self.forward_text(raw)

    def on_up_binary(self, payload):
        if not payload:
            return
        tag = payload[0]
        if tag == 3:
            self.stats["audio"] += 1
            if self.args.no_audio:
                return
        else:
            self.stats["frames"] += 1
            self.stats["bytes"] += len(payload)
            if self.args.raw:
                log("frame", "tag=%d len=%d head=%s" % (tag, len(payload), payload[:9].hex()))
        self.down.broadcast_binary(payload)

    def forward_text(self, raw):
        if self.args.page_remove or self.args.page_set is not None:
            try:
                obj = json.loads(raw)
                if isinstance(obj, dict) and "page" in obj:
                    if self.args.page_remove:
                        obj.pop("page", None)
                    else:
                        obj["page"] = self.args.page_set
                    raw = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
            except Exception:
                pass
        self.down.broadcast_text(raw)

    def on_up_close(self):
        log("up", "上游断开，3 秒后重连")
        time.sleep(3)
        self.connect_up()

    # --- ninebot -> CarWithin
    def on_down_text(self, raw):
        log("down->up", pretty(raw))
        if self.args.pass_client_text:
            self.up.send_text(raw)
            return
        try:
            obj = json.loads(raw)
        except Exception:
            return
        kind = obj.get("type") if isinstance(obj, dict) else None
        if kind == "ping":
            self.down.broadcast_text(json.dumps(
                {"type": "pong", "t0": obj.get("t0"), "s": int(time.time() * 1e6)}))
        elif kind == "ready":
            log("note", "ninebot 自己发了 ready —— 说明它其实懂这套，可以不转发")
            self.up.send_text(raw)
        elif kind == "display":
            log("note", "ninebot 报了自己的显示尺寸，已转给 CarWithin")
            self.up.send_text(raw)

    def on_down_binary(self, payload):
        log("down->up", "binary %d 字节（忽略）" % len(payload))

    def on_down_connect(self, client):
        # 新客户端连进来，把它需要的握手信息补一遍
        time.sleep(0.2)
        self.send_hello_snapshot()

    def send_hello_snapshot(self):
        for raw in self.last_texts:
            self.forward_text(raw)

    # --- 连接管理
    def connect_up(self):
        host, port = self.args.upstream.rsplit(":", 1)
        client = CarWithinClient(host, int(port), self.args.path,
                                 self.on_up_text, self.on_up_binary, self.on_up_close)
        try:
            client.connect()
        except Exception as exc:
            log("up", "连 CarWithin 失败：%s（3 秒后重试）" % exc)
            time.sleep(3)
            return self.connect_up()
        self.up = client
        self.send_ready()

    def send_ready(self):
        w, h = [int(x) for x in self.args.view.lower().split("x")]
        viewer = str(uuid.uuid4())
        self.up.send_text(json.dumps({
            "type": "ready",
            "decoder": "mse",
            "viewer": viewer,
            "audioClock": False,
        }, separators=(",", ":")))
        log("up", "已发送 ready decoder=mse viewer=%s" % viewer)
        self.up.send_text(json.dumps({
            "type": "display",
            "w": w, "h": h, "dpr": 1,
            "sw": w, "sh": h,
            "hz": self.args.fps,
            "h265": self.args.h265 == "yes",
            "fullscreen": False,
            "ua": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
                  "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
        }, separators=(",", ":")))
        log("up", "已发送 display %dx%d h265=%s" % (w, h, self.args.h265))

    def heartbeat(self):
        while True:
            time.sleep(1.0)
            if self.up and self.up.alive:
                self.up.send_text(json.dumps({"type": "ping", "t0": int(time.time() * 1e6)}))
            if time.time() - self.stats["since"] >= 10:
                log("stat", "10 秒内 文本=%d 视频帧=%d 音频包=%d 总字节=%d 下游客户端=%d"
                    % (self.stats["text"], self.stats["frames"], self.stats["audio"],
                       self.stats["bytes"], self.down.count() if self.down else 0))
                self.stats.update({"frames": 0, "bytes": 0, "audio": 0, "text": 0,
                                   "since": time.time()})

    def run(self):
        self.last_texts = []
        self.down = NinebotServer(self.args.listen, self.on_down_text,
                                  self.on_down_binary, self.on_down_connect)
        threading.Thread(target=self.down.serve_forever, daemon=True).start()
        self.connect_up()
        self.heartbeat()


def main():
    ap = argparse.ArgumentParser(description="CarWithin -> ninebot_pro 协议桥")
    ap.add_argument("--upstream", default="192.168.1.5:9888", help="CarWithin 的 IP:端口（HTTP 端口）")
    ap.add_argument("--path", default="/stream", help="CarWithin 的 WebSocket 路径")
    ap.add_argument("--listen", default="0.0.0.0:9000", help="本脚本对外监听的 IP:端口")
    ap.add_argument("--view", default="848x480", help="上报给 CarWithin 的接收端分辨率")
    ap.add_argument("--fps", type=int, default=60, help="上报的刷新率/期望帧率")
    ap.add_argument("--h265", default="no", choices=["yes", "no"], help="是否上报支持 H.265")
    ap.add_argument("--no-audio", action="store_true", help="丢弃音频包")
    ap.add_argument("--page-remove", action="store_true", help="转发前删掉 page 字段")
    ap.add_argument("--page-set", type=int, default=None, help="转发前把 page 改成指定值")
    ap.add_argument("--pass-client-text", action="store_true", help="把 ninebot 的文本也转给 CarWithin")
    ap.add_argument("--raw", action="store_true", help="逐帧打印二进制帧头")
    args = ap.parse_args()
    log("boot", "upstream=%s%s  listen=%s  view=%s" % (args.upstream, args.path, args.listen, args.view))
    try:
        Bridge(args).run()
    except KeyboardInterrupt:
        log("boot", "退出")


if __name__ == "__main__":
    main()
