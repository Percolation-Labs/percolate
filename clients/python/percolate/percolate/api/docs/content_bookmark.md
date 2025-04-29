# POST /admin/content/bookmark

## Overview
The `/admin/content/bookmark` endpoint allows users to bookmark external URIs as resources within the system. Bookmarks are linked to user sessions (daily diary or task threads) and processed asynchronously.

## Requirements

### Authentication
- Header: `Authorization: Bearer <token>`
- Dependency: `get_current_token`

### Request
- Content-Type: `application/json`
- Body parameters:
  - `uri` or `url` (string, required): The resource URI to bookmark.
  - `description` or `summary` or `content` (string, optional): Textual summary of the URI.
  - `title` or `name` (string, optional): Title of the resource.
  - `task_id` (string, optional): Session/thread ID. If omitted, a new daily diary session is created.
  - `user_id` (string, optional): Identifier of the user.
  - `device_info` (string, optional): Base64-encoded JSON string with device metadata.
  - `is_public_resource` (boolean, optional, default: `true`): Whether the resource is public or owned.
  - `expand_resource` (boolean, optional, default: `false`): Whether to chunk the resource into sub-resources.

### Processing Steps
1. Validate and parse inputs:
   - Extract `uri` from `uri` or `url`.
   - Extract `intent` from `description`/`summary`/`content`.
   - Extract `resource_title` from `title`/`name`.
   - Decode `device_info` into metadata dict via `try_parse_base64_dict`.
2. Session management:
   - No `task_id`: call `Session.daily_diary_entry(user_id, query=uri, metadata=device_info)`.
   - With `task_id`: call `Session.task_thread_entry(thread_id=task_id, userid=user_id, query=uri, metadata=device_info)`.
   - Persist session via `p8.repository(Session).update_records()`.
3. Background task `index_resources`:
   - Upsert `Resources` object (`name`, `summary`, `uri`, `userid`).
   - If `expand_resource` is true: call `Resources.chunked_resource(uri, name=resource_title, userid=...)`.
   - Create `SessionResources` linking head resource ID to session ID with chunk count.
   - Persist resources and session-resources via repository.
4. Add `index_resources` to FastAPI `BackgroundTasks`.
5. Respond immediately.

### Response
- HTTP 200
- Body:
```json
{ "status": "received uri https://example.com" }
```

### Errors
- 401 Unauthorized: Missing/invalid token.
- 500 Internal Server Error: Unexpected failures.

### Dependencies
- FastAPI `BackgroundTasks`
- Pydantic models: `Resources`, `Session`, `SessionResources`
- Utility: `try_parse_base64_dict`
- Repository: `p8.repository`