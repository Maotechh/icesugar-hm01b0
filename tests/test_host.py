import binascii
import os
from pathlib import Path
import struct
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch
import zlib
from host.camera import (Camera, CameraError, decode_response, gray_png, main, parse_frame, request_packet,
                         save_frame, walking_errors)


class ProtocolTests(unittest.TestCase):
    def test_configuration(self):
        class SensorModel(Camera):
            def __init__(self):
                self.registers = {0: 1, 1: 0xb0, 0x0100: 0}
                self.streaming_readback = []
                self.bad_readback = False
                self.bad_analog_readback = False

            def enable(self, enabled=True):
                self.enabled = enabled

            def read(self, address):
                if address not in (0x0100, 0, 1):
                    self.streaming_readback.append(self.registers[0x0100])
                if self.bad_readback and address == 0x3059:
                    return 0
                if address == 0x3052:
                    return 0xd1 if self.bad_analog_readback else 0xd0
                return self.registers[address]

            def write(self, address, value):
                if address == 0x0103:
                    self.registers = {0: 1, 1: 0xb0, 0x0100: 0}
                else:
                    self.registers[address] = value

        sensor = SensorModel()
        with patch("host.camera.time.sleep"):
            for pattern in ("walking", "image"):
                config = sensor.configure(pattern)
                self.assertEqual(config["chip_id"], "0x01b0")
                self.assertEqual(sensor.registers[0x3059], 0x42)
                self.assertEqual(sensor.registers[0x3060], 0x08)
                self.assertEqual(sensor.registers[0x1012], 0)
                self.assertEqual(sensor.registers[0x2100], int(pattern == "image"))
                self.assertEqual(sensor.registers[0x0601], 0x11 if pattern == "walking" else 0)
                self.assertEqual(sensor.registers[0x0100], 1)
                if pattern == "image":
                    self.assertEqual(config["registers"]["0x3052"], 0xd0)
                    self.assertEqual(config["register_writes"]["0x3052"], 0x50)
                self.assertTrue(sensor.enabled)
                self.assertFalse(any(sensor.streaming_readback))
                sensor.standby()
                self.assertEqual(sensor.registers[0x0100], 0)
                self.assertFalse(sensor.enabled)
            sensor.bad_readback = True
            with self.assertRaises(CameraError):
                sensor.configure("image")
            self.assertEqual(sensor.registers[0x0100], 0)
            sensor.bad_readback = False
            sensor.bad_analog_readback = True
            with self.assertRaises(CameraError):
                sensor.configure("image")
            self.assertEqual(sensor.registers[0x0100], 0)

    def test_request(self):
        p = request_packet(2, 4, 0x1234, 0x56)
        self.assertEqual(p[:7], b"HC\x02\x04\x12\x34\x56")
        self.assertEqual(binascii.crc_hqx(p, 65535), 0)

    def test_response(self):
        p = b"HC\x02\x04\x00" + struct.pack("<I", 1) + b"\xa6"
        p += struct.pack("<I", zlib.crc32(p))
        self.assertEqual(decode_response(p, 2, 4), b"\xa6")
        for i in range(len(p)):
            broken = bytearray(p)
            broken[i] ^= 1
            with self.assertRaises(CameraError):
                decode_response(broken, 2, 4)
        with self.assertRaises(CameraError):
            decode_response(p[:-1], 2, 4)

    def test_command_discards_delayed_response(self):
        def response(seq, payload):
            header = b"HC" + bytes((0, seq, 0)) + struct.pack("<I", len(payload))
            packet = header + payload
            return packet + struct.pack("<I", zlib.crc32(packet))

        camera = Camera.__new__(Camera)
        peer, camera.fd = os.pipe()
        camera.seq = 16
        stale = response(99, b"old")
        current = response(16, b"new")
        camera.stream = stale + current

        def read_exact(size, deadline):
            del deadline
            result, camera.stream = camera.stream[:size], camera.stream[size:]
            self.assertEqual(len(result), size)
            return result

        camera.read_exact = read_exact
        try:
            self.assertEqual(camera.command(0), b"new")
            self.assertEqual(camera.seq, 17)
        finally:
            os.close(camera.fd)
            os.close(peer)

    def test_frame(self):
        raw = bytes(324 * 244)
        header = struct.pack("<IHHHBBI", len(raw), 244, 648, 648, 0, 0, 123)
        self.assertTrue(parse_frame(header + raw, 0)[1]["valid"])
        self.assertFalse(parse_frame(header + raw[:-1], 0)[1]["valid"])
        self.assertFalse(parse_frame(header + raw, 1)[1]["valid"])
        for flag in range(8):
            broken = bytearray(header)
            broken[10] = 1 << flag
            self.assertFalse(parse_frame(broken + raw, 0)[1]["valid"])

    def test_walking(self):
        raw = bytes((1,2,4,8,16,32,64,128,0)) * 100
        self.assertEqual(walking_errors(raw), 0)
        self.assertEqual(walking_errors(raw[4:]), 0)
        self.assertEqual(walking_errors(raw[:10] + b"\xff" + raw[11:]), 1)
        self.assertGreater(walking_errors(bytes(900)), 0)

    def test_png(self):
        png = gray_png(bytes(range(6)), 3, 2)
        self.assertEqual(png[:8], b"\x89PNG\r\n\x1a\n")
        index = 8
        chunks = {}
        while index < len(png):
            size = struct.unpack_from(">I", png, index)[0]
            kind = png[index+4:index+8]
            body = png[index+8:index+8+size]
            self.assertEqual(struct.unpack_from(">I", png, index+8+size)[0], zlib.crc32(kind+body))
            chunks[kind] = body
            index += 12 + size
        self.assertEqual(zlib.decompress(chunks[b"IDAT"]), b"\x00\x00\x01\x02\x00\x03\x04\x05")

    def test_frame_output_refuses_collisions(self):
        raw = bytes(324 * 244)
        with TemporaryDirectory() as directory:
            save_frame(directory, 0, raw, {"valid": True})
            self.assertTrue((Path(directory) / "frame-0000.png").exists())
            self.assertTrue((Path(directory) / "frame-0000.pgm").exists())
            with self.assertRaises(FileExistsError):
                save_frame(directory, 0, b"invalid", {"valid": False})
            self.assertEqual((Path(directory) / "frame-0000.raw").read_bytes(), raw)

    def test_invalid_frame_has_only_evidence(self):
        with TemporaryDirectory() as directory:
            save_frame(directory, 0, b"invalid", {"valid": False})
            self.assertEqual(sorted(p.suffix for p in Path(directory).iterdir()),
                             [".json", ".raw"])

    def test_orphan_image_blocks_frame_write(self):
        with TemporaryDirectory() as directory:
            previous = Path(directory) / "frame-0000.png"
            previous.write_bytes(b"previous image")
            with self.assertRaises(FileExistsError):
                save_frame(directory, 0, b"invalid", {"valid": False})
            self.assertEqual(previous.read_bytes(), b"previous image")
            self.assertFalse((Path(directory) / "frame-0000.raw").exists())

    def test_existing_output_rejected_before_opening_serial(self):
        with TemporaryDirectory() as directory:
            with patch("sys.argv", ["camera.py", "capture", "--output", directory]):
                with patch("host.camera.Camera") as camera:
                    with self.assertRaises(FileExistsError):
                        main()
                    camera.assert_not_called()


if __name__ == "__main__":
    unittest.main()
