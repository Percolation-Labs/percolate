# routers/drafts.py
from fastapi import APIRouter, HTTPException, BackgroundTasks
from fastapi import   Depends, Response, Form, Request
from fastapi.responses import JSONResponse
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
from apscheduler.triggers.cron import CronTrigger

import traceback
from percolate.utils.studio import Project, apply_project
from fastapi import   Depends, File, UploadFile
import percolate as p8
import datetime
from percolate.models.p8.types import Schedule
from percolate.utils import try_parse_base64_dict
import time
from percolate.models.sync import SyncProvider, SyncConfig
from percolate.models.p8.db_types import AccessLevel


class ScheduleCreate(BaseModel):
    """Request model for creating a schedule."""
    userid: str = Field(..., description="User id associated with schedule")
    name: str = Field(..., description="Task to execute")
    spec: dict = Field(..., description="The task spec can be any json but we have an internal protocol. LLM instructions are valid should use a system_prompt attribute")
    schedule: str = Field(..., description="Cron schedule string, e.g. '0 0 * * *'")

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
async def index_entity(request: IndexRequest, background_tasks: BackgroundTasks, sleep_seconds:int=7, user: dict = Depends(get_api_key))->IndexAudit:
    """index entity and get an audit log id to check status
    the index is created as a background tasks and we respond with an id ref that can be used in the get/
    we sleep for n seconds to allow records to flush after trigger
    """
    id=uuid.uuid1()
    s = PostgresService(IndexAudit)
     
    try:
        
        if request.entity_full_name not in ['p8.AIResponse', "p8.IndexAudit"]:
          
            record = IndexAudit(id=id, model_name='percolate', entity_full_name=request.entity_full_name, metrics={}, status="REQUESTED", message="Indexed requested")
            s.update_records(record)
            """todo create an audit record pending and use that in the api response"""
            logger.info(f"handling {request=}")
            background_tasks.add_task(s.index_entity_by_name,
                                      request.entity_full_name,
                                      id=id,
                                      sleep_seconds=sleep_seconds)
            return record
        else:
            record = IndexAudit(id=id,model_name='percolate',entity_full_name=request.entity_full_name, metrics={}, status="SKIPPED", message="Skipped by design")
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
async def upload_uri(request : dict,
                     background_tasks: BackgroundTasks, 
                     task_id: str = None, 
                     user_id:str=None,
                     device_info:str =None, 
                     is_public_resource:bool = True,
                     expand_resource:bool=False,
                     token: dict = Depends(get_current_token)):
    """book mark uris the same way we upload file content. Resources are assumed public by default e.g. a public we reference but can be "owned" too
    A task_id is a thread id for a session parent e.g. a chat with actions pinned. but by default we just pin to the daily diary
    """

    from percolate.models.p8 import Resources, SessionResources, Session
    
    """quickly audit the bookmark and do the rest as a background task
    im likely to make resources and task resources first class citizens and also create a user session model and functions that do this in the database
    """
    
    """compatibility with modes"""
    user_id = user_id or request.get('user_id')
    #
    """any alias is fine"""
    uri = request.get('uri') or request.get('url')
    intent =  request.get('description') or request.get('summary') or request.get('content')
    resource_title = request.get('title') or request.get('name')
    """get device info from the base64string"""
    device_info:dict = try_parse_base64_dict(device_info) or {}
  
  
    if not task_id:
        task = Session.daily_diary_entry(user_id,query=uri, metadata=device_info)
        task_id = task.id
    else:
        task = Session.task_thread_entry(thread_id=task_id, userid=user_id, query=uri, metadata=device_info)
    
    """we are always auditing intent"""
    p8.repository(Session).update_records(task)   
        
    def index_resources():
        try: 
            if expand_resource:
                """Use the new FileSystemService for resource expansion/chunking"""
                from percolate.services.FileSystemService import FileSystemService
                
                # Initialize FileSystemService which auto-configures for web URIs
                fs = FileSystemService()
                
                # Use the modern read_chunks method with web content support
                resources = list(fs.read_chunks(
                    path=uri,
                    mode='simple',  # Use simple mode for web content
                    chunk_size=1000,  # Standard chunk size  
                    chunk_overlap=200,  # Standard overlap
                    userid=None if is_public_resource else user_id,
                    name=resource_title,
                    save_to_db=False  # We'll save manually for better control
                ))
                
                if resources:
                    head = resources[0]
                    length = len(resources)
                else:
                    # Fallback to simple resource if chunking fails
                    head = resources = Resources(name=resource_title,
                                                content=intent,
                                                summary = intent, 
                                                uri = uri,
                                                userid=None if is_public_resource else user_id)    
                    length = 1
            else:
                """Simple resource creation without expansion"""
                head = resources = Resources(name=resource_title,
                                            content=intent,
                                            summary = intent, 
                                            uri = uri,
                                            userid=None if is_public_resource else user_id)    
                length = 1
            
            """link the resource to sessions
            We store only the head resource in the session for IIR for now
            """
            tr = SessionResources(resource_id=head.id, session_id=task_id,count=length)
        
            """for now we insert seps but in future we will have a function for this"""
            p8.repository(Resources).update_records(resources)
            p8.repository(SessionResources).update_records(tr)
            
            logger.debug(f"Saved task resource {tr=} using {'FileSystemService chunking' if expand_resource else 'simple resource'}")
        except:
            logger.warning(f"Failing background task")
            logger.warning(f"{traceback.format_exc()}")
            """todo implement failure system logs"""
            

    """background task"""
    background_tasks.add_task(index_resources)
       
    logger.info(f"{request=}")
       
    return JSONResponse({"status":f'received uri {uri}'})

