"""
Example client functions for testing the admin content endpoints.
Requires the `requests` library: pip install requests
"""
import os
import requests
from percolate.utils import make_uuid
import json
import base64

# Base URL for Percolate API (override via environment)
BASE_URL = "http://127.0.0.1:5008"
# Retrieve test bearer token from environment
TOKEN = os.environ.get("P8_TEST_BEARER_TOKEN")
if not TOKEN:
    raise EnvironmentError("Environment variable P8_TEST_BEARER_TOKEN is not set.")

HEADERS = {"Authorization": f"Bearer {TOKEN}"}

device_info = base64.b64encode(json.dumps({'test':'device'}).encode('utf-8'))

def upload_uri_example(
    uri: str,
    description: str = "Sample bookmark for testing.",
    title: str = "Sample Bookmark",
    user_id: str = make_uuid('amartey@gmail.com'),
    device_info: str = device_info,
    is_public_resource: bool = True,
    expand_resource: bool = True,
    task_id: str = None,
):
    """
    Test the POST /admin/content/bookmark endpoint.

    Args:
        uri: URL to bookmark.
        description: Optional description or summary.
        title: Optional title of the resource.
        user_id: Optional user identifier (sent as query param).
        device_info: Optional base64-encoded JSON device metadata (query param).
        is_public_resource: Whether resource is public (query param).
        expand_resource: Whether to chunk the resource (query param).
        task_id: Optional session/thread ID (query param).
    """
    """
    Construct query parameters for optional args, send JSON body for URI data.
    """
    url = f"{BASE_URL}/admin/content/bookmark"
    headers = {**HEADERS, "Content-Type": "application/json"}
    # Body only contains URI and optional descriptive fields
    payload = {
        "uri": uri,
        "description": description,
        "title": title,
    }
    # Query params for session and metadata
    params = {}
    if user_id is not None:
        params['user_id'] = user_id
    if task_id is not None:
        params['task_id'] = task_id
    if device_info is not None:
        params['device_info'] = device_info
    params['is_public_resource'] = str(is_public_resource).lower()
    params['expand_resource'] = str(expand_resource).lower()
    # Send request
    response = requests.post(url, headers=headers, params=params, json=payload)
    # Debug info
    print("URL:", response.request.url)
    print("Request JSON:", payload)
    print("Query params:", params)
    print("Status code:", response.status_code)
    try:
        print("Response JSON:", response.json())
    except ValueError:
        print("Response text:", response.text)
    return response

def upload_file_example(
    file_path: str,
    task_id: str = None,
    add_resource: bool = True,
    user_id: str = make_uuid('amartey@gmail.com'),
    device_info: str = device_info,
):
    """
    Test the POST /admin/content/upload endpoint.

    Args:
        file_path: Path to local file to upload.
        task_id: Session/task identifier.
        add_resource: Whether to index the file as a resource.
        user_id: Optional user identifier.
        device_info: Optional base64 device info string.
    """
    url = f"{BASE_URL}/admin/content/upload"
    headers = HEADERS.copy()
    

    # 'requests' sets appropriate multipart/form-data headers
    with open(file_path, "rb") as f:
        files = {"file": (os.path.basename(file_path), f)}
        data = {
            "task_id": task_id,
            "add_resource": str(add_resource).lower(),
            "user_id": user_id or None,
            "device_info": device_info or None,
        }
        response = requests.post(url, headers=headers, files=files,  params=data)
    print("Uploaded file:", file_path)
    print("Request data:", data)
    print("Status code:", response.status_code)
    try:
        print("Response JSON:", response.json())
    except ValueError:
        print("Response text:", response.text)
    return response

if __name__ == "__main__":
    # Example URI bookmark
    upload_uri_example("https://example.com")
    # Example file upload: adjust sample.txt path if necessary
    sample_file = os.path.join(os.path.dirname(__file__), "sample.txt")
    if os.path.exists(sample_file):
        upload_file_example(sample_file)
    else:
        print(f"Sample file not found at {sample_file}, skipping file upload example.")