import json 
import re
import os
import base64
from pathlib import Path
from typing import Optional

def extract_and_replace_base64_images(markdown_text: str, output_dir: str = "images", url_prefix: Optional[str] = None, write_file:bool=False) -> str:
    """
    Extracts base64 images from markdown, saves them to output_dir unless write file is False - S3 paths should be used
    and replaces the base64 data with links to the saved images.

    Args:
        markdown_text (str): The input markdown text.
        output_dir (str): Directory to save images into.
        url_prefix (Optional[str]): URL prefix to use in the replaced markdown. 
                                    If None, uses relative paths.

    Returns:
        str: The updated markdown text.
    """
    
    Path(output_dir).mkdir(parents=True, exist_ok=True)
    pattern = r'!\[.*?\]\(data:image\/([a-zA-Z]+);base64,([^)]*)\)'

    def replace_func(match):
        image_format = match.group(1).lower()  # e.g., png, jpeg
        base64_data = match.group(2)

        idx = replace_func.counter
        filename = f"image_{idx}.{image_format}"
        file_path = Path(output_dir) / filename
        replace_func.counter += 1

        if write_file:
            with open(file_path, "wb") as f:
                f.write(base64.b64decode(base64_data))

        if url_prefix:
            image_link = f"{url_prefix}/{filename}"
        else:
            image_link = f"{output_dir}/{filename}"

        return f"![]({image_link})"

    replace_func.counter = 1

    updated_markdown = re.sub(pattern, replace_func, markdown_text)

    return updated_markdown

def parse_fenced_code_blocks(
    input_string, try_parse=True, select_type="json", first=True, on_error=None
):
    """
    extract code from fenced blocks - will try to parse into python dicts if option set
    json is assumed
    """
    try:
        input_string = input_string.replace("\n", "")
        pattern = r"```(.*?)```|~~~(.*?)~~~"
        matches = re.finditer(pattern, input_string, re.DOTALL)
        code_blocks = []
        for match in matches:
            code_block = match.group(1) if match.group(1) else match.group(2)
            # print(code_block)
            if code_block[: len(select_type)] == select_type:
                code_block = code_block[len(select_type) :]
                code_block.strip()
                if try_parse and select_type == "json":
                    code_block = json.loads(code_block)
                code_blocks.append(code_block)
        return code_blocks if not first and len(code_blocks) > 1 else code_blocks[0]
    except:
        if on_error:
            raise
        # raise
        # FAIL SILENT
        return [] if not first else {}
    
    
def json_loads(s):
    try:
        return json.loads(s)
    except:
        return parse_fenced_code_blocks(s)
    raise Exception(f"Cannot parse the string as json or fenced json")

from .providers import get_content_provider_for_uri