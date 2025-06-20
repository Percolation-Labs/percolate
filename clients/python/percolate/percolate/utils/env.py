import os
from pathlib import Path
from importlib import import_module
import json
def get_repo_root():
    """the root directory of the project by convention"""
    path = os.environ.get("P8_HOME")
    if not path:
        p8 = import_module("percolate")
        path = str(Path(p8.__file__).resolve().parent.parent.parent.parent.parent)
        return path
    return path

def _try_load_account_token(path):
    """percolate account settings can be saved locally"""
    try:
        if Path.exists(path):
            with open(path,'r') as f:
                return  json.load(f)
    except: 
        pass
    return {}
    
user_percolate_home = Path.home() / ".percolate"
user_percolate_auth = user_percolate_home / 'auth'
user_percolate_storage = user_percolate_home / 'storage'

PERCOLATE_ACCOUNT_SETTINGS = _try_load_account_token(user_percolate_auth / 'token')
        
# Core paths 
P8_HOME = os.environ.get('P8_HOME', get_repo_root())
STUDIO_HOME = f"{P8_HOME}/studio"
P8_SCHEMA = 'p8'
P8_EMBEDDINGS_SCHEMA = 'p8_embeddings'

# Embedded DB settings
P8_EMBEDDED_DB_HOME = os.environ.get('P8_EMBEDDED_DB_HOME', str(user_percolate_home / 'storage'))
 
# DuckDB specific settings
P8_DUCKDB_DIR = os.environ.get('P8_DUCKDB_DIR', str(Path(P8_EMBEDDED_DB_HOME) / 'duckdb'))
 
# Always default PyIceberg to enabled
PERCOLATE_USE_PYICEBERG = os.environ.get('PERCOLATE_USE_PYICEBERG', "1").lower() in ("1", "true", "yes", "y")

# PostgreSQL settings
POSTGRES_DB = "app"
P8_CONTAINER_REGISTRY = "harbor.percolationlabs.ai"

def from_env_or_project(key, default):
    """
    when percolate is run normally, the connection details are loaded from the project
    in dev we typically want to override these with environment vars
    """
    return os.environ.get(key) or PERCOLATE_ACCOUNT_SETTINGS.get(key,default)

"""for now settings these env vars overrides the project"""
POSTGRES_SERVER = from_env_or_project('P8_PG_HOST', "localhost") 
POSTGRES_PORT = from_env_or_project('P8_PG_PORT', 5438)
POSTGRES_PASSWORD = from_env_or_project('P8_PG_PASSWORD', 'postgres') 
POSTGRES_USER = from_env_or_project('P8_PG_USER', 'postgres') 

POSTGRES_CONNECTION_STRING = f"postgresql://{POSTGRES_USER}:{POSTGRES_PASSWORD}@{POSTGRES_SERVER}:{POSTGRES_PORT}/{POSTGRES_DB}"
TESTDB_CONNECTION_STRING =  f"postgresql://{POSTGRES_USER}:{POSTGRES_PASSWORD}@{POSTGRES_SERVER}:{POSTGRES_PORT}/test"
DEFAULT_CONNECTION_TIMEOUT = 30
 
"""later we will add these to the project"""
MINIO_SECRET = os.environ.get('MINIO_SECRET', 'percolate')
MINIO_SERVER = os.environ.get('MINIO_SERVER', 'localhost:9000')
MINIO_P8_BUCKET = 'percolate'

# S3 configuration
S3_ACCESS_KEY = os.environ.get('S3_ACCESS_KEY')
S3_SECRET = os.environ.get('S3_SECRET')
S3_URL = os.environ.get('S3_URL', 'hel1.your-objectstorage.com')
S3_DEFAULT_BUCKET = os.environ.get('S3_DEFAULT_BUCKET', 'percolate')
S3_BUCKET_NAME = os.environ.get('S3_BUCKET_NAME', S3_DEFAULT_BUCKET)
#   
TAVILY_API_KEY = os.environ.get('TAVILY_API_KEY')

GPT_MINI = "gpt-4.1-mini"
DEFAULT_MODEL =  "gpt-4.1"

