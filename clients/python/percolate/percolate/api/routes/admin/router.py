# routers/drafts.py
from fastapi import APIRouter, HTTPException, BackgroundTasks
from fastapi import   Depends, Response
import json
import time
from percolate.services import MinioService, S3Service
from percolate.api.routes.auth import get_api_key, get_current_token
from pydantic import BaseModel, Field
import typing
import uuid
from percolate.services import PostgresService
from percolate.models.p8 import IndexAudit
from percolate.utils import logger
import traceback
from percolate.utils.studio import Project, apply_project
from fastapi import   Depends, File, UploadFile

router = APIRouter()

@router.post("/env/sync")
async def sync_env(user: dict = Depends(get_api_key)):
    """sync env adds whatever keys you have in your environment your database instance
    This is used on database setup or if keys are missing in database sessions
    """
    return Response(content=json.dumps({'status':'ok'}))


class AddApiRequest(BaseModel):
    uri: str = Field(description="Add the uri to the openapi.json for the API you want to add")
    token: typing.Optional[str] = Field(description="Add an optional bearer token or API key for API access")
    verbs: typing.Optional[str] = Field(description="A comma-separated list of verbs e.g. get,post to filter endpoints by when adding endpoints")
    endpoint_filter: typing.Optional[typing.List[str]] = Field(description="A list of endpoints to filter by when adding endpoints")
    
@router.post("/add/api")
async def add_api( add_request:AddApiRequest,  user: dict = Depends(get_api_key)):
    """add apis to Percolate
    """
    return Response(content=json.dumps({'status':'ok'}))

class AddAgentRequest(BaseModel):
    name: str = Field(description="A unique entity name, fully qualified by namespace or use 'public' as default" )
    functions: dict = Field(description="A mapping of function names in Percolate with a description of how the function is useful to you")
    spec: dict = Field(description="The Json spec of your agents structured response e.g. from a Pydantic model")
    description: str = Field(description="Your agent description - acts as a system prompt")
    
    
@router.post("/add/agent")
async def add_agent( add_request:AddAgentRequest,  user: dict = Depends(get_api_key)):
    """add agents to Percolate. Agents require a Json Schema for any structured response you want to use, a system prompt and a dict/mapping of external registered functions.
    Functions can be registered via the add APIs endpoint.
    """
    return Response(content=json.dumps({'status':'ok'}))

@router.post("/add/project")
async def add_project( project: Project,  user: dict = Depends(get_api_key)):
    """Post the project yaml/json file to apply the settings. This can be used to add apis, agents and models. 
    
    - If you have set environment keys in your API we will sync these to your database if the `sync-env` flag is set in the project options
    - If you want to index the Percolation documentation set the flag `index-docs`
    """
    results = apply_project(project)
    return Response(content=json.dumps(results))


@router.get("/slow-endpoint", include_in_schema=False)
async def slow_response(user: dict = Depends(get_current_token)):
    """a test utility"""
    import time
    time.sleep(10)  # Simulate a delay
    return {"message": "This response was delayed by 10 seconds"}



class IndexRequest(BaseModel):
    """a request to update the indexes for entities by full name"""
    entity_full_name: str = Field(description="The full entity name - optionally omit for public namespace")

 
@router.post("/index/", response_model=IndexAudit)
async def index_entity(request: IndexRequest, background_tasks: BackgroundTasks, user: dict = Depends(get_api_key))->IndexAudit:
    """index entity and get an audit log id to check status
    the index is created as a background tasks and we respond with an id ref that can be used in the get/
    """
    id=uuid.uuid1()
    s = PostgresService(IndexAudit)
    try:
        
        record = IndexAudit(id=id, model_name='percolate', entity_full_name=request.entity_full_name, metrics={}, status="REQUESTED", message="Indexed requested")
        s.update_records(record)
        """todo create an audit record pending and use that in the api response"""
        background_tasks.add_task(s.index_entity_by_name, request.entity_full_name, id=id)
        return record
    except Exception as e:
        """handle api errors"""
        logger.warning(f"/admin/index {traceback.format_exc()}")
        record = IndexAudit(id=id,model_name='percolate',entity_full_name=request.entity_full_name, metrics={}, status="ERROR", message=str(e))
        """log the error"""
        s.update_records(record)
        raise HTTPException(status_code=500, detail="Failed to manage the index")
    
