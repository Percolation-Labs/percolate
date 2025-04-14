
from __future__ import annotations
from fastapi import APIRouter, FastAPI, Response, UploadFile, File, Form
from http import HTTPStatus
from fastapi.middleware.cors import CORSMiddleware
from pathlib import Path
from .routes import set_routes
from percolate import __version__
from starlette.middleware.sessions import SessionMiddleware
from uuid import uuid1
from datetime import datetime


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
)


k = str(uuid1())

app.add_middleware(SessionMiddleware, secret_key=k)

api_router = APIRouter()

origins = [
    "http://localhost:5008",
]

app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/", include_in_schema=False)
@app.get("/healthcheck", include_in_schema=False)
async def healthcheck():
    return {"status": "ok"}


    
app.include_router(api_router)
set_routes(app)

@app.get("/models")
def get_models():
    """
    
    List the models that have configured tokens in the Percolate database. Only models with tokens set will be shown
    """
    
    from percolate.models.p8 import LanguageModelApi
    import percolate as p8
    
    data  = p8.repository(LanguageModelApi).execute(f"""select name as id, token_env_key, created_at as created, updated_at as updated from p8."LanguageModelApi" where token is not null """)
    
    data =  [{
        'id': r['id'],
        'created': r['created'],
        'updated': r['updated'],
        'object': 'model',
        
    } for r in data]
    
    return {'object':'list', 'data': data}
    
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
    2. uvicorn percolate.api.main:app --port 5008 --reload 
    Now we are running the dev server on the same location that the database etc expects
    Also add percolate-api mapped to localhost in your hosts files
    
    http://127.0.0.1:5008/docs or /swagger
    """
    
    start()