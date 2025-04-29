"""
Some utils for reading files from drive as markdown



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
import fitz   
import io
import re
from percolate.utils.parsing import extract_and_replace_base64_images

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

def list_all_google_drive_folders(access_token):
    """
    List all folders in the user's Google Drive, handling pagination.
    """
    headers = {
        "Authorization": f"Bearer {access_token}"
    }
    
    all_folders = []
    page_token = None
    
    while True:
        params = {
            "q": "mimeType='application/vnd.google-apps.folder'",
            "fields": "nextPageToken, files(id, name)",
            "spaces": "drive",
            "corpora": "user",
            "pageSize": 100  # Maximum allowed by the API
        }
        
        if page_token:
            params["pageToken"] = page_token
            
        response = requests.get(f"{GOOGLE_DRIVE_API}/files", headers=headers, params=params)
        response.raise_for_status()
        
        result = response.json()
        folders = result.get("files", [])
        all_folders.extend(folders)
        
        page_token = result.get("nextPageToken")
        if not page_token:
            break
            
    return all_folders

def list_all_shared_drives(access_token):
    """
    List all shared drives that the user has access to, handling pagination.
    """
    headers = {
        "Authorization": f"Bearer {access_token}"
    }
    
    all_drives = []
    page_token = None
    
    while True:
        params = {
            "fields": "nextPageToken, drives(id, name)",
            "pageSize": 100  # Maximum allowed by the API
        }
        
        if page_token:
            params["pageToken"] = page_token
            
        response = requests.get(f"{GOOGLE_DRIVE_API}/drives", headers=headers, params=params)
        response.raise_for_status()
        
        result = response.json()
        drives = result.get("drives", [])
        all_drives.extend(drives)
        
        page_token = result.get("nextPageToken")
        if not page_token:
            break
            
    return all_drives

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


def list_files_in_folder(access_token, folder_id='root', recursive=True):
    """
    List all files in a specific folder, with option to list recursively through subfolders.
    
    Args:
        access_token: OAuth2 access token
        folder_id: ID of the folder to list files from (default is 'root')
        recursive: Whether to list files in subfolders recursively
        
    Returns:
        List of file objects with id, name, mimeType, and parents
    """
    headers = {
        "Authorization": f"Bearer {access_token}"
    }
    
    all_files = []
    page_token = None
    
    # Query to find all files in the specified folder
    query = f"'{folder_id}' in parents and trashed = false"
    
    while True:
        params = {
            "q": query,
            "fields": "nextPageToken, files(id, name, mimeType, parents)",
            "spaces": "drive",
            "pageSize": 100
        }
        
        if page_token:
            params["pageToken"] = page_token
            
        response = requests.get(f"{GOOGLE_DRIVE_API}/files", headers=headers, params=params)
        response.raise_for_status()
        
        result = response.json()
        files = result.get("files", [])
        
        # Add all files to our result list
        all_files.extend(files)
        
        # If recursive is enabled, check for subfolders and process them
        if recursive:
            subfolders = [f for f in files if f.get("mimeType") == "application/vnd.google-apps.folder"]
            for subfolder in subfolders:
                # Recursively get files from subfolders
                subfolder_files = list_files_in_folder(access_token, subfolder.get("id"), recursive)
                all_files.extend(subfolder_files)
        
        page_token = result.get("nextPageToken")
        if not page_token:
            break
            
    return all_files


def list_files_in_drive(access_token, drive_id, recursive=True):
    """
    List all files in a specific shared drive, with option to list recursively.
    
    Args:
        access_token: OAuth2 access token
        drive_id: ID of the shared drive
        recursive: Whether to list files in subfolders recursively
        
    Returns:
        List of file objects with id, name, mimeType, and parents
    """
    headers = {
        "Authorization": f"Bearer {access_token}"
    }
    
    all_files = []
    page_token = None
    
    # Important: For shared drives we need to include the driveId parameter
    params = {
        "q": "trashed = false",
        "fields": "nextPageToken, files(id, name, mimeType, parents)",
        "spaces": "drive",
        "pageSize": 100,
        "driveId": drive_id,
        "includeItemsFromAllDrives": True,
        "supportsAllDrives": True,
        "corpora": "drive"
    }
    
    while True:
        if page_token:
            params["pageToken"] = page_token
            
        response = requests.get(f"{GOOGLE_DRIVE_API}/files", headers=headers, params=params)
        response.raise_for_status()
        
        result = response.json()
        files = result.get("files", [])
        all_files.extend(files)
        
        page_token = result.get("nextPageToken")
        if not page_token:
            break
            
    return all_files


def list_all_drive_files_flat(access_token, whitelist_folders=None):
    """
    List all files across Google Drive with full metadata in a flat structure.
    Each record contains both the file information and its drive information.
    
    Args:
        access_token: OAuth2 access token
        whitelist_folders: Optional list of folder names to include (if None, include all folders)
        
    Returns:
        List of dictionaries, each containing file info and its associated drive info
    """
 
    my_drive_info = {
        "drive_id": "root",
        "drive_name": "My Drive",
        "drive_type": "my_drive"
    }
    
    my_drive_files = _get_all_files_in_drive(
        access_token, 
        drive_id="root", 
        is_my_drive=True, 
        whitelist_folders=whitelist_folders
    )
    
    for file in my_drive_files:
        record = {
            **my_drive_info,
            "file_id": file.get("id"),
            "file_name": file.get("name"),
            "mime_type": file.get("mimeType"),
            **{f"{k}": file.get(k) for k in ["parents", "createdTime", "modifiedTime", "size", 
                                           "md5Checksum", "webViewLink", "iconLink", "owners", 
                                           "shared", "sharingUser", "ownedByMe", "capabilities"] 
               if k in file}
        }
        yield record
    
    for drive in list_all_shared_drives(access_token):
        drive_info = {
            "drive_id": drive.get("id"),
            "drive_name": drive.get("name"),
            "drive_type": "shared_drive"
        }
        
        drive_files = _get_all_files_in_drive(
            access_token, 
            drive_id=drive.get("id"), 
            is_my_drive=False,
            whitelist_folders=whitelist_folders
        )
        
        for file in drive_files:
            record = {
                **drive_info,
                "file_id": file.get("id"),
                "file_name": file.get("name"),
                "mime_type": file.get("mimeType"),
                **{f"{k}": file.get(k) for k in ["parents", "createdTime", "modifiedTime", "size", 
                                               "md5Checksum", "webViewLink", "iconLink", "owners", 
                                               "shared", "sharingUser", "ownedByMe", "capabilities"] 
                   if k in file}
            }
            yield record
    
def list_files_as_chunked_resources(access_token, whitelist_folders=None):
    """
    For testing we can get a batch of resources but we should use a sync process to sync files to percolate
    """
    from percolate.models import Resources
    
    for f in list_all_drive_files_flat(access_token=access_token,whitelist_folders=whitelist_folders):
        name, data = read_doc_as_text(access_token,f)
        #temp
        if 'Chat Log' in name:
            continue
        if 'Google Doc' not in name:
            continue
        print(name)
        if data:
            for chunk in Resources.chunked_resource_from_text(text=data, name=name, uri=f['webViewLink'] ):
                yield chunk        
        
    
def _get_all_files_in_drive(access_token, drive_id, is_my_drive=True, whitelist_folders=None):
    """
    Get all files in a drive with comprehensive metadata.
    
    Args:
        access_token: OAuth2 access token
        drive_id: ID of the drive
        is_my_drive: Whether this is My Drive (True) or a Shared Drive (False)
        whitelist_folders: Optional list of folder names to include
        
    Returns:
        List of file objects with extensive metadata
    """
    headers = {
        "Authorization": f"Bearer {access_token}"
    }
    
    all_files = []
    page_token = None
    
    # Prepare folder info if whitelist provided
    folder_info = None
    if whitelist_folders:
        folder_info = _get_folder_info(access_token, drive_id, is_my_drive)
    
    # Build query parameters based on whether it's My Drive or Shared Drive
    base_params = {
        "fields": "nextPageToken, files(id, name, mimeType, parents, createdTime, modifiedTime, size, md5Checksum, webViewLink, iconLink, owners, shared, sharingUser, ownedByMe, capabilities)",
        "pageSize": 100,
        "q": "trashed = false"
    }
    
    # For shared drives, we need additional parameters
    if not is_my_drive:
        base_params.update({
            "driveId": drive_id,
            "includeItemsFromAllDrives": True,
            "supportsAllDrives": True,
            "corpora": "drive"
        })
    
    while True:
        params = base_params.copy()
        
        if page_token:
            params["pageToken"] = page_token
            
        response = requests.get(f"{GOOGLE_DRIVE_API}/files", headers=headers, params=params)
        response.raise_for_status()
        
        result = response.json()
        files = result.get("files", [])
        
        # If we have a whitelist, filter files based on their parent folders
        if whitelist_folders and folder_info:
            for file in files:
                parent_ids = file.get("parents", [])
                should_include = False
                
                for parent_id in parent_ids:
                    if parent_id in folder_info:
                        folder_path = _get_folder_path(folder_info, parent_id)
                        for whitelisted in whitelist_folders:
                            if whitelisted in folder_path.split('/'):
                                should_include = True
                                break
                
                if should_include:
                    all_files.append(file)
        else:
            # If no whitelist, include all files
            all_files.extend(files)
        
        page_token = result.get("nextPageToken")
        if not page_token:
            break
            
    return all_files

def _get_files_generator(access_token, drive_id, is_my_drive=True, whitelist_folders=None):
    """
    Generator function to get files in a drive one page at a time.
    
    Args:
        access_token: OAuth2 access token
        drive_id: ID of the drive
        is_my_drive: Whether this is My Drive (True) or a Shared Drive (False)
        whitelist_folders: List of folder names to include
        
    Yields:
        File objects one at a time
    """
    headers = {
        "Authorization": f"Bearer {access_token}"
    }
    
    page_token = None
    folder_info = None
    
    # Get folder info if whitelist is provided (only once)
    if whitelist_folders:
        folder_info = _get_folder_info(access_token, drive_id, is_my_drive)
    
    # Build the appropriate parameters
    base_params = {
        "fields": "nextPageToken, files(id, name, mimeType, parents, createdTime, modifiedTime, size, md5Checksum, webViewLink, iconLink, owners, shared, sharingUser, ownedByMe, capabilities)",
        "pageSize": 100,
        "q": "trashed = false"
    }
    
    if not is_my_drive:
        base_params.update({
            "driveId": drive_id,
            "includeItemsFromAllDrives": True,
            "supportsAllDrives": True,
            "corpora": "drive"
        })
    
    while True:
        params = base_params.copy()
        
        if page_token:
            params["pageToken"] = page_token
            
        response = requests.get(f"{GOOGLE_DRIVE_API}/files", headers=headers, params=params)
        response.raise_for_status()
        
        result = response.json()
        files = result.get("files", [])
        
        for file in files:
            # Filter based on whitelist if provided
            if whitelist_folders and folder_info:
                parent_ids = file.get("parents", [])
                should_include = False
                
                for parent_id in parent_ids:
                    if parent_id in folder_info:
                        folder_path = _get_folder_path(folder_info, parent_id)
                        for whitelisted in whitelist_folders:
                            if whitelisted in folder_path.split('/'):
                                should_include = True
                                break
                
                if should_include:
                    yield file
            else:
                # If no whitelist, yield all files
                yield file
        
        page_token = result.get("nextPageToken")
        if not page_token:
            break
        

def _get_folder_info(access_token, drive_id, is_my_drive=True):
    """
    Get information about all folders in a drive to build folder paths.
    
    Returns:
        Dictionary mapping folder IDs to their name and parent ID
    """
    headers = {
        "Authorization": f"Bearer {access_token}"
    }
    
    folders = {}
    page_token = None
    
    # Build query for folders only
    base_params = {
        "fields": "nextPageToken, files(id, name, parents)",
        "pageSize": 100,
        "q": "mimeType='application/vnd.google-apps.folder' and trashed = false"
    }
    
    if not is_my_drive:
        # For Shared Drives, add these parameters
        base_params.update({
            "driveId": drive_id,
            "includeItemsFromAllDrives": True,
            "supportsAllDrives": True,
            "corpora": "drive"
        })
    
    while True:
        params = base_params.copy()
        
        if page_token:
            params["pageToken"] = page_token
            
        response = requests.get(f"{GOOGLE_DRIVE_API}/files", headers=headers, params=params)
        response.raise_for_status()
        
        result = response.json()
        folder_list = result.get("files", [])
        
        for folder in folder_list:
            folders[folder.get("id")] = {
                "name": folder.get("name"),
                "parents": folder.get("parents", [])
            }
        
        page_token = result.get("nextPageToken")
        if not page_token:
            break
            
    return folders


def _get_folder_path(folder_info, folder_id, path=None):
    """
    Recursively build the full path of a folder.
    
    Args:
        folder_info: Dictionary mapping folder IDs to their information
        folder_id: ID of the folder to get the path for
        path: Current path being built
    
    Returns:
        String with the full path of the folder
    """
    if path is None:
        path = []
    
    if folder_id not in folder_info:
        return "/".join(reversed(path))
    
    current_folder = folder_info[folder_id]
    path.append(current_folder["name"])
    
    if not current_folder["parents"]:
        return "/".join(reversed(path))
    
    # Since a file/folder can have multiple parents in Google Drive,
    # we just take the first parent for simplicity
    parent_id = current_folder["parents"][0]
    return _get_folder_path(folder_info, parent_id, path)


"""Doc iterator"""




def read_doc_as_text(access_token, file_info):
    """
    Extract text content from various document types.
    
    Args:
        access_token: OAuth2 access token
        file_info: Dictionary containing file metadata (id, name, mimeType)
        
    Returns:
        Tuple of (title, text_content)
    """
    file_id = file_info.get("file_id")
    file_name = file_info.get("file_name", "Untitled")
    mime_type = file_info.get("mime_type", "")
    
    # Handle Google Docs
    if mime_type == "application/vnd.google-apps.document":
        return _extract_google_doc_text(access_token, file_id, file_name)
    
    # Handle PDFs
    elif mime_type == "application/pdf":
        return _extract_pdf_text(access_token, file_id, file_name)
    
    # Handle plain text files
    elif mime_type == "text/plain":
        return _extract_text_file(access_token, file_id, file_name)
    
    # Handle Microsoft Word documents
    elif mime_type in ["application/vnd.openxmlformats-officedocument.wordprocessingml.document", 
                       "application/msword"]:
        # For Word docs, we'll export to PDF then extract text
        return _extract_word_doc_text(access_token, file_id, file_name)
    
    # If unsupported file type, return empty content
    return file_name, None


def _extract_google_doc_text(access_token, file_id, file_name):
    """Extract text from Google Doc."""
    headers = {
        "Authorization": f"Bearer {access_token}"
    }
    
    # Fetch the document content
    response = requests.get(f"{GOOGLE_DOCS_API}/documents/{file_id}", headers=headers)
    response.raise_for_status()
    doc = response.json()
    
    # Convert to markdown using the existing function
    markdown_text = google_doc_to_markdown(doc)
    
    # Clean up the title for return
    title = f"{file_name}.md"
    
    return title, markdown_text


def _extract_pdf_text(access_token, file_id, file_name):
    """Extract text from PDF using PyMuPDF."""
    headers = {
        "Authorization": f"Bearer {access_token}"
    }
    
    # Download the PDF file
    response = requests.get(
        f"{GOOGLE_DRIVE_API}/files/{file_id}",
        headers=headers,
        params={"alt": "media"}
    )
    response.raise_for_status()
    
    # Create a file-like object from the response content
    pdf_stream = io.BytesIO(response.content)
    
    # Open the PDF with PyMuPDF
    try:
        doc = fitz.open(stream=pdf_stream, filetype="pdf")
        
        # Extract text from all pages
        text_content = []
        for page_num in range(len(doc)):
            page = doc[page_num]
            text_content.append(page.get_text())
        
        full_text = "\n\n".join(text_content)
        
        # Clean up the title for return
        title = file_name if file_name.lower().endswith(".pdf") else f"{file_name}.pdf"
        
        return title, full_text
    
    except Exception as e:
        return f"{file_name}.pdf", f"[Error extracting PDF text: {str(e)}]"
    finally:
        if 'doc' in locals():
            doc.close()


def _extract_text_file(access_token, file_id, file_name):
    """Extract text from plain text file."""
    headers = {
        "Authorization": f"Bearer {access_token}"
    }
    
    # Download the text file
    response = requests.get(
        f"{GOOGLE_DRIVE_API}/files/{file_id}",
        headers=headers,
        params={"alt": "media"}
    )
    response.raise_for_status()
    
    # Handle encoding - try to decode as UTF-8 first, fallback to latin-1
    try:
        text_content = response.content.decode('utf-8')
    except UnicodeDecodeError:
        text_content = response.content.decode('latin-1')
    
    # Clean up the title for return
    title = file_name if file_name.lower().endswith((".txt", ".md", ".html", ".csv")) else f"{file_name}.txt"
    
    return title, text_content

def docx_bytes_to_markdown(docx_bytes: bytes) -> str:
    """Convert a DOCX file (as bytes) to Markdown."""
    import mammoth, html2text, io

    with io.BytesIO(docx_bytes) as file_obj: 
        result = mammoth.convert_to_html(file_obj)
        html_content = result.value

 
    markdown = html2text.html2text(html_content)

    return markdown.strip()

def _extract_word_doc_text(access_token, file_id, file_name, replace_base_64_images:bool=True):
    """Extract text from Word doc by exporting to PDF first, then extracting text."""
    headers = {
        "Authorization": f"Bearer {access_token}"
    }
    
    # Export as PDF
    response = requests.get(
        f"{GOOGLE_DRIVE_API}/files/{file_id}/export",
        headers=headers,
        params={"mimeType": "application/pdf"}
    )
    
    # If export fails, try to download directly and process
    if response.status_code != 200:
        response = requests.get(
            f"{GOOGLE_DRIVE_API}/files/{file_id}",
            headers=headers,
            params={"alt": "media"}
        )
        response.raise_for_status()
        # Return the generated PDF
        md = docx_bytes_to_markdown(response.content)
        if replace_base_64_images:
            """todo: for now im not replacing the images with an accessible link"""
            md = extract_and_replace_base64_images(markdown_text=md)
        return f"{file_name}.md", md
        
    # Create a file-like object from the PDF response content
    pdf_stream = io.BytesIO(response.content)
    
    # Open the PDF with PyMuPDF
    try:
        doc = fitz.open(stream=pdf_stream, filetype="pdf")
        
        # Extract text from all pages
        text_content = []
        for page_num in range(len(doc)):
            page = doc[page_num]
            text_content.append(page.get_text())
        
        full_text = "\n\n".join(text_content)
        
        # Clean up the title for return
        base_name = re.sub(r'\.(docx|doc)$', '', file_name, flags=re.IGNORECASE)
        title = f"{base_name}.txt"
        
        return title, full_text
    
    except Exception as e:
        return f"{file_name}.txt", f"[Error extracting Word document text: {str(e)}]"
    finally:
        if 'doc' in locals():
            doc.close()

