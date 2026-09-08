#!/usr/bin/env python3
"""HM01B0 acquisition via the iCESugar FPGA. Python standard library only."""
import argparse
import binascii
import fcntl
import glob
import hashlib
import json
import os
from pathlib import Path
import select
import struct
import sys
import termios
import time
import zlib

WIDTH, HEIGHT = 324, 244
MAX_PAYLOAD = 131072 + 16
FLAG_NAMES = ("odd_nibbles", "line_length", "line_count", "sync_overlap",
              "overflow", "unstable_sample", "short_pclk", "timeout")

# Adapted from OpenMV HM01B0 default_regs (MIT), see LICENSES/OpenMV.txt.
# Bus width, sync offset and clock division remain in the shared configuration.
IMAGE_REGISTERS = {
    0x1003: 0, 0x1007: 0x08,
    0x3044: 0x0a, 0x3045: 0, 0x3047: 0x0a,
    0x3050: 0xc0, 0x3051: 0x42, 0x3052: 0x50, 0x3053: 0,
    0x3054: 0x03, 0x3055: 0xf7, 0x3056: 0xf8, 0x3057: 0x29,
    0x3058: 0x1f, 0x3064: 0, 0x3065: 0x04,
    0x1000: 0x43, 0x1001: 0x43, 0x1002: 0x43,
    0x0350: 0x7f, 0x1006: 1,
    0x1008: 1, 0x1009: 0xa0, 0x100a: 0x60, 0x100b: 0x90, 0x100c: 0x40,
    0x2000: 0x07,
    0x2003: 0, 0x2004: 0x1c, 0x2007: 0, 0x2008: 0x58,
    0x200b: 0, 0x200c: 0x7a, 0x200f: 0, 0x2010: 0xb8,
    0x2013: 0, 0x2014: 0x58, 0x2017: 0, 0x2018: 0x9b,
    0x2100: 1, 0x2101: 0x64, 0x2102: 0x0a, 0x2103: 3, 0x2104: 5,
    0x2105: 1, 0x2106: 2, 0x2108: 4, 0x2109: 4, 0x210b: 0xc0,
    0x210d: 0x20, 0x210e: 0,
    0x210f: 0, 0x2110: 0x3c, 0x2111: 0, 0x2112: 0x32,
    0x2150: 0, 0x3011: 0x70, 0x0101: 0,
}


class CameraError(RuntimeError):
    pass


def request_packet(op, seq, address=0, value=0):
    data = struct.pack(">2sBBHB", b"HC", op, seq, address, value)
    return data + struct.pack(">H", binascii.crc_hqx(data, 0xffff))


def decode_response(data, op, seq):
    if len(data) < 13:
        raise CameraError("Truncated response")
    magic, actual_op, actual_seq, status, length = struct.unpack("<2sBBBI", data[:9])
    if (magic, actual_op, actual_seq) != (b"HC", op, seq):
        raise CameraError("Response header/sequence mismatch")
    if length > MAX_PAYLOAD or len(data) != length + 13:
        raise CameraError("Invalid response length")
    if zlib.crc32(data[:-4]) != struct.unpack("<I", data[-4:])[0]:
        raise CameraError("Response CRC32 mismatch")
    if status:
        raise CameraError(f"FPGA status 0x{status:02x} for command {op}")
    return data[9:-4]


