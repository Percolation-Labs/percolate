
from __future__ import annotations
from fastapi import APIRouter, FastAPI, Response, UploadFile, File, Form, Request
from http import HTTPStatus
from fastapi.middleware.cors import CORSMiddleware
from pathlib import Path
from .routes import set_routes
from percolate import __version__
from starlette.middleware.sessions import SessionMiddleware
from uuid import uuid1
from datetime import datetime
from starlette.middleware.base import BaseHTTPMiddleware
import os
import json
from percolate.utils import logger
from contextlib import asynccontextmanager
from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.cron import CronTrigger
import percolate as p8
from percolate.models.p8.types import Schedule
from percolate.api.routes.auth.utils import get_stable_session_key
import asyncio
# Global scheduler instance
scheduler = BackgroundScheduler()

def acquire_task_lock(process_id, task_name, timeout_seconds=300):
    """Try to acquire a lock for running a specific task."""
    import time
    import json
    from percolate.models.p8.types import Settings
    
    lock_key = f"task_lock:{task_name}"
    
    try:
        settings_repo = p8.repository(Settings)
        current_time = time.time()
        
        # Use a transaction-like approach with immediate re-check
        # First, check if lock exists and is valid
        existing_lock = settings_repo.select(key=lock_key)
        if existing_lock:
            lock_data = json.loads(existing_lock[0]['value'])
            if current_time < lock_data.get('expires_at', 0):
                # Lock is held by another process
                logger.debug(f"Task {task_name} already running on {lock_data['process_id']}")
                return False
        
        # Try to acquire lock with our process ID
        lock_value = json.dumps({
            'process_id': process_id,
            'acquired_at': current_time,
            'expires_at': current_time + timeout_seconds
        })
        
        lock_setting = Settings(key=lock_key, value=lock_value)
        settings_repo.update_records(lock_setting)
        
        # CRITICAL: Re-check that we actually got the lock
        # This handles race conditions where multiple pods try simultaneously
        verification = settings_repo.select(key=lock_key)
        if verification:
            verified_data = json.loads(verification[0]['value'])
            if verified_data.get('process_id') == process_id:
                logger.info(f"Acquired lock for task: {task_name}")
                return True
            else:
                # Another process beat us to it
                logger.debug(f"Lost race for task {task_name} to {verified_data.get('process_id')}")
                return False
        
        # Shouldn't happen, but handle gracefully
        logger.error(f"Lock verification failed for task {task_name}")
        return False
        
    except Exception as e:
        logger.error(f"Failed to acquire task lock: {e}")
        return False

def release_task_lock(process_id, task_name):
    """Release the lock for a task."""
    import time
    import json
    from percolate.models.p8.types import Settings
    
    lock_key = f"task_lock:{task_name}"
    
    try:
        settings_repo = p8.repository(Settings)
        release_value = json.dumps({
            'released_by': process_id,
            'released_at': time.time()
        })
        
        lock_setting = Settings(key=lock_key, value=release_value)
        settings_repo.update_records(lock_setting)
        
        logger.debug(f"Released lock for task: {task_name}")
        
    except Exception as e:
        logger.error(f"Failed to release task lock: {e}")