from percolate.api.routes.auth import hybrid_auth, HybridAuth
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

# Create a version of hybrid_auth that allows anonymous access
class OptionalHybridAuth(HybridAuth):
    """
    Variation of HybridAuth that allows anonymous access.
    Returns user_id if authenticated, None if not.
    """
    
    async def __call__(
        self, 
        request: Request,
        credentials: typing.Optional[HTTPAuthorizationCredentials] = Depends(HTTPBearer(auto_error=False))
    ) -> typing.Optional[str]:
        """
        Returns user_id if authenticated, None if not authenticated.
        Does not raise 401 for anonymous access.
        """
        try:
            # Try to authenticate using the parent class logic
            return await super().__call__(request, credentials)
        except HTTPException:
            # If authentication fails, return None instead of raising 401
            return None

# Create a singleton instance
optional_hybrid_auth = OptionalHybridAuth()

@router.post("/content/upload")
async def upload_file(background_tasks: BackgroundTasks,
                      file: UploadFile = File(...),
                      task_id: str = Form(None),
                      add_resource: bool = Form(True), 
                      user_id:str = Form(None), 
                      device_info:str = Form(None),
                      auth_user_id: typing.Optional[str] = Depends(optional_hybrid_auth)):
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
    from percolate.models import Resources,Session,SessionResources
    device_info = try_parse_base64_dict(device_info)
    
    # Use hybrid auth - prefer user_id parameter over auth_user_id
    effective_user_id = user_id if user_id else auth_user_id
    logger.info(f"Using user_id: {effective_user_id} (param: {user_id}, auth: {auth_user_id})")
    logger.info(f"Received task_id: {task_id}")
                 
    def index_resource(file_upload_result:dict,task_id:str=None):
        """given a file upload result which provides e.g. the key, index the resource"""
        
        try:         
            logger.debug(f"indexing {file_upload_result=}")
            uri = file_upload_result['uri']
            if not task_id:
                """the user can upload either in a session context or we just pin to daily activity"""
                task = Session.daily_diary_entry(userid=effective_user_id,query= uri, metadata=device_info)
                task_id = task.id
            else:
                task = Session.task_thread_entry(thread_id=task_id, userid=effective_user_id, query=uri, metadata=device_info)
                
            """we are always auditing intent"""
            p8.repository(Session).update_records(task)   

            """Use the new FileSystemService chunking method that works with S3 URIs"""
            from percolate.services.FileSystemService import FileSystemService
            
            # Initialize FileSystemService which auto-configures S3
            fs = FileSystemService()
            
            # Use the modern read_chunks method with proper S3 URI support
            resources = list(fs.read_chunks(
                path=uri,
                mode='simple',  # Use simple mode for faster processing
                chunk_size=1000,  # Standard chunk size
                chunk_overlap=200,  # Standard overlap
                userid=effective_user_id,
                name=file.filename,
                save_to_db=False  # We'll save manually for better control
            ))
            
            if resources:
                # Save all chunks to database
                _ = p8.repository(Resources).update_records(resources)
                """resources can be stored as chunked but we store a ref to the head only"""
                tr = SessionResources(resource_id=resources[0].id, session_id=task_id,count=len(resources))
                """for now we insert seps but in future we will have a function for this"""
                p8.repository(SessionResources).update_records(tr)
                
                logger.debug(f"uploaded {len(resources)} resource chunks using FileSystemService ref={uri}")
            else:
                logger.warning(f"No resources created from {uri} - file may be empty or unsupported")
        except:
            logger.warning(f"Failing background task")
            logger.warning(f"{traceback.format_exc()}")     
    
    try:
        
        # Upload to S3 using put_object with bytes
        s3_service = S3Service()
        logger.info(f"Uploading file for user: {effective_user_id}")
        path = f'users/{effective_user_id}/' if effective_user_id else ''
        """todo still deciding on a file path scheme"""
        path += f"{task_id or 'default'}"
        
        # Build the full S3 URI
        s3_key = f"{path}/{file.filename}"
        s3_uri = f"s3://{s3_service.default_bucket}/{s3_key}"
        
        # Use direct bytes upload since this is a small file from user upload
        file_content = file.file.read()
        file.file.seek(0)  # Reset file pointer
        
        result = s3_service.upload_filebytes_to_uri(
            s3_uri=s3_uri,
            file_content=file_content,
            content_type=file.content_type
        )
        
        # Get presigned URL separately if needed
        result["presigned_url"] = s3_service.get_presigned_url_for_uri(s3_uri)
        
        if add_resource:
            background_tasks.add_task(index_resource, file_upload_result=result,task_id=task_id)
        
        logger.info(f"Uploaded file {result['name']} to S3 successfully")
        
        # Determine auth method
        auth_method = None
        if user_id:
            auth_method = "user_id_param"
        elif auth_user_id:
            auth_method = "bearer_token"
            
        # Extract key from URI - the part after the bucket name
        uri_parts = result["uri"].split('/', 3)
        key = uri_parts[3] if len(uri_parts) > 3 else result["name"]
            
        return JSONResponse({
            "key": key,
            "filename": result["name"],
            "task_id": task_id,
            "size": result["size"],
            "content_type": result["content_type"],
            "last_modified": result["last_modified"],
            "etag": result["etag"],
            "path": path,
            "user_id": effective_user_id,
            "auth_method": auth_method,
            "message": "Uploaded successfully to S3",
            "presigned_url": result["presigned_url"]
        })
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
        