@router.get("/index/{id}", response_model=IndexAudit)
async def get_index(id: uuid.UUID, user: dict = Depends(get_api_key)) -> IndexAudit:
    """
    request the status of the index by id
    """
    #todo - proper error handling
    records = PostgresService.get_by_id(id)
    if records:
        return records
    """TODO error not found"""
    return {}



@router.post("/content/bookmark")
async def upload_uri(request : dict, task_id: str = "default", add_resource: bool = True, user: dict = Depends(get_current_token)):
    """book mark uris the same way we upload file content"""

    """TODO""" 
       
    logger.info(f"{request=}")
       
    return Response(json.dumps({"status":'received'}))

@router.post("/content/upload")
async def upload_file(file: UploadFile = File(...), task_id: str = "default", add_resource: bool = True, user: dict = Depends(get_current_token)):
    """
    Uploads a file to S3 storage and optionally stores it as a file resource which is indexed.
    Files are stored under the task_id folder structure.
    
    Args:
        file: The file to upload
        task_id: The task ID to associate with the file, defaults to "default"
        add_resource: Whether to add the file as a database resource for content indexing
        user: The authenticated user (injected by dependency)
    
    Returns:
        JSON with the filename and status message
    """
 
    
    try:
        
        # Upload to S3 using put_object with bytes
        s3_service = S3Service()
        result = s3_service.upload_file(
            project_name=task_id,
            file_name=file.filename,
            file_content=file.file,
            content_type=file.content_type
        )
        
        # TODO: If add_resource is True, add file metadata to database for indexing
        
        logger.info(f"Uploaded file {result['key']} to S3 successfully")
        return {
            "key": result["key"],
            "filename": result["name"],
            "task_id": task_id,
            "size": result["size"],
            "content_type": result["content_type"],
            "last_modified": result["last_modified"],
            "etag": result["etag"],
            "message": "Uploaded successfully to S3"
        }
    except Exception as e:
        logger.error(f"File upload failed: {str(e)}")
        logger.warning(traceback.format_exc())
        raise HTTPException(status_code=500, detail=f"File upload failed: {str(e)}")

@router.get("/content/files")
async def list_files(task_id: str = "default", prefix: str = None, user: dict = Depends(get_current_token)):
    """
    Lists files stored in S3 under the specified task_id.
    
    Args:
        task_id: The task ID folder to list files from, defaults to "default"
        prefix: Additional prefix to filter files within the task_id folder
        user: The authenticated user (injected by dependency)
    
    Returns:
        JSON list of files with metadata
    """
    try:
        # List files from S3
        s3_service = S3Service()
        files = s3_service.list_files(
            project_name=task_id,
            prefix=prefix
        )
        
        return {
            "task_id": task_id,
            "files": files,
            "count": len(files)
        }
    except Exception as e:
        logger.error(f"Failed to list files: {str(e)}")
        logger.warning(traceback.format_exc())
        raise HTTPException(status_code=500, detail=f"Failed to list files: {str(e)}")

@router.get("/content/file/{task_id}/{filename:path}")
async def get_file(task_id: str, filename: str, prefix: str = None, user: dict = Depends(get_current_token)):
    """
    Retrieves a file from S3 storage.
    
    Args:
        task_id: The task ID/project name associated with the file
        filename: The filename to retrieve
        prefix: Optional subfolder within the task_id/project
        user: The authenticated user (injected by dependency)
    
    Returns:
        The file content as a response
    """
    try:
        # Get file from S3
        s3_service = S3Service()
        result = s3_service.download_file(
            project_name=task_id,
            file_name=filename,
            prefix=prefix
        )
        
        # Get content and content type from the result
        content = result["content"]
        content_type = result["content_type"]
        
        # Return the file content
        return Response(content=content, media_type=content_type)
    except Exception as e:
        logger.error(f"Failed to retrieve file {filename} from project {task_id}: {str(e)}")
        logger.warning(traceback.format_exc())
        raise HTTPException(status_code=404, detail=f"File not found or error retrieving: {str(e)}")

