
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
# Global scheduler instance
scheduler = BackgroundScheduler()

def run_scheduled_job(schedule_record):
    """Run a scheduled job based on its specification."""
    logger.info(f"Running scheduled task: {schedule_record.name}")
    
    # Handle different task types
    try:
        if schedule_record.spec and "task" in schedule_record.spec:
            task_name = schedule_record.spec["task"]
            logger.info(f"Executing task: {task_name}")
            
            # Process pending TUS uploads task
            if task_name == "process_pending_s3_resources":
                from percolate.api.controllers.tus import process_pending_s3_resources
                import asyncio
                
                # Create an event loop for the async task
                loop = asyncio.new_event_loop()
                asyncio.set_event_loop(loop)
                
                try:
                    # Run the async function in the event loop
                    result = loop.run_until_complete(process_pending_s3_resources())
                    logger.info(f"Scheduled task result: {result}")
                finally:
                    loop.close()
        else:
            logger.warning(f"No task specified in schedule record: {schedule_record.id}")
    except Exception as e:
        logger.error(f"Error running scheduled task {schedule_record.id}: {str(e)}")
        # Don't propagate exceptions to prevent scheduler from failing

# @asynccontextmanager
# async def lifespan(app: FastAPI):
#     """Application lifespan: start and shutdown scheduler."""
    
#     repo = p8.repository(Schedule)
#     table = Schedule.get_model_table_name()  
   
#     try:
#         data = repo.execute(f"SELECT * FROM {table} WHERE disabled_at IS NULL")
#         for d in data:
#             try:
#                 record = Schedule(**d)
#                 trigger = CronTrigger.from_crontab(record.schedule)
#                 scheduler.add_job(run_scheduled_job, trigger, args=[record], id=str(record.id))
#             except Exception as e:
#                 logger.warning(f"Failed to schedule job for record {d.get('id')}: {e}")
#     except Exception as ex:
#         logger.warning(f"Failed to load scheduler data {ex}")
    
#     scheduler.start()
#     logger.info(f"Scheduler started with jobs: {[j.id for j in scheduler.get_jobs()]}")
    
#     # Check if we need to process pending TUS uploads (we don't create schedules at startup)
#     try:
#         from percolate.api.controllers.tus import process_pending_s3_resources
#         import asyncio
#         # Process any pending uploads at startup, but don't create a schedule
#         asyncio.create_task(process_pending_s3_resources())
#         logger.info("Triggered initial TUS processing at startup")
#     except Exception as e:
#         logger.error(f"Failed to trigger initial TUS processing: {e}")
    
#     try:
#         yield
#     finally:
#         scheduler.shutdown()


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
   # lifespan=lifespan,
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
    "https://tauri.localhost" #(Tauri production origin with https)
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