class Camera:
    def __init__(self, port=None):
        if port is None:
            ports = glob.glob("/dev/serial/by-id/usb-MuseLab_DAPLink_CMSIS-DAP_*-if01")
            if len(ports) != 1:
                raise CameraError("Need exactly one iCELink serial device, or use --port")
            port = ports[0]
        self.port, self.seq = port, 0
        self.fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.previous = termios.tcgetattr(self.fd)
            settings = termios.tcgetattr(self.fd)
            settings[:6] = [0, 0, termios.CS8 | termios.CREAD | termios.CLOCAL,
                            0, termios.B115200, termios.B115200]
            settings[6][termios.VMIN] = 0
            settings[6][termios.VTIME] = 0
            termios.tcsetattr(self.fd, termios.TCSANOW, settings)
            termios.tcflush(self.fd, termios.TCIFLUSH)
        except BaseException:
            os.close(self.fd)
            raise

    def close(self):
        try:
            termios.tcsetattr(self.fd, termios.TCSANOW, self.previous)
        finally:
            os.close(self.fd)

    def read_exact(self, size, deadline):
        result = bytearray()
        while len(result) < size:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.fd], [], [], remaining)[0]:
                raise CameraError(f"Serial timeout: got {len(result)}/{size} bytes")
            try:
                chunk = os.read(self.fd, size - len(result))
            except BlockingIOError:
                continue
            if not chunk:
                raise CameraError("Serial device disconnected")
            result.extend(chunk)
        return bytes(result)

    def command(self, op, address=0, value=0, timeout=3):
        seq = self.seq
        self.seq = (seq + 1) & 255
        packet = memoryview(request_packet(op, seq, address, value))
        deadline = time.monotonic() + timeout
        while packet:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([], [self.fd], [], remaining)[1]:
                raise CameraError("Serial write timeout")
            try:
                packet = packet[os.write(self.fd, packet):]
            except BlockingIOError:
                pass
        header = self.read_exact(9, deadline)
        if header[:4] != bytes((0x48, 0x43, op, seq)):
            raise CameraError(f"Unexpected response header: {header.hex()}")
        length = struct.unpack_from("<I", header, 5)[0]
        if length > MAX_PAYLOAD:
            raise CameraError(f"Oversized response: {length}")
        return decode_response(header + self.read_exact(length + 4, deadline), op, seq)

    def status(self):
        p = self.command(0)
        if len(p) != 16 or p[0] != 1:
            raise CameraError("Unsupported FPGA protocol")
        crc, uart, busy = struct.unpack_from("<HHH", p, 4)
        return dict(version=p[0], enabled=bool(p[1]), gpio=f"0x{p[2]:02x}",
                    request_crc_errors=crc, uart_errors=uart, busy_errors=busy,
                    clock_hz=struct.unpack_from("<I", p, 12)[0])

    def enable(self, enabled=True):
        p = self.command(3, value=int(enabled))
        if p != bytes([int(enabled)]):
            raise CameraError("Enable acknowledgement mismatch")

    def read(self, address):
        p = self.command(2, address)
        if len(p) != 1:
            raise CameraError("Invalid I2C read response")
        return p[0]

    def write(self, address, value):
        self.command(1, address, value)

    def chip_id(self):
        identity = self.read(0) << 8 | self.read(1)
        if identity != 0x01b0:
            raise CameraError(f"Unexpected sensor ID 0x{identity:04x}")
        return f"0x{identity:04x}"

    def configure(self, pattern="walking", polarity=0):
        self.enable()
        identity = self.chip_id()
        self.write(0x0103, 1)
        time.sleep(0.02)
        if self.read(0x0100) != 0:
            raise CameraError("Sensor did not enter standby after reset")
        # B0315 supplies its own 24 MHz clock; FPGA never drives XCLK.
        registers = {
            0x3067: 0, 0x3060: 0x08, 0x3059: 0x42, 0x1012: 0,
            0x0383: 1, 0x0387: 1, 0x0390: 0, 0x3010: 1,
            0x0340: 1, 0x0341: 4, 0x0342: 1, 0x0343: 0x78,
            0x3068: 0x20 | polarity,
            0x0202: 0, 0x0203: 188, 0x0205: 0, 0x020e: 1, 0x020f: 0,
            0x2100: 0, 0x1000: 0, 0x1008: 0,
            0x0601: 0x11 if pattern == "walking" else 0,
        }
        if pattern == "image":
            registers.update(IMAGE_REGISTERS)
        for address, value in registers.items():
            self.write(address, value)
        self.write(0x0104, 1)
        readback = {f"0x{a:04x}": self.read(a) for a in registers}
        for address, value in registers.items():
            # This module returns D0 after the upstream-recommended 3052=50.
            # Verified across three resets; compare exactly, do not mask bits.
            expected = 0xd0 if address == 0x3052 else value
            actual = readback[f"0x{address:04x}"]
            if actual != expected:
                raise CameraError(f"Register 0x{address:04x}: wrote 0x{value:02x}, "
                                  f"expected 0x{expected:02x}, read 0x{actual:02x}")
        self.write(0x0100, 1)
        if self.read(0x0100) != 1:
            raise CameraError("Sensor did not enter streaming mode")
        time.sleep(1 if pattern == "image" else 0.3)
        return dict(chip_id=identity, pattern=pattern, registers=readback,
                    register_writes={f"0x{a:04x}": v for a, v in registers.items()})

    def standby(self):
        self.enable()
        self.write(0x0100, 0)
        if self.read(0x0100) != 0:
            raise CameraError("Sensor did not enter standby")
        self.enable(False)

    def capture(self, mode=0):
        return parse_frame(self.command(4, value=mode, timeout=18), mode)