# Vision model configuration
# As of May 22, 2025 - State of the Art Vision Models (Cost vs Speed vs Accuracy)
#
# COST-EFFECTIVE OPTIONS (Best value for frequent use):
# - "gpt-4o-mini": OpenAI's most cost-effective vision model (~33x cheaper than gpt-4o)
#   Speed: Fast | Cost: $2.50/1M tokens | Accuracy: Good for most tasks
# - "gemini-2.0-flash": Google's budget option  
#   Speed: Very Fast | Cost: $0.10/1M input | Accuracy: Good for simple vision tasks
#
# BALANCED OPTIONS (Good performance-to-cost ratio):
# - "gpt-4o": OpenAI's standard vision model (default)
#   Speed: Fast | Cost: $2/1M input, $8/1M output | Accuracy: Excellent
# - "gemini-2.5-pro": Google's flagship (for prompts <200K tokens)
#   Speed: Fast | Cost: $1.25/1M input, $10/1M output | Accuracy: Excellent
#
# PREMIUM OPTIONS (Best accuracy, higher cost):
# - "claude-3.5-sonnet": Anthropic's vision model
#   Speed: Medium | Cost: $3/1M input, $15/1M output | Accuracy: Superior reasoning
# - "claude-3.7-sonnet": Anthropic's latest with extended thinking
#   Speed: Medium | Cost: $3/1M input, $15/1M output | Accuracy: Best for complex analysis
# - "gemini-2.5-pro": Google's flagship (for prompts >200K tokens)  
#   Speed: Fast | Cost: $2.50/1M input, $15/1M output | Accuracy: Excellent
#
# NOTES:
# - Image token costs vary by resolution (typically 1000-1600 tokens per image)
# - Claude excels at extended reasoning and document analysis
# - Gemini leads in multimodal tasks and benchmark performance  
# - GPT-4o offers best balance of speed, cost, and accuracy for most use cases
# - Pricing as of May 2025, subject to change
P8_DEFAULT_VISION_MODEL = os.environ.get('P8_DEFAULT_VISION_MODEL', 'gpt-4o')

def load_db_key(key = "P8_API_KEY"):
    """valid database login requests the key for API access"""
    from percolate.services import PostgresService
    from percolate.utils import make_uuid
    pg = PostgresService()
    data = pg.execute(f'SELECT value from p8."Settings" where id = %s limit 1', (str(make_uuid({"key": key})),))
    if data:
        return data[0]['value']
    
    
def sync_model_keys(connection_string:str=None) -> dict:
    """look for any keys required and returns which there are and which are loaded in env"""
    from percolate.services import PostgresService
    pg = PostgresService(connection_string=connection_string)
    rows = pg.execute(f"""select distinct token_env_key from p8."LanguageModelApi" """)
    
    d = {}
    for row in rows:
        
        k = row['token_env_key'] 
        if k is None:
            continue
        if token:= os.environ.get(k):
            d[k] = True
            pg.execute(f"""update p8."LanguageModelApi" set token=%s where token_env_key = %s""", data=(token,k))
        else:
            d[k] = False
    return d
        


class DBSettings:
    def get(self, key, default=None):
        return load_db_key(key) or default
    
SETTINGS = DBSettings()
 
# Email configuration (defaults to Gmail SMTP using service account email)
EMAIL_PROVIDER = os.environ.get('EMAIL_PROVIDER', 'gmail')
EMAIL_SMTP_SERVER = os.environ.get('EMAIL_SMTP_SERVER', 'smtp.gmail.com')
EMAIL_SMTP_PORT = int(os.environ.get('EMAIL_SMTP_PORT', 587))
EMAIL_USE_TLS = os.environ.get('EMAIL_USE_TLS', 'true').lower() in ('true', '1', 'yes', 'y')
EMAIL_USERNAME = os.environ.get('EMAIL_USERNAME', 'eepis.development@gmail.com')
EMAIL_PASSWORD = os.environ.get('EMAIL_PASSWORD', '')

# System user for row-level security when no user context is provided
def get_system_user_id():
    """
    Get the system user ID for operations without explicit user context.
    System user has admin privileges (access_level = 1) by default.
    
    Returns:
        The system user UUID as a string
    """
    # First check environment variable
    system_user_id = os.environ.get('P8_SYSTEM_USER_ID')
    if system_user_id:
        return system_user_id
    
    # Otherwise generate deterministic UUID from "system-user" string
    # Use uuid5 directly to avoid circular imports with make_uuid
    import uuid
    return str(uuid.uuid5(uuid.NAMESPACE_DNS, "system-user"))

# System user constants
SYSTEM_USER_ID = get_system_user_id()
SYSTEM_USER_ROLE_LEVEL = 1  # Admin level by default