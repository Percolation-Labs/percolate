"""Bytes to markdown, one lightweight library per format.

MARKDOWN IS THE INTERMEDIATE FORM FOR EVERYTHING, and that is a decision worth
stating because the alternative looks cheaper. A PDF could be chunked from its
text layer, a DOCX from its paragraph list, a transcript from its segments --
three formats, three chunkers, three sets of edge cases. Normalising to
markdown first means ONE chunker, and it means the thing a model is eventually
shown still has the headings and table structure that told a reader what the
sentence was about.

THE LIBRARY CHOICES, and why each is the light one:

    pdf    pymupdf4llm   -- reads the PDF's own structure, no model, no OCR by
                           default; milliseconds a page. Docling and MinerU
                           are better on scanned and multi-column documents and
                           cost 1-2GB of weights and 5-30x the time, which is
                           the wrong default and a reasonable opt-in.
                           NOTE: since 1.28 pymupdf4llm pulls pymupdf-layout,
                           which pulls onnxruntime (~75MB). `parser: pymupdf`
                           below is the same extraction with none of that.
    docx   python-docx   -- a zip and some XML. Pure Python, no converters in
                           the chain. MarkItDown covers more formats and pulls
                           magika (onnxruntime again) to guess types we are
                           already told.
    html   stdlib        -- HTMLParser. A dependency to strip tags is not one
                           worth having.
    audio  a remote      -- transcription is a model call, and a model call
                           belongs to the worker (the rule about what the
                           database may not do applies here too:
                           whoever holds the socket holds the latency). Any
                           OpenAI-shaped /audio/transcriptions endpoint works,
                           including a local one.

Nothing here does OCR. A scanned PDF produces little or no text, and this
module SAYS SO rather than returning three characters and letting the pipeline
report success -- see `EmptyParse`.
"""

from __future__ import annotations

import io
import re
from dataclasses import dataclass, field
from html.parser import HTMLParser
from typing import Any, ClassVar

from .policy import IngestPolicy

__all__ = ["PARSERS", "EmptyParse", "MissingParser", "ParseResult", "to_markdown"]


class EmptyParse(RuntimeError):
    """The parser ran and produced nothing worth chunking."""


class MissingParser(RuntimeError):
    """The library this parser needs is not installed."""


@dataclass
class ParseResult:
    markdown: str
    parser: str
    detail: dict[str, Any] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# The parsers. Each takes (bytes, name, policy) and returns markdown.
# ---------------------------------------------------------------------------

def _decode(data: bytes) -> str:
    """UTF-8, then latin-1 as the encoding that cannot fail.

    Guessing with chardet is a dependency and a probability; a mis-decoded byte
    in prose costs one wrong character, and refusing the upload costs the
    document. Latin-1 maps every byte to something, so this never raises.
    """
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data.decode("latin-1")


def _parse_markdown(data: bytes, name: str | None, policy: IngestPolicy) -> ParseResult:
    return ParseResult(_decode(data), "markdown")


def _parse_text(data: bytes, name: str | None, policy: IngestPolicy) -> ParseResult:
    """Plain text is markdown that happens to use no markup.

    Deliberately not "wrap it in a code fence": the text of a log or a JSON
    export is what gets embedded, and a fence would put two tokens of syntax at
    the front of every chunk.
    """
    return ParseResult(_decode(data), "text")


class _Stripper(HTMLParser):
    """Tags out, block structure kept. ~40 lines instead of a dependency."""

    _BLOCK: ClassVar[set[str]] = {"p", "div", "br", "li", "tr", "section",
                                  "article", "table"}
    _HEAD: ClassVar[dict[str, str]] = {
        "h1": "#", "h2": "##", "h3": "###", "h4": "####", "h5": "#####", "h6": "######"}

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.out: list[str] = []
        self._skip = 0

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style"):
            self._skip += 1
        elif tag in self._HEAD:
            self.out.append("\n\n" + self._HEAD[tag] + " ")
        elif tag == "li":
            self.out.append("\n- ")
        elif tag in self._BLOCK:
            self.out.append("\n\n")

    def handle_endtag(self, tag):
        if tag in ("script", "style") and self._skip:
            self._skip -= 1
        elif tag in self._HEAD:
            self.out.append("\n")

    def handle_data(self, data):
        if not self._skip:
            self.out.append(data)


def _parse_html(data: bytes, name: str | None, policy: IngestPolicy) -> ParseResult:
    s = _Stripper()
    s.feed(_decode(data))
    text = re.sub(r"\n{3,}", "\n\n", "".join(s.out))
    text = re.sub(r"[ \t]{2,}", " ", text)
    return ParseResult(text.strip(), "html")