def parse_frame(payload, mode):
    if len(payload) < 16:
        raise CameraError("Truncated frame metadata")
    count, lines, minimum, maximum, flags, actual_mode, cycles = struct.unpack("<IHHHBBI", payload[:16])
    raw = payload[16:]
    metadata = dict(bytes=count, lines=lines, min_nibbles=minimum, max_nibbles=maximum,
                    flags=flags, errors=[name for i, name in enumerate(FLAG_NAMES) if flags & (1 << i)],
                    mode=actual_mode, cycles=cycles, crc32=f"{zlib.crc32(raw):08x}",
                    sha256=hashlib.sha256(raw).hexdigest())
    metadata["valid"] = (not flags and count == len(raw) == WIDTH * HEIGHT
                         and lines == HEIGHT and minimum == maximum == WIDTH * 2
                         and actual_mode == mode)
    return raw, metadata


def walking_errors(raw):
    # Sensor test pattern rotates 01,02,04,08,10,20,40,80,00 (nine positions).
    pattern = bytes((1, 2, 4, 8, 16, 32, 64, 128, 0))
    if not raw or raw[0] not in pattern:
        return len(raw) or 1
    phase = pattern.index(raw[0])
    return sum(b != pattern[(i + phase) % 9] for i, b in enumerate(raw))


def save_frame(directory, number, raw, metadata):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    base = directory / f"frame-{number:04d}"
    base.with_suffix(".raw").write_bytes(raw)
    base.with_suffix(".json").write_text(json.dumps(metadata, indent=2) + "\n")
    if metadata["valid"]:
        cropped = b"".join(raw[y * WIDTH + 2:y * WIDTH + 322] for y in range(2, 242))
        base.with_suffix(".pgm").write_bytes(b"P5\n320 240\n255\n" + cropped)
        base.with_suffix(".png").write_bytes(gray_png(cropped, 320, 240))


def gray_png(pixels, width, height):
    if len(pixels) != width * height:
        raise ValueError("PNG dimensions do not match pixels")
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))
    scanlines = b"".join(b"\x00" + pixels[y * width:(y + 1) * width] for y in range(height))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(scanlines)) + chunk(b"IEND", b""))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status")
    sub.add_parser("probe")
    sub.add_parser("disable")
    sub.add_parser("standby")
    config = sub.add_parser("configure")
    config.add_argument("--pattern", choices=("walking", "image"), default="walking")
    config.add_argument("--polarity", type=int, choices=(0, 1), default=0)
    capture = sub.add_parser("capture")
    capture.add_argument("--mode", type=int, choices=range(4), default=0)
    capture.add_argument("--count", type=int, default=1)
    capture.add_argument("--walking", action="store_true")
    capture.add_argument("--output", default="outputs/" + time.strftime("%Y%m%d-%H%M%S"))
    args = parser.parse_args()
    camera = Camera(args.port)
    try:
        if args.command == "status":
            print(json.dumps(camera.status(), indent=2))
        elif args.command == "disable":
            camera.enable(False)
            print(json.dumps(camera.status(), indent=2))
        elif args.command == "standby":
            camera.standby()
            print(json.dumps(camera.status(), indent=2))
        elif args.command == "probe":
            camera.enable()
            try:
                print(json.dumps(dict(chip_id=camera.chip_id(), status=camera.status()), indent=2))
            finally:
                camera.enable(False)
        elif args.command == "configure":
            print(json.dumps(camera.configure(args.pattern, args.polarity), indent=2))
        elif args.command == "capture":
            if args.count < 1:
                raise CameraError("Frame count must be positive")
            for i in range(args.count):
                raw, meta = camera.capture(args.mode)
                if args.walking:
                    meta["walking_errors"] = walking_errors(raw)
                    meta["valid"] &= meta["walking_errors"] == 0
                save_frame(args.output, i, raw, meta)
                print(json.dumps(dict(frame=i, **meta)), flush=True)
                if not meta["valid"]:
                    raise CameraError(f"Invalid frame saved for inspection in {args.output}")
    finally:
        camera.close()


if __name__ == "__main__":
    try:
        main()
    except (CameraError, OSError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
