# POST /admin/content/upload

## Overview
Uploads a file to S3 storage and optionally indexes it as a resource. Files are organized under `task_id` folders.

## Requirements

### Authentication
- Header: `Authorization: Bearer <token>`
- Dependency: `get_current_token`

### Request
- Content-Type: `multipart/form-data`
- Form parameters:
  - `file` (UploadFile, required): The file to upload.
  - `task_id` (string, optional): Session/thread ID. Defaults to `"default"`.
  - `add_resource` (boolean, optional, default: `true`): Whether to index the file as a resource.
  - `user_id` (string, optional): Identifier of the user.
  - `device_info` (string, optional): Base64-encoded JSON string with device metadata.

### Processing Steps
1. Decode `device_info` via `try_parse_base64_dict()`.
2. Define background task `index_resource(file_upload_result)`:
   - Extract `uri` from upload result.
   - Determine session via `Session.daily_diary_entry` or `Session.task_thread_entry`.
   - Persist session via `p8.repository(Session).update_records()`.
   - Generate resources via `Resources.chunked_resource(uri, userid=user_id)`.
   - Create `SessionResources` linking head resource ID to session ID and chunk count.
   - Persist resources and session-resources via repository.
3. Upload file:
   - Use `S3Service.upload_file(project_name=task_id, file_name, file_content, content_type, fetch_presigned_url=True)`.
   - If `add_resource` is true, enqueue `index_resource` in background tasks.
   - Log successful upload.
4. Return upload metadata.

### Response
- HTTP 200
- Body:
```json
{
  "key": "<s3-key>",
  "filename": "<original filename>",
  "task_id": "<session id>",
  "size": <bytes>,
  "content_type": "<mime-type>",
  "last_modified": <timestamp>,
  "etag": "<s3-etag>",
  "message": "Uploaded successfully to S3"
}
```

### Errors
- 400 Bad Request: Missing file.
- 401 Unauthorized: Missing/invalid token.
- 500 Internal Server Error: Upload or indexing failure.

### Dependencies
- FastAPI `File`, `UploadFile`, `BackgroundTasks`
- `S3Service`
- Pydantic models: `Resources`, `Session`, `SessionResources`
- Utility: `try_parse_base64_dict`
- Repository: `p8.repository`