import os

P8_SCHEMA = 'p8'
P8_EMBEDDINGS_SCHEMA = 'p8_embeddings'
#
POSTGRES_DB = "app"
POSTGRES_SERVER = os.environ.get('P8_PG_HOST', 'localhost')
POSTGRES_PORT = os.environ.get('P8_PG_PORT', 5438)
POSTGRES_PASSWORD =  "postgres"
POSTGRES_USER = "postgres"
POSTGRES_CONNECTION_STRING = f"postgresql://{POSTGRES_USER}:{POSTGRES_PASSWORD}@{POSTGRES_SERVER}:{POSTGRES_PORT}/{POSTGRES_DB}"
DEFAULT_CONNECTION_TIMEOUT = 30
#
MINIO_SECRET = os.environ.get('MINIO_SECRET', 'percolate')
MINIO_SERVER = os.environ.get('MINIO_SERVER', 'localhost:9000')
MINIO_P8_BUCKET = 'percolate'
#

GPT_MINI = "gpt-4o-mini"
DEFAULT_MODEL =   "gpt-4o-2024-08-06"

def load_db_key(key = "P8_API_KEY"):
    """valid database login requests the key for API access"""
    from percolate.services import PostgresService
    from percolate.utils import make_uuid
    pg = PostgresService()
    data = pg.execute(f'SELECT value from p8."Settings" where id = %s limit 1', (str(make_uuid({"key": key})),))
    if data:
        return data[0]['value']
    
    
def sync_model_keys() -> dict:
    """look for any keys required and returns which there are and which are loaded in env"""
    from percolate.services import PostgresService
    pg = PostgresService()
    rows = pg.execute(f"""select distinct token_env_key from p8."LanguageModelApi" """)
    
    d = {}
    for row in rows:
        k = row['token_env_key'] 
        if token:= os.environ.get(k):
            d[k] = True
            pg.execute(f"""update p8."LanguageModelApi" set token=%s where token_env_key = %s""", data=(token,k))
        else:
            d[k] = False
    return d
        