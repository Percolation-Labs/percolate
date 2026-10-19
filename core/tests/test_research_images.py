"""An article image is identified by its bytes, kept only when it fits the rule, and read through a revision (REM-309)."""
import struct
import unittest
import zlib
from contextlib import asynccontextmanager
from unittest.mock import AsyncMock, patch
from uuid import UUID

from fastapi.testclient import TestClient

from percolate_core.content import images
from percolate_core.content.server import build_app, caller


def png(width: int, height: int) -> bytes:
    def chunk(kind: bytes, body: bytes) -> bytes:
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"\0")) + chunk(b"IEND", b""))


def jpeg(width: int, height: int) -> bytes:
    app0 = b"\xff\xe0" + struct.pack(">H", 16) + b"JFIF\0\x01\x01\0\0\x01\0\x01\0\0"
    sof = b"\xff\xc0" + struct.pack(">HBHHB", 11, 8, height, width, 1) + b"\x01\x11\x00"
    return b"\xff\xd8" + app0 + sof + b"\xff\xd9"


def webp_lossless(width: int, height: int) -> bytes:
    bits = (width - 1) | ((height - 1) << 14)
    body = b"\x2f" + bits.to_bytes(4, "little") + b"\0" * 8
    chunk = b"VP8L" + struct.pack("<I", len(body)) + body
    return b"RIFF" + struct.pack("<I", 4 + len(chunk)) + b"WEBP" + chunk


SVG = b'<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>'


class IdentifyTest(unittest.TestCase):
    def test_reads_type_and_size_from_the_bytes(self):
        self.assertEqual(images.identify(png(1200, 675)), ("image/png", 1200, 675))
        self.assertEqual(images.identify(jpeg(800, 600)), ("image/jpeg", 800, 600))
        self.assertEqual(images.identify(webp_lossless(640, 480)), ("image/webp", 640, 480))
        self.assertIsNone(images.identify(SVG))
        self.assertIsNone(images.identify(b"GIF89a" + b"\0" * 40))

    def test_refuses_what_the_rule_refuses(self):
        self.assertEqual(images.check(png(600, 400))[0], "image/png")
        for data, says in ((b"", "empty"), (SVG, "SVG"), (png(599, 400), "at least 600 x 400"),
                           (jpeg(800, 399), "at least 600 x 400"), (png(800, 600) + b"\0" * images.MAX_BYTES, "2 MB")):
            with self.subTest(says=says), self.assertRaisesRegex(images.ImageRefused, says):
                images.check(data)


class RoutesTest(unittest.TestCase):
    def app(self, conn, claims):
        @asynccontextmanager
        async def scoped(_claims):
            self.seen = _claims
            yield conn
        application = build_app(())
        application.dependency_overrides[caller] = lambda: claims
        return application, scoped

    def test_an_upload_is_checked_before_anything_is_stored(self):
        conn = AsyncMock()
        application, scoped = self.app(conn, {"sub": "writer"})
        with patch("percolate_core.content.server.as_caller", scoped), \
                patch("percolate_core.content.server.storage.put") as put, TestClient(application) as client:
            for body in (SVG, png(300, 200)):
                response = client.post("/research-images", content=body, headers={"Content-Type": "image/png"})
                self.assertEqual(response.status_code, 422)
                self.assertFalse(response.json()["saved"])
            put.assert_not_called()

    def test_an_upload_is_registered_under_the_type_its_bytes_have(self):
        conn = AsyncMock()
        conn.fetchval.side_effect = [{"status": "unlimited"}, UUID("22222222-2222-2222-2222-222222222222")]
        application, scoped = self.app(conn, {"sub": "writer"})
        with patch("percolate_core.content.server.as_caller", scoped), \
                patch("percolate_core.content.server.storage.put", return_value=("sum", "key")) as put, \
                patch("percolate_core.content.server.storage.bucket", return_value="bucket"), \
                TestClient(application) as client:
            # The header lies; the bytes are a JPEG.
            response = client.post("/research-images", content=jpeg(800, 600),
                                   headers={"Content-Type": "image/png", "X-P8-Title": "Cover"})
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.json()["content_type"], "image/jpeg")
        self.assertEqual(put.call_args.args[1], "image/jpeg")
        sql, *args = conn.fetchval.call_args.args
        self.assertIn("content.register_research_image", sql)
        self.assertEqual(args[4:], ["image/jpeg", "Cover"])

    def test_an_upload_needs_a_signed_in_caller(self):
        application, _ = self.app(AsyncMock(), None)
        with TestClient(application) as client:
            self.assertEqual(client.post("/research-images", content=png(800, 600)).status_code, 401)

    def test_a_signed_out_reader_gets_the_image_inline_with_no_script(self):
        conn = AsyncMock()
        conn.fetchrow.return_value = {"bucket": "b", "object_key": "k", "content_type": "image/png",
                                      "size_bytes": 10, "checksum": "sum"}
        application, scoped = self.app(conn, None)
        snap = "33333333-3333-3333-3333-333333333333"
        with patch("percolate_core.content.server.as_caller", scoped), \
                patch("percolate_core.content.server.storage.get", return_value=png(800, 600)), \
                TestClient(application) as client:
            response = client.get(f"/research-images/{snap}")
        self.assertEqual(response.status_code, 200)
        self.assertIsNone(self.seen, "read as the anonymous caller, so the revision decides")
        self.assertEqual(conn.fetchrow.call_args.args[1:], (UUID(snap),))
        self.assertEqual(response.headers["content-type"], "image/png")
        self.assertEqual(response.headers["x-content-type-options"], "nosniff")
        self.assertIn("sandbox", response.headers["content-security-policy"])
        self.assertNotIn("attachment", response.headers.get("content-disposition", ""))

    def test_no_row_or_bytes_that_are_not_the_row_are_one_404(self):
        snap = "33333333-3333-3333-3333-333333333333"
        for row, stored in ((None, png(800, 600)),
                            ({"bucket": "b", "object_key": "k", "content_type": "image/png", "size_bytes": 1,
                              "checksum": "s"}, SVG)):
            conn = AsyncMock()
            conn.fetchrow.return_value = row
            application, scoped = self.app(conn, None)
            with self.subTest(row=bool(row)), patch("percolate_core.content.server.as_caller", scoped), \
                    patch("percolate_core.content.server.storage.get", return_value=stored), \
                    TestClient(application) as client:
                self.assertEqual(client.get(f"/research-images/{snap}").status_code, 404)


if __name__ == "__main__":
    unittest.main()
