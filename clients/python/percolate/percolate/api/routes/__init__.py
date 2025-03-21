from fastapi import FastAPI

from .admin import router as admin_router
from .tasks import router as task_router
from .chat import router as chat_router
from .entities import router as entity_router
from .tools import router as tool_router
from .integrations import router as x_router
from .auth import router as auth_router

def set_routes(app: FastAPI):
    app.include_router(auth_router, prefix=f"/auth", tags=["Auth"])
    app.include_router(admin_router, prefix=f"/admin", tags=["Admin"])
    app.include_router(task_router, prefix=f"/tasks", tags=["Tasks"])
    app.include_router(entity_router, prefix=f"/entities", tags=["Entities"])
    app.include_router(tool_router, prefix=f"/tools", tags=["Tools"])
    app.include_router(chat_router, prefix=f"/chat", tags=["Chat"])
    app.include_router(x_router, prefix=f"/x", tags=["Integrations"])