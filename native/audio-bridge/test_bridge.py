"""Exercise the native PCM contract with synthetic buffers and a private socket pair."""
import ctypes
import errno
import os
from pathlib import Path
import platform
import socket
import struct
import subprocess
import tempfile
import unittest


class AudioBridgeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="openu60-audio-test-")
        output = Path(cls.directory.name) / "bridge.so"
        source = Path(__file__).with_name("bridge.c")
        flag = "-dynamiclib" if platform.system() == "Darwin" else "-shared"
        subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", flag, "-fPIC", "-pthread", str(source), "-o", str(output)], check=True)
        cls.bridge = ctypes.CDLL(str(output))
        cls.bridge.zte_rtp_dsp_send_handler.argtypes = [ctypes.c_void_p, ctypes.c_ushort]
        cls.bridge.zte_rtp_dsp_receive_handler.argtypes = [ctypes.c_void_p, ctypes.c_uint]

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def setUp(self):
        self.parent, self.child = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
        self.parent.settimeout(3)
        self.previous = os.environ.get("OPENU60_AUDIO_FD")
        os.environ["OPENU60_AUDIO_FD"] = str(self.child.fileno())
        self.assertEqual(self.bridge.zte_rtp_init(), 0)
        self.assertEqual(self.parent.recv(64), b"OU60\x01\x00\x08\x00" + struct.pack("<IHH", 8000, 1, 16))

    def tearDown(self):
        self.bridge.zte_rtp_deinit()
        self.parent.close()
        self.child.close()
        if self.previous is None:
            os.environ.pop("OPENU60_AUDIO_FD", None)
        else:
            os.environ["OPENU60_AUDIO_FD"] = self.previous

    def test_downlink_pcm_is_delivered_without_modification(self):
        pcm = struct.pack("<160h", *range(-80, 80))
        self.assertEqual(self.bridge.zte_rtp_dsp_send_handler(pcm, len(pcm)), 320)
        self.assertEqual(self.parent.recv(1024), b"OU60\x02\x00\x40\x01" + pcm)

    def test_uplink_pcm_is_copied_only_for_a_complete_valid_frame(self):
        pcm = struct.pack("<160h", *range(160))
        output = ctypes.create_string_buffer(320)
        self.parent.send(b"OU60\x03\x00\x40\x01" + pcm)
        self.assertEqual(self.bridge.zte_rtp_dsp_receive_handler(output, 320), 320)
        self.assertEqual(output.raw, pcm)

    def test_malformed_packets_fail_without_substituting_silence(self):
        for packet in [b"short", b"OU60\x02\x00\x40\x01" + bytes(320), b"OU60\x03\x00\x40\x01" + bytes(318)]:
            with self.subTest(packet_length=len(packet)):
                output = ctypes.create_string_buffer(b"x" * 320, 320)
                self.parent.send(packet)
                self.assertLess(self.bridge.zte_rtp_dsp_receive_handler(output, 320), 0)
                self.assertEqual(output.raw, b"x" * 320)

    def test_invalid_pcm_sizes_and_closed_channels_fail(self):
        self.assertEqual(self.bridge.zte_rtp_dsp_send_handler(b"x", 1), -errno.EINVAL)
        self.bridge.zte_rtp_deinit()
        self.assertEqual(self.bridge.zte_rtp_dsp_send_handler(bytes(320), 320), -errno.ENOTCONN)


if __name__ == "__main__":
    unittest.main()