# Scheduled tasks endpoints
@router.post("/schedules", response_model=Schedule)
async def create_schedule(request: ScheduleCreate, user: dict = Depends(get_api_key)):
    """Create a new scheduled task."""
    from percolate.api.main import scheduler, run_scheduled_job
    # Persist schedule to database
    record = Schedule(id=str(uuid.uuid1()), userid=request.userid, name=request.name, spec=request.spec, schedule=request.schedule)
    result = p8.repository(Schedule).update_records(record)
    # Determine model instance for scheduling
    scheduled = Schedule(**result[0]) if result else record
    # Schedule the job in memory immediately
    try:
        trigger = CronTrigger.from_crontab(scheduled.schedule)
        scheduler.add_job(
            run_scheduled_job,
            trigger,
            args=[scheduled],
            id=str(scheduled.id)
        )
        logger.info(f"Scheduled new job {scheduled.id}")
    except Exception as e:
        logger.warning(f"Failed to add job to scheduler: {e}")
    return scheduled
   
@router.get("/schedules", response_model=typing.List[Schedule])
async def list_schedules(user: dict = Depends(get_api_key)):
    """List all active (non-disabled) schedules."""
 
    repo = p8.repository(Schedule)
    table = Schedule.get_model_table_name()
    data = repo.execute(f"SELECT * FROM {table} WHERE disabled_at IS NULL")
    return [Schedule(**d) for d in data]
   
@router.delete("/schedules/{schedule_id}", response_model=Schedule)
async def disable_schedule(schedule_id: str, user: dict = Depends(get_api_key)):
    """Disable (soft delete) a schedule by setting its disabled_at timestamp."""
    from percolate.api.main import scheduler
    repo = p8.repository(Schedule)
    table = Schedule.get_model_table_name()
    data = repo.execute(f"SELECT * FROM {table} WHERE id = %s", data=(schedule_id,))
    if not data:
        raise HTTPException(status_code=404, detail="Schedule not found")
    existing = Schedule(**data[0])
    existing.disabled_at = datetime.datetime.utcnow()
    result = p8.repository(Schedule).update_records(existing)
    updated = Schedule(**result[0]) if result else existing
    # Remove from scheduler
    try:
        scheduler.remove_job(str(schedule_id))
        logger.info(f"Removed scheduled job {schedule_id}")
    except Exception:
        logger.warning(f"Job {schedule_id} not found in scheduler or failed to remove")
    return updated

