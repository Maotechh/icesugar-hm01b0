import os
import pty
import select
import struct
import threading
import unittest
from unittest.mock import patch
import zlib

from host.camera import Camera, CameraError


class SerialTests(unittest.TestCase):
    def test_reopen_synchronizes_before_capture(self):
        self.exercise_recovery(partial=False)

    def test_partial_old_response_is_drained(self):
        self.exercise_recovery(partial=True)

    def test_synchronization_deadline(self):
        camera = Camera.__new__(Camera)
        camera.fd = 0
        with patch("host.camera.time.monotonic", side_effect=[0, 0, 0, 0, 18]):
            with patch("host.camera.select.select", return_value=([], [], [])):
                with patch.object(camera, "status", side_effect=CameraError("timeout")) as status:
                    with self.assertRaisesRegex(CameraError, "synchronization timeout"):
                        camera.synchronize()
                    status.assert_called_once_with(timeout=3)

    def exercise_recovery(self, partial):
        master, slave = pty.openpty()
        errors = []

        def request():
            data = bytearray()
            while len(data) < 9:
                if not select.select([master], [], [], 6)[0]:
                    raise TimeoutError("No host request")
                data.extend(os.read(master, 9 - len(data)))
            self.assertEqual(data[:2], b"HC")
            return data

        def respond(op, seq, payload):
            packet = b"HC" + bytes((op, seq, 0)) + struct.pack("<I", len(payload)) + payload
            packet += struct.pack("<I", zlib.crc32(packet))
            pending = memoryview(packet)
            while pending:
                pending = pending[os.write(master, pending):]

        def device():
            try:
                first = request()
                self.assertEqual(first[2], 0)
                # The FPGA was busy: it dropped the status request and is
                # completing a capture from the previous host connection.
                if partial:
                    os.write(master, b"old response tail without a header")
                else:
                    respond(4, first[3], b"old frame")
                barrier = request()
                self.assertEqual(barrier[2], 0)
                status = bytes((1, 1)) + bytes(10) + struct.pack("<I", 48000000)
                respond(0, barrier[3], status)
                capture = request()
                self.assertEqual(capture[2], 4)
                respond(4, capture[3], b"fresh frame")
            except BaseException as exc:
                errors.append(exc)

        worker = threading.Thread(target=device, daemon=True)
        worker.start()
        camera = None
        try:
            camera = Camera(os.ttyname(slave))
            self.assertEqual(camera.command(4), b"fresh frame")
        finally:
            if camera is not None:
                camera.close()
            worker.join(7)
            os.close(master)
            os.close(slave)
        self.assertFalse(worker.is_alive(), "Device test did not finish")
        if errors:
            raise errors[0]


if __name__ == "__main__":
    unittest.main()
