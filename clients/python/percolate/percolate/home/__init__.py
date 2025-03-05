from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
import os
from pathlib import Path

router = APIRouter()

# Setup static files and templates
current_dir = Path(__file__).parent
static_dir = current_dir / "static"
templates_dir = current_dir / "templates"

# Define routes
@router.get("/", response_class=HTMLResponse)
async def home(request: Request):
    """Serve the home page"""
    return templates.TemplateResponse("index.html", {"request": request})

# Function to setup the home module with the FastAPI app
def setup_home(app):
    """Setup the home module with the FastAPI app"""
    # Mount static files
    app.mount("/static", StaticFiles(directory=str(static_dir)), name="static")
    
    # Setup templates
    global templates
    templates = Jinja2Templates(directory=str(templates_dir))
    
    # Include router
    app.include_router(router, tags=["home"])