class SyncScheduleRequest(BaseModel):
    """Request model for creating a scheduled sync configuration."""
    provider: SyncProvider = Field(..., description="Sync provider (google_drive, box, dropbox, onedrive)")
    folder_id: str = Field(..., description="Remote folder ID to sync from")
    target_namespace: str = Field(default="p8", description="Target model namespace (default: p8)")
    target_model_name: str = Field(default="Resources", description="Target model name (default: Resources)")
    access_level: AccessLevel = Field(default=AccessLevel.PUBLIC, description="Access level for synced content")
    include_folders: typing.Optional[typing.List[str]] = Field(None, description="List of folder names to include")
    exclude_folders: typing.Optional[typing.List[str]] = Field(None, description="List of folder names to exclude")
    include_file_types: typing.Optional[typing.List[str]] = Field(None, description="List of file extensions to include")
    exclude_file_types: typing.Optional[typing.List[str]] = Field(None, description="List of file extensions to exclude")
    sync_interval_hours: int = Field(default=24, description="Sync interval in hours (default: 24)")
    enabled: bool = Field(default=True, description="Whether sync is enabled")

@router.post("/sync/schedule", response_model=dict)
async def create_sync_schedule(
    request: SyncScheduleRequest,
    background_tasks: BackgroundTasks,
    user: dict = Depends(get_api_key)
):
    """
    Create a new scheduled sync configuration to sync files from external providers
    to a specific target table. This endpoint:
    
    1. Creates or validates the target model (can be Abstract model)
    2. Creates a sync configuration
    3. Schedules the sync to run on the specified interval
    
    Args:
        request: Sync schedule configuration
        user: Authenticated admin user
        
    Returns:
        Dictionary with sync config ID and schedule information
    """
    try:
        from percolate.models.AbstractModel import AbstractModel
        from percolate.models.p8.types import Resources
        from percolate.services.sync.file_sync import FileSync
        
        # Get user ID from authenticated user
        user_id = user.get('user_id') or user.get('id')
        if not user_id:
            raise HTTPException(status_code=400, detail="User ID not found in authentication")
            
        # Validate that we have sync credentials for this provider and user
        from percolate.models.sync import SyncCredential
        creds = p8.repository(SyncCredential).select(userid=user_id, provider=request.provider.value)
        if not creds:
            raise HTTPException(
                status_code=400, 
                detail=f"No sync credentials found for provider {request.provider.value}. Please authenticate first."
            )
        
        # Check if target model exists or create Abstract model
        target_model = None
        full_model_name = f"{request.target_namespace}.{request.target_model_name}"
        
        # Special handling for the default Resources model
        if request.target_namespace == "p8" and request.target_model_name == "Resources":
            target_model = Resources
            logger.info(f"Using existing Resources model")
        else:
            # Try to get existing model from registry first
            try:
                # Check if model exists in database
                model_check = p8.repository(Resources).execute(
                    """SELECT EXISTS(
                        SELECT FROM information_schema.tables 
                        WHERE table_schema = %s 
                        AND table_name = %s
                    )""",
                    data=(request.target_namespace, request.target_model_name)
                )
                
                model_exists = model_check[0]['exists'] if model_check else False
                
                if not model_exists:
                    # Create Abstract model that inherits from Resources
                    logger.info(f"Creating new Abstract model: {full_model_name}")
                    
                    # Create the model dynamically with access_level
                    target_model = AbstractModel.create_model(
                        name=request.target_model_name,
                        namespace=request.target_namespace,
                        description=f"Synced content from {request.provider.value} folder {request.folder_id}",
                        fields={},  # No additional fields, inherits from Resources
                        access_level=request.access_level,  # Pass access level directly
                        inherit_config=True,  # Inherit config from Resources parent
                        __base__=Resources  # Inherit from Resources
                    )
                    
                    # Create the table using SqlModelHelper
                    sql_helper = target_model.to_sql_model_helper()
                    create_sql = sql_helper.create_table_sql()
                    
                    # Execute table creation
                    repo = p8.repository(Resources)  # Use Resources repo for execution
                    repo.execute(create_sql)
                    
                    logger.info(f"Created table for model {full_model_name}")
                else:
                    logger.info(f"Model {full_model_name} already exists")
                    # For existing models, we'll use Resources as the base
                    target_model = Resources
                    
            except Exception as e:
                logger.error(f"Error checking/creating model: {str(e)}")
                raise HTTPException(status_code=500, detail=f"Failed to create target model: {str(e)}")
        
        # Create sync configuration
        sync_config = SyncConfig(
            userid=user_id,
            provider=request.provider,
            enabled=request.enabled,
            include_folders=request.include_folders,
            exclude_folders=request.exclude_folders,
            include_file_types=request.include_file_types,
            exclude_file_types=request.exclude_file_types,
            sync_interval_hours=request.sync_interval_hours,
            provider_metadata={
                "folder_id": request.folder_id,
                "target_namespace": request.target_namespace,
                "target_model_name": request.target_model_name,
                "access_level": request.access_level.value
            }
        )
        
        # Save sync configuration
        saved_configs = p8.repository(SyncConfig).update_records(sync_config)
        saved_config = saved_configs[0] if saved_configs else sync_config
        
        # Create a schedule for the sync task
        schedule_spec = {
            "task_type": "file_sync",
            "sync_config_id": str(saved_config.id),
            "user_id": user_id,
            "provider": request.provider.value,
            "target_model": full_model_name
        }
        
        # Convert sync interval to cron expression
        # For hourly intervals, use "0 */N * * *" format
        if request.sync_interval_hours == 24:
            cron_schedule = "0 0 * * *"  # Daily at midnight
        elif request.sync_interval_hours == 12:
            cron_schedule = "0 */12 * * *"  # Every 12 hours
        elif request.sync_interval_hours == 6:
            cron_schedule = "0 */6 * * *"  # Every 6 hours
        elif request.sync_interval_hours == 1:
            cron_schedule = "0 * * * *"  # Every hour
        else:
            # For other intervals, run every N hours
            cron_schedule = f"0 */{request.sync_interval_hours} * * *"
        
        schedule = Schedule(
            id=str(uuid.uuid4()),
            userid=user_id,
            name=f"Sync {request.provider.value} to {full_model_name}",
            spec=schedule_spec,
            schedule=cron_schedule
        )
        
        # Save schedule
        saved_schedules = p8.repository(Schedule).update_records(schedule)
        saved_schedule = saved_schedules[0] if saved_schedules else schedule
        
        # Schedule the job immediately
        try:
            from percolate.api.main import scheduler, run_scheduled_job
            from apscheduler.triggers.cron import CronTrigger
            
            trigger = CronTrigger.from_crontab(cron_schedule)
            scheduler.add_job(
                run_scheduled_job,
                trigger,
                args=[saved_schedule],
                id=str(saved_schedule.id)
            )
            logger.info(f"Scheduled sync job {saved_schedule.id}")
        except Exception as e:
            logger.warning(f"Failed to add job to scheduler: {e}")
        
        # Optionally trigger an immediate sync in the background
        def run_initial_sync():
            try:
                import asyncio
                sync_service = FileSync()
                # Run the sync
                loop = asyncio.new_event_loop()
                asyncio.set_event_loop(loop)
                result = loop.run_until_complete(
                    sync_service.sync_user_content(user_id=user_id, force=True)
                )
                logger.info(f"Initial sync completed: {result}")
            except Exception as e:
                logger.error(f"Initial sync failed: {str(e)}")
        
        # Add initial sync as background task
        background_tasks.add_task(run_initial_sync)
        
        return {
            "sync_config_id": str(saved_config.id),
            "schedule_id": str(saved_schedule.id),
            "provider": request.provider.value,
            "folder_id": request.folder_id,
            "target_model": full_model_name,
            "access_level": request.access_level.name,
            "sync_interval_hours": request.sync_interval_hours,
            "cron_schedule": cron_schedule,
            "enabled": request.enabled,
            "message": "Sync schedule created successfully. Initial sync started in background."
        }
        
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Failed to create sync schedule: {str(e)}")
        logger.error(traceback.format_exc())
        raise HTTPException(status_code=500, detail=f"Failed to create sync schedule: {str(e)}")