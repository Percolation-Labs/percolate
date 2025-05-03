import re
from typing import Iterator, List, Dict, Tuple

from pydantic import BaseModel


class MarkdownChunk(BaseModel):
    """A markdown chunk with its ordinal, section ordinal, heading path, and level."""
    ordinal: int               # global chunk sequence number
    section_ordinal: int       # sibling chunk index within this heading path
    path: List[str]            # list of heading titles from level 1 up to current
    level: int                 # depth level, equal to len(path)
    content: str               # the markdown content of this chunk

    def to_markdown(self):
        t = f""
        for i, h in enumerate(self.path):
            t+= f"{'#' * (i+1)} {h}\n\n"
        t+= self.content
        return t + "\n\n"
    
    def __repr__(self):
        return self.to_markdown()

_HEADING_PATTERN = re.compile(r'^(?P<hashes>#{1,4})\s*(?P<title>.*)$')


def iter_markdown_chunks(
    markdown_text: str,
    separator: str = "\n\n"
) -> Iterator[MarkdownChunk]:
    """
    Iterate over markdown content, yield leaf chunks under headings up to level 4.

    Each chunk contains:
      - ordinal: global sequence number starting at 1
      - section_ordinal: the chunk's index among siblings in its heading path
      - path: list of heading titles from the root down to current
      - level: depth = len(path)
      - content: the markdown text block
    Content before any heading has an empty path and level=0.
    Chunks are text segments split by the given separator (default double newline).
    """
    if isinstance(markdown_text,list):
        markdown_text = f"\n".join([str(s) for s in markdown_text])
    
    lines = markdown_text.splitlines(keepends=True)
    path: List[str] = []
    section_lines: List[str] = []
    global_ord = 1
    section_counters: Dict[Tuple[str, ...], int] = {}

    def flush_section(p: List[str], lines_block: List[str]) -> Iterator[MarkdownChunk]:
        nonlocal global_ord
        key = tuple(p)
        section_counters.setdefault(key, 1)
        text = ''.join(lines_block)
        for part in text.split(separator):
            if not part or not part.strip():
                continue
            sec_ord = section_counters[key]
            yield MarkdownChunk(
                ordinal=global_ord,
                section_ordinal=sec_ord,
                path=list(p),
                level=len(p),
                content=part.strip()
            )
            global_ord += 1
            section_counters[key] += 1

    for line in lines:
        m = _HEADING_PATTERN.match(line)
        if m:
            # flush content accumulated under previous heading path
            yield from flush_section(path, section_lines)
            # update path to new heading
            level = len(m.group('hashes'))
            title = m.group('title').strip()
            # truncate old path to parent of this level
            path = path[: level - 1]
            path.append(title)
            # reset content lines
            section_lines = []
        else:
            section_lines.append(line)

    # flush final section
    yield from flush_section(path, section_lines)
    
def get_pdf_markdown_elements(uri):
    def convert_elements_to_markdown(elements):
        from unstructured.documents.elements import Title, NarrativeText, ListItem, Table
        markdown_lines = []
        heading_level = 1  # Start with H1 for the first title
        previous_element = None

        for element in elements:
            if isinstance(element, Title):
                # Infer heading level based on sequence
                if isinstance(previous_element, Title):
                    heading_level += 1
                else:
                    heading_level = 1  # Reset to H1 if previous wasn't a title
                heading_level = min(heading_level, 6)  # Cap at H6
                markdown_lines.append(f"{'#' * heading_level} {element.text}")
            elif isinstance(element, NarrativeText):
                markdown_lines.append(element.text)
            elif isinstance(element, ListItem):
                markdown_lines.append(f"- {element.text}")
            elif isinstance(element, Table):
                markdown_lines.append("<!-- Table omitted -->")
            else:
                markdown_lines.append(element.text)
            previous_element = element

        return "\n\n".join(markdown_lines)
    
    try:
        from unstructured.partition.pdf import partition_pdf
        elements =  partition_pdf(filename=uri)
        if not elements:
            """poor fallback"""
            from .content_providers import PDFContentProvider
            """TODO"""
            #return PDFContentProvider().extract_text_elements()
        return list(iter_markdown_chunks(convert_elements_to_markdown(elements)))
    except ImportError:
        print("`unstructured` is not installed. Falling back...")
    except Exception as e:
        raise
