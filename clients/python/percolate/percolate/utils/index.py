from glob import glob
from percolate.utils import get_repo_root,split_string_into_chunks,logger
from percolate.models.p8 import PercolateAgent
import percolate as p8
import uuid

def index_codebase(include_api_json=True):
    """
    add all the code into a vector store in a crude sort of way
    """
    R = get_repo_root()    
    files = {
        'py' : glob(f"{R}/**/*.py", recursive=True),
        'md' : glob(f"{R}/**/*.md", recursive=True),
        'sql' : glob(f"{R}/**/*.sql", recursive=True),
        'yaml' : glob(f"{R}/**/*.yaml", recursive=True),
    }

    records = []
    for file_type, file_paths in files.items():
        for file_path in file_paths:
            with open(file_path, "r") as f:
                f = f.read()
                for i, f in enumerate(split_string_into_chunks(f)):
                    f = f"""
                    ```{file_type}
                    # {file_path}
                    {f}
                    ```"""
                    records.append(PercolateAgent(id=str(uuid.uuid1()), name=file_path.split('/')[-1], uri=file_path, content=f,category=file_type, ordinal=i))

    logger.info(f"Indexing {len(records)} items")
    
    p8.repository(PercolateAgent).update_records(records,index_entities=False) #this is on trigger now