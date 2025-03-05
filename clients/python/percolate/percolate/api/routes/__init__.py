from fastapi import FastAPI

from .admin import router as admin_router
from .tasks import router as task_router
from .content import router as content_router
from .chat import router as chat_router

def set_routes(app: FastAPI):
    app.include_router(admin_router, prefix=f"/admin", tags=["admin"])
    app.include_router(task_router, prefix=f"/tasks", tags=["tasks"])
    app.include_router(content_router, prefix=f"/content", tags=["content"])
    app.include_router(chat_router, prefix=f"/chat", tags=["chat"])