def _parse_pdf_rich(data: bytes, name: str | None, policy: IngestPolicy) -> ParseResult:
    try:
        import pymupdf
        import pymupdf4llm
    except ModuleNotFoundError as e:
        raise MissingParser(
            "the pdf parser needs pymupdf4llm: pip install 'percolate-core[ingest]' "
            f"(missing {e.name})") from None
    doc = pymupdf.open(stream=data, filetype="pdf")
    try:
        md = pymupdf4llm.to_markdown(doc, show_progress=False)
        return ParseResult(md, "pymupdf4llm", {"pages": doc.page_count})
    finally:
        doc.close()


def _parse_pdf_plain(data: bytes, name: str | None, policy: IngestPolicy) -> ParseResult:
    """The same extraction with none of pymupdf4llm's transitive weight.

    Kept as a named parser rather than a fallback, so a deployment that cannot
    afford onnxruntime writes `parser: pymupdf` and gets a documented,
    reproducible downgrade instead of a different answer depending on what
    happened to be installed.
    """
    try:
        import pymupdf
    except ModuleNotFoundError as e:
        raise MissingParser(
            f"the pymupdf parser needs pymupdf (missing {e.name})") from None
    doc = pymupdf.open(stream=data, filetype="pdf")
    try:
        pages = [page.get_text("text") for page in doc]
        return ParseResult("\n\n".join(pages), "pymupdf", {"pages": doc.page_count})
    finally:
        doc.close()


def _docx_table(table: Any) -> str:
    rows = [[c.text.strip().replace("|", "\\|") for c in r.cells] for r in table.rows]
    if not rows:
        return ""
    width = max(len(r) for r in rows)
    rows = [r + [""] * (width - len(r)) for r in rows]
    head, *body = rows
    lines = ["| " + " | ".join(head) + " |",
             "| " + " | ".join("---" for _ in head) + " |"]
    lines += ["| " + " | ".join(r) + " |" for r in body]
    return "\n".join(lines)


def _parse_docx(data: bytes, name: str | None, policy: IngestPolicy) -> ParseResult:
    """Headings, paragraphs, lists and tables. In document order.

    IN DOCUMENT ORDER is the part worth the code: python-docx exposes
    `paragraphs` and `tables` as two flat lists, and the obvious loop --
    every paragraph, then every table -- moves each table to the end of the
    document. A table's meaning is entirely positional, so that is not a
    formatting imperfection; it is the numbers ending up under the wrong
    heading, in a chunk that reads as if they belonged there.
    """
    try:
        import docx
        from docx.table import Table
        from docx.text.paragraph import Paragraph
    except ModuleNotFoundError as e:
        raise MissingParser(
            "the docx parser needs python-docx: pip install 'percolate-core[ingest]' "
            f"(missing {e.name})") from None

    document = docx.Document(io.BytesIO(data))
    parts: list[str] = []
    tables = 0
    for child in document.element.body.iterchildren():
        tag = child.tag.rsplit("}", 1)[-1]
        if tag == "p":
            para = Paragraph(child, document)
            text = para.text.strip()
            if not text:
                continue
            style = (para.style.name or "").lower()
            if style.startswith("heading"):
                level = "".join(ch for ch in style if ch.isdigit()) or "1"
                parts.append("#" * min(int(level), 6) + " " + text)
            elif "list" in style:
                parts.append("- " + text)
            else:
                parts.append(text)
        elif tag == "tbl":
            rendered = _docx_table(Table(child, document))
            if rendered:
                tables += 1
                parts.append(rendered)
    return ParseResult("\n\n".join(parts), "docx", {"tables": tables})


def _parse_transcribe(data: bytes, name: str | None, policy: IngestPolicy) -> ParseResult:
    from .transcribe import transcribe

    text, detail = transcribe(data, name or "audio.wav", policy.transcribe)
    return ParseResult(text, "transcribe", detail)


PARSERS = {
    "markdown":    _parse_markdown,
    "text":        _parse_text,
    "html":        _parse_html,
    "pymupdf4llm": _parse_pdf_rich,
    "pymupdf":     _parse_pdf_plain,
    "docx":        _parse_docx,
    "transcribe":  _parse_transcribe,
}


def to_markdown(data: bytes, policy: IngestPolicy, name: str | None = None) -> ParseResult:
    parser = policy.parser
    if parser not in PARSERS:
        raise MissingParser(
            f"no parser named {parser!r} -- this deployment has "
            f"{', '.join(sorted(PARSERS))}")
    result = PARSERS[parser](data, name, policy)
    result.markdown = re.sub(r"\n{3,}", "\n\n", result.markdown or "").strip()

    # A parse that yields nothing is the failure this collection keeps finding:
    # the step succeeds, record_ingest writes zero chunks, the resource goes
    # 'stored', and the file is silently absent from every search anyone runs.
    # Raised instead, naming the most likely cause for this parser.
    if len(result.markdown) < 16:
        why = ("a scanned PDF has no text layer, and nothing here does OCR"
               if parser.startswith("pymupdf")
               else "the file may be empty, or not the format its content type claims")
        raise EmptyParse(
            f"{parser} read {len(data)} bytes and produced "
            f"{len(result.markdown)} characters of text -- {why}")
    return result
