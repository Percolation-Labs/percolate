# routers/drafts.py
from fastapi import APIRouter, HTTPException
from percolate.models.p8 import Task
from percolate.api.auth import get_current_token
import uuid
from fastapi import   Depends, File, UploadFile
from percolate.services import MinioService
router = APIRouter()




@router.post("/upload/")
async def upload_file(folder:str, file: UploadFile = File(...)):
    """uploads a file to a folder"""
    try:
        # Read file and upload to MinIO
        content = await file.read()
        MinioService().add_file(f"{folder}/{file.filename}",content, file.content_type)
    
        return {"filename": f"{folder}/{file.filename}", "message": "Uploaded successfully"}
    except Exception as e:
        return {"error": str(e)}