def run_scheduled_job(schedule_record):
    """Run a scheduled job based on its specification."""
    import uuid,socket
    
    # Generate unique process ID for this execution
    process_id = f"{socket.gethostname()}-{os.getpid()}-{uuid.uuid4().hex[:8]}"
    task_name = f"{schedule_record.name}:{schedule_record.id}"
    
    # Try to acquire lock for this task
    if not acquire_task_lock(process_id, task_name):
        logger.debug(f"Skipping {task_name} - already running on another pod")
        return
    
    try:
        logger.info(f"Running scheduled task: {schedule_record.name}")
        
        # Handle different task types
        if schedule_record.name and schedule_record.name.lower() == "daily-digest":
            logger.info(f"Executing Daily Digest task for user: {schedule_record.userid}")
            from percolate.services.tasks.TaskManager import TaskManager
            task_manager = TaskManager()
            task_manager.dispatch_task(schedule_record)
        elif schedule_record.spec and "task_type" in schedule_record.spec:
            task_type = schedule_record.spec["task_type"]
            logger.info(f"Executing task type: {task_type}")
            
            if task_type == "digest":
                # Handle digest tasks
                from percolate.services.tasks.TaskManager import TaskManager
                task_manager = TaskManager()
                task_manager.dispatch_task(schedule_record)
            elif task_type == "file_sync":
                # Handle file sync tasks
                logger.info(f"Running file sync task: {schedule_record.spec}")
                # File sync logic would go here
            else:
                logger.warning(f"Unknown task type: {task_type}")
        elif schedule_record.spec and "task" in schedule_record.spec:
            task_name = schedule_record.spec["task"]
            logger.info(f"Executing task: {task_name}")
        else:
            logger.warning(f"No task specified in schedule record: {schedule_record.id}")
            
    except Exception as e:
        logger.error(f"Error running scheduled task {schedule_record.id}: {str(e)}")
    finally:
        # Always release the lock
        release_task_lock(process_id, task_name)

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan: all pods run schedulers with per-task locking."""
    import socket
    
    # Create a unique identifier for this pod
    pod_id = f"{socket.gethostname()}-{os.getpid()}"
    
    # Load and start schedules - ALL pods do this
    repo = p8.repository(Schedule)
    table = Schedule.get_model_table_name()  
   
    try:
        data = repo.execute(f"SELECT * FROM {table} WHERE disabled_at IS NULL")
        for d in data:
            try:
                record = Schedule(**d)
                trigger = CronTrigger.from_crontab(record.schedule)
                scheduler.add_job(run_scheduled_job, trigger, args=[record], id=str(record.id))
            except Exception as e:
                logger.warning(f"Failed to schedule job for record {d.get('id')}: {e}")
    except Exception as ex:
        logger.warning(f"Failed to load scheduler data {ex}")
    
    scheduler.start()
    logger.info(f"✓ Scheduler started on pod {pod_id} with jobs: {[j.id for j in scheduler.get_jobs()]}")
    
    try:
        yield
    finally:
        # Shutdown scheduler
        scheduler.shutdown()
        logger.info(f"Scheduler shutdown complete on pod {pod_id}")


app = FastAPI(
    title="Percolate",
    openapi_url=f"/openapi.json",
    description=(
        """Percolate server can be used to do maintenance tasks on the database and also to test the integration of APIs in general"""
    ),
    version=__version__,
    contact={
        "name": "Percolation Labs",
        "url": "https://github.com/Percolation-Labs/percolate.git",
        "email": "percolationlabs@gmail.com",
    },
    license_info={
        "name": "MIT",
        "url": "https://opensource.org/licenses/MIT",
    },
    docs_url="/swagger",
    redoc_url=f"/docs",
    lifespan=lifespan,
)

# Use stable session key for session persistence across restarts
session_key = get_stable_session_key()

logger.info('Percolate api app started with stable session key')

# Add session middleware with better cookie settings
app.add_middleware(
    SessionMiddleware, 
    secret_key=session_key,
    max_age=86400,  # 1 day in seconds
    same_site="none",  # Allow cross-site cookies (needed for OAuth redirects)
    https_only=False,  # Set to True in production with HTTPS
    session_cookie="session"  # Ensure consistent cookie name
)
#app.add_middleware(PayloadLoggerMiddleware)


api_router = APIRouter()

origins = [
    "http://localhost:5008",
    "http://localhost:8000",
    "http://localhost:5000",
    "http://127.0.0.1:5008",
    "http://127.0.0.1:8000",
    "http://127.0.0.1:5000",
    "http://localhost:1420",# (Tauri dev server)
    "http://tauri.localhost",# (Tauri production origin)
    "https://tauri.localhost", #(Tauri production origin with https)
    "https://vault.percolationlabs.ai",
]

app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
    expose_headers=[
        "Location",
        "Upload-Offset", 
        "Upload-Length", 
        "Tus-Version", 
        "Tus-Resumable", 
        "Tus-Max-Size", 
        "Tus-Extension", 
        "Upload-Metadata",
        "Upload-Expires"
    ],
)


@app.get("/", include_in_schema=False)
@app.get("/healthcheck", include_in_schema=False)
async def healthcheck():
    return {"status": "ok"}

@app.get("/ping", include_in_schema=False)
async def ping():
    return Response(status_code=HTTPStatus.OK)


    
# Create the apple-app-site-association file content
# Replace YOUR_TEAM_ID with your actual Apple Developer Team ID
def get_aasa_content(team_id):
    return {
        "applinks": {
            "apps": [],
            "details": [
                {
                    "appID": f"{team_id}.EEPIS.EepisApp",
                    "paths": ["/auth/google/callback*"]
                }
            ]
        }
    }

@app.get("/.well-known/apple-app-site-association")
async def serve_apple_app_site_association():
    # Replace with your actual Team ID
    team_id = os.environ.get("APPLE_TEAM_ID", "SG2497YYXJ")
    
    content = get_aasa_content(team_id)
    
    # Return JSON with the correct content type
    return Response(
        content=json.dumps(content),
        media_type="application/json"
    )
    
app.include_router(api_router)
set_routes(app)

@app.get("/models")
def get_models():
    """
    List the models that have configured tokens in the Percolate database. Only models with tokens set will be shown
    """
    from .utils.models import list_available_models
    return list_available_models()
    
def start():
    import uvicorn

    uvicorn.run(
        f"{Path(__file__).stem}:app",
        host="0.0.0.0",
        port=5008,
        log_level="debug",
        reload=True,
    )


if __name__ == "__main__":
    """
    You can start the dev with this in the root
    if running the docker image we keep the same port and stop the service in docker - this makes it easier to test in dev
    for example: 
    1. docker compose stop percolate-api
    #export for whatever env e.g. for using pos
    2. uvicorn percolate.api.main:app --port 5008 --reload 
    Now we are running the dev server on the same location that the database etc expects
    Also add percolate-api mapped to localhost in your hosts files
    
    http://127.0.0.1:5008/docs or /swagger
    """
    
    start()