@router.delete("/content/file/{task_id}/{filename:path}")
async def delete_file(task_id: str, filename: str, prefix: str = None, user: dict = Depends(get_current_token)):
    """
    Deletes a file from S3 storage.
    
    Args:
        task_id: The task ID/project name associated with the file
        filename: The filename to delete
        prefix: Optional subfolder within the task_id/project
        user: The authenticated user (injected by dependency)
    
    Returns:
        JSON with deletion status
    """
    try:
        # Delete file from S3
        s3_service = S3Service()
        result = s3_service.delete_file(
            project_name=task_id,
            file_name=filename,
            prefix=prefix
        )
        
        # Return success response
        return {
            "key": result["key"],
            "filename": result["name"],
            "task_id": task_id,
            "message": "File deleted successfully",
            "status": result["status"]
        }
    except Exception as e:
        logger.error(f"Failed to delete file {filename} from project {task_id}: {str(e)}")
        logger.warning(traceback.format_exc())
        raise HTTPException(status_code=500, detail=f"File deletion failed: {str(e)}")

@router.get("/content/url/{task_id}/{filename:path}")
async def get_presigned_url(
    task_id: str, 
    filename: str, 
    operation: str = "get_object", 
    expires_in: int = 3600, 
    prefix: str = None, 
    user: dict = Depends(get_current_token)
):
    """
    Generates a presigned URL for direct access to a file in S3 storage.
    
    Args:
        task_id: The task ID/project name associated with the file
        filename: The filename to access
        operation: The S3 operation ('get_object', 'put_object', etc.)
        expires_in: URL expiration time in seconds (default: 1 hour)
        prefix: Optional subfolder within the task_id/project
        user: The authenticated user (injected by dependency)
    
    Returns:
        JSON with the presigned URL
    """
    try:
        # Generate presigned URL
        s3_service = S3Service()
        url = s3_service.get_presigned_url(
            project_name=task_id,
            file_name=filename,
            operation=operation,
            expires_in=expires_in,
            prefix=prefix
        )
        
        # Return the URL
        return {
            "url": url,
            "task_id": task_id,
            "filename": filename,
            "operation": operation,
            "expires_in": expires_in,
            "expires_at": int(time.time() + expires_in),
            "message": f"Generated {operation} URL expiring in {expires_in} seconds"
        }
    except Exception as e:
        logger.error(f"Failed to generate presigned URL for {filename} in project {task_id}: {str(e)}")
        logger.warning(traceback.format_exc())
        raise HTTPException(status_code=500, detail=f"Failed to generate presigned URL: {str(e)}")

class CreateS3KeyRequest(BaseModel):
    """Request model for creating S3 access keys for a project"""
    project_name: str = Field(description="The project name to create keys for")
    read_only: bool = Field(default=False, description="Whether to create read-only keys")

@router.post("/content/keys")
async def create_project_keys(
    request: CreateS3KeyRequest,
    user: dict = Depends(get_api_key)  # Higher security: require API key
):
    """
    Creates access keys for a specific project in S3 storage.
    These keys will have limited permissions to only access files within the project.
    
    Args:
        request: The request model containing project_name and read_only flag
        user: The authenticated admin user (injected by dependency)
    
    Returns:
        JSON with the created access keys
    """
    try:
        # Create project access keys
        s3_service = S3Service()
        key_data = s3_service.create_user_key(
            project_name=request.project_name,
            read_only=request.read_only
        )
        
        # Return the key data (sensitive information - admin access only)
        return {
            **key_data,
            "created_at": int(time.time()),
            "message": f"Created {'read-only' if request.read_only else 'read-write'} keys for project {request.project_name}"
        }
    except Exception as e:
        logger.error(f"Failed to create keys for project {request.project_name}: {str(e)}")
        logger.warning(traceback.format_exc())
        raise HTTPException(status_code=500, detail=f"Failed to create project keys: {str(e)}")