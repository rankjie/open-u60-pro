import struct
import unittest

from patch_wms_sms_events import ANCHORS, PATCHED_END, PATCH_SITE, PIPE_SENDER, RESUME, TEXT_END, TRAMPOLINE, patch


def fixture():
    data = bytearray(328325)
    data[:6] = b"\x7fELF\x02\x01"
    struct.pack_into("<H", data, 18, 183)
    struct.pack_into("<Q", data, 32, 64)
    struct.pack_into("<HH", data, 54, 56, 1)
    struct.pack_into("<IIQQQQQQ", data, 64, 1, 5, 0, 0, 0, TEXT_END, TEXT_END, 4096)
    for offset, value in ANCHORS.items():
        data[offset:offset + len(value)] = value
    data[0x48000:0x48009] = b"untouched"
    return bytes(data)


def destination(data, address, *, link=False):
    word = struct.unpack_from("<I", data, address)[0]
    assert word >> 26 == (0b100101 if link else 0b000101)
    offset = word & 0x3FFFFFF
    if offset & 0x2000000:
        offset -= 0x4000000
    return address + offset * 4


class WMSEventPatchTests(unittest.TestCase):
    def test_stored_arrival_uses_native_pipe_and_resumes_original_cleanup(self):
        original = fixture()
        result = patch(original)
        self.assertEqual(destination(result, PATCH_SITE), TRAMPOLINE)
        self.assertEqual(struct.unpack_from("<II", result, TRAMPOLINE), (0x52800000, 0xD2800001))
        self.assertEqual(destination(result, TRAMPOLINE + 8, link=True), PIPE_SENDER)
        self.assertEqual(destination(result, TRAMPOLINE + 12), RESUME)
        self.assertEqual(struct.unpack_from("<QQ", result, 64 + 32), (PATCHED_END, PATCHED_END))
        allowed = set(range(PATCH_SITE, PATCH_SITE + 4)) | set(range(TRAMPOLINE, PATCHED_END)) | set(range(96, 112))
        self.assertTrue(all(left == right or index in allowed for index, (left, right) in enumerate(zip(original, result))))
        self.assertEqual(len(result), len(original))

    def test_changed_firmware_or_occupied_padding_is_rejected(self):
        for offset in (18, PATCH_SITE, PIPE_SENDER, 0x3F811, TRAMPOLINE):
            with self.subTest(offset=offset):
                data = bytearray(fixture())
                data[offset] ^= 1
                with self.assertRaises(ValueError):
                    patch(bytes(data))

    def test_reapplying_patch_is_rejected_instead_of_patching_another_branch(self):
        with self.assertRaises(ValueError):
            patch(patch(fixture()))


if __name__ == "__main__":
    unittest.main()
