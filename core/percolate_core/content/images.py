"""What an uploaded article image is, read from its own bytes (REM-309).

The uploader's `Content-Type` is a claim; the first bytes are the fact. An
article image is PNG, JPEG or WebP, at most 2 MB and at least 600 x 400
(the application's rule for article images). SVG is refused because
it can carry script, and so is anything this module cannot size: a picture we
cannot measure is not one we can promise renders.

Headers only, no decoder. A decoder is a dependency and an attack surface for a
question the first few hundred bytes answer.
"""
from __future__ import annotations

import struct

MAX_BYTES = 2 * 1024 * 1024
MIN_WIDTH, MIN_HEIGHT = 600, 400


class ImageRefused(ValueError):
    """Not kept, and why, in words the writer can act on."""


def _png(data: bytes) -> tuple[int, int] | None:
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR" or len(data) < 24:
        return None
    return struct.unpack(">II", data[16:24])


def _jpeg(data: bytes) -> tuple[int, int] | None:
    if data[:2] != b"\xff\xd8":
        return None
    i = 2
    while i + 4 <= len(data):
        if data[i] != 0xFF:
            return None
        marker = data[i + 1]
        if marker == 0xFF:          # fill byte
            i += 1
            continue
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
            i += 2
            continue
        length = struct.unpack(">H", data[i + 2:i + 4])[0]
        # Start-of-frame markers carry the size; C4, C8 and CC share the range and do not.
        if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
            if i + 9 > len(data):
                return None
            height, width = struct.unpack(">HH", data[i + 5:i + 9])
            return width, height
        i += 2 + length
    return None


def _webp(data: bytes) -> tuple[int, int] | None:
    if data[:4] != b"RIFF" or data[8:12] != b"WEBP" or len(data) < 30:
        return None
    chunk = data[12:16]
    if chunk == b"VP8 " and data[23:26] == b"\x9d\x01\x2a":
        width, height = struct.unpack("<HH", data[26:30])
        return width & 0x3FFF, height & 0x3FFF
    if chunk == b"VP8L" and data[20] == 0x2F:
        bits = int.from_bytes(data[21:25], "little")
        return (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
    if chunk == b"VP8X":
        return int.from_bytes(data[24:27], "little") + 1, int.from_bytes(data[27:30], "little") + 1
    return None


SNIFFERS = (("image/png", _png), ("image/jpeg", _jpeg), ("image/webp", _webp))


def identify(data: bytes) -> tuple[str, int, int] | None:
    """(content type, width, height) from the bytes, or None when they are none of the three."""
    for content_type, sniff in SNIFFERS:
        size = sniff(data)
        if size:
            return content_type, size[0], size[1]
    return None


def check(data: bytes) -> tuple[str, int, int]:
    """The image's type and size, or ImageRefused saying what is wrong with it."""
    if not data:
        raise ImageRefused("The file is empty.")
    if len(data) > MAX_BYTES:
        raise ImageRefused(f"The image is {len(data) / 1048576:.1f} MB; an article image is at most 2 MB.")
    found = identify(data)
    if found is None:
        raise ImageRefused("An article image is a PNG, JPEG or WebP file. SVG is not accepted, "
                           "because it can carry script: export it as a PNG.")
    content_type, width, height = found
    if width < MIN_WIDTH or height < MIN_HEIGHT:
        raise ImageRefused(f"The image is {width} x {height} pixels; an article image is at least "
                           f"{MIN_WIDTH} x {MIN_HEIGHT}.")
    return found
