"""
You need an access token to test this
one way is to use the auth/google/login to save the access token

TOKEN_PATH = Path.home() / '.percolate' / 'auth' / 'google' /  'token'
import json

with open(TOKEN_PATH, 'r') as f:
    d = json.load(f)

test_token(d['access_token'])
#etc.
"""

import requests
from percolate.utils import logger

GOOGLE_DRIVE_API = "https://www.googleapis.com/drive/v3"
GOOGLE_DOCS_API = "https://docs.googleapis.com/v1"

def test_token(access_token):
    """sanity check function depending on what we want to do with the token"""
    
    headers = {"Authorization": f"Bearer {access_token}"}
    
    user_response = requests.get("https://www.googleapis.com/oauth2/v2/userinfo", headers=headers)
    logger.info(f"User info status: {user_response.status_code}")
    logger.info(f"User info response: {user_response.text}")
 
    drive_response = requests.get(f"{GOOGLE_DRIVE_API}/about?fields=user", headers=headers)
    logger.info(f"Drive API status: {drive_response.status_code}")
    logger.info(f"Drive API response: {drive_response.text}")
    
def list_google_docs_files(access_token):
    """
    List Google Docs files in the user's Drive.
    """
    headers = {
        "Authorization": f"Bearer {access_token}"
    }
    params = {
        "q": "mimeType='application/vnd.google-apps.document'",
        "fields": "files(id, name)",
        "spaces": "drive",
        "corpora": "user"  # This specifies we're only looking at the user's files
    }
    response = requests.get(f"{GOOGLE_DRIVE_API}/files", headers=headers, params=params)
    response.raise_for_status()
    return response.json().get("files", [])

def fetch_google_doc(access_token, file_id):
    """
    Fetch the contents of a Google Doc using the Docs API.
    """
    headers = {
        "Authorization": f"Bearer {access_token}"
    }

    response = requests.get(f"{GOOGLE_DOCS_API}/documents/{file_id}", headers=headers)
    response.raise_for_status()
    return response.json()

def google_doc_to_markdown(doc):
    """
    Convert the Google Doc JSON into a more comprehensive Markdown format.
    """
    markdown = []
    
    for element in doc.get("body", {}).get("content", []):
        # Handle paragraphs
        if "paragraph" in element:
            para = element["paragraph"]
            para_style = para.get("paragraphStyle", {})
            para_type = para_style.get("namedStyleType", "")
            
            # Check if it's a list item
            bullet = para.get("bullet")
            if bullet:
                list_type = bullet.get("listProperties", {}).get("nestingLevel", 0)
                is_ordered = bullet.get("listId") and "glistvnpm" in bullet.get("listId", "")
                indent = "  " * list_type
                marker = "1. " if is_ordered else "* "
                prefix = indent + marker
            else:
                prefix = ""
            
            # Process the text with formatting
            text_parts = []
            for el in para.get("elements", []):
                run = el.get("textRun")
                if run:
                    content = run.get("content", "")
                    if not content.strip():  # Keep empty lines/spaces
                        text_parts.append(content)
                        continue
                        
                    style = run.get("textStyle", {})
                    formatted_text = content
                    
                    # Apply formatting (preserving nested formatting)
                    if style.get("bold") and style.get("italic"):
                        formatted_text = f"***{content}***"
                    elif style.get("bold"):
                        formatted_text = f"**{content}**"
                    elif style.get("italic"):
                        formatted_text = f"*{content}*"
                    
                    # Handle links
                    if style.get("link"):
                        url = style.get("link").get("url", "")
                        formatted_text = f"[{formatted_text}]({url})"
                        
                    text_parts.append(formatted_text)
            
            text = "".join(text_parts)
            
            # Apply heading formatting after combining text
            if para_type.startswith("HEADING_"):
                try:
                    level = int(para_type[-1])
                    text = f"{'#' * level} {text}"
                except ValueError:
                    # Fallback in case of unexpected format
                    text = f"## {text}"
            
            # Add the prefix for lists
            if prefix:
                text = prefix + text
                
            markdown.append(text)
            
        # Handle tables (basic conversion)
        elif "table" in element:
            table = element["table"]
            markdown.append("\n")  # Space before table
            
            for row in table.get("tableRows", []):
                row_cells = []
                for cell in row.get("tableCells", []):
                    # Extract text from cell content
                    cell_text = []
                    for cell_content in cell.get("content", []):
                        if "paragraph" in cell_content:
                            cell_para = cell_content["paragraph"]
                            para_text = []
                            for text_element in cell_para.get("elements", []):
                                run = text_element.get("textRun")
                                if run:
                                    para_text.append(run.get("content", "").replace("\n", " "))
                            cell_text.append("".join(para_text).strip())
                    row_cells.append(" ".join(cell_text))
                
                markdown.append("| " + " | ".join(row_cells) + " |")
                
                # Add header separator after first row
                if row == table.get("tableRows", [])[0]:
                    markdown.append("| " + " | ".join(["---"] * len(row_cells)) + " |")
        
        # Handle horizontal line
        elif "horizontalRule" in element:
            markdown.append("\n---\n")
            
    return "\n".join(markdown)