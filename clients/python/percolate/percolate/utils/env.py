import os

P8_SCHEMA = 'p8'
P8_EMBEDDINGS_SCHEMA = 'p8_embeddings'
#
POSTGRES_DB = "app"
POSTGRES_SERVER = "localhost"
POSTGRES_PORT = os.environ.get('P8_PG_PORT', 5438)
POSTGRES_PASSWORD =  "postgres"
POSTGRES_USER = "postgres"
POSTGRES_CONNECTION_STRING = f"postgresql://{POSTGRES_USER}:{POSTGRES_PASSWORD}@{POSTGRES_SERVER}:{POSTGRES_PORT}/{POSTGRES_DB}"
#


GPT_MINI = "gpt-4o-mini"
DEFAULT_MODEL =   "gpt-4o-2024-08-06"
