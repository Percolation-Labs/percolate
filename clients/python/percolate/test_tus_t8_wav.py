#!/usr/bin/env python3
"""
Test TUS upload with T8.wav file
"""

import os
import sys
import asyncio
from pathlib import Path
from fastapi import BackgroundTasks

# Add percolate to path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# Set up environment
os.environ["POSTGRES_HOST"] = "eepis.percolationlabs.ai"
os.environ["POSTGRES_PORT"] = "5434"
os.environ["POSTGRES_PASSWORD"] = os.environ.get("P8_TEST_BEARER_TOKEN")
os.environ["POSTGRES_USER"] = "app"
os.environ["POSTGRES_DB"] = "app"
os.environ["TUS_STORAGE_PATH"] = "/tmp/tus_test"
os.environ["S3_DEFAULT_BUCKET"] = "percolate"

# Import after setting environment
from percolate.api.controllers import tus_filesystem as controller
from percolate.utils import logger

# Suppress warnings
import warnings
warnings.filterwarnings("ignore")

class MockBackgroundTasks:
    def __init__(self):
        self.tasks = []
    
    def add_task(self, func, *args, **kwargs):
        self.tasks.append((func, args, kwargs))
    
    async def run_all(self):
        for func, args, kwargs in self.tasks:
            if asyncio.iscoroutinefunction(func):
                await func(*args, **kwargs)
            else:
                func(*args, **kwargs)

class MockRequest:
    def __init__(self):
        self.url = type('obj', (object,), {
            'scheme': 'https',
            'netloc': 'eepis.percolationlabs.ai'
        })
        self.headers = {'host': 'eepis.percolationlabs.ai'}

async def test_upload():
    """Test file upload with T8.wav"""
    
    # Use T8.wav
    test_file = os.path.expanduser("~/Downloads/T8.wav")
    
    if not os.path.exists(test_file):
        print(f"Error: T8.wav not found at {test_file}")
        return
    
    file_size = os.path.getsize(test_file)
    filename = os.path.basename(test_file)
    
    print(f"Test file: {filename}")
    print(f"File size: {file_size:,} bytes ({file_size / 1024 / 1024:.1f} MB)")
    
    try:
        # 1. Create upload
        print("\n1. Creating upload...")
        request = MockRequest()
        
        result = await controller.create_upload(
            request=request,
            filename=filename,
            file_size=file_size,
            metadata={'test': 'true', 'file': 'T8.wav'},
            user_id=None,
            project_name="test",
            content_type="audio/wav"
        )
        
        upload_id = result.upload_id
        print(f"✓ Created upload: {upload_id}")
        print(f"  Location: {result.location}")
        
        # 2. Upload in chunks (10MB chunks for 332MB file)
        print("\n2. Uploading chunks...")
        bg_tasks = MockBackgroundTasks()
        
        chunk_size = 10 * 1024 * 1024  # 10MB chunks
        total_chunks = (file_size + chunk_size - 1) // chunk_size
        
        print(f"  Total chunks: {total_chunks}")
        
        with open(test_file, 'rb') as f:
            offset = 0
            chunk_num = 0
            
            while offset < file_size:
                chunk_data = f.read(chunk_size)
                if not chunk_data:
                    break
                
                chunk_num += 1
                print(f"\r  Uploading chunk {chunk_num}/{total_chunks} ({chunk_num*100//total_chunks}%)", end='', flush=True)
                
                result = await controller.process_chunk(
                    upload_id=upload_id,
                    chunk_data=chunk_data,
                    content_length=len(chunk_data),
                    offset=offset,
                    background_tasks=bg_tasks
                )
                
                offset = result.offset
        
        print(f"\n✓ All {chunk_num} chunks uploaded to filesystem")
        
        # 3. Run background tasks (finalization)
        print("\n3. Finalizing upload (assembling chunks)...")
        await bg_tasks.run_all()
        
        # 4. Check final status
        print("\n4. Checking final status...")
        upload = await controller.get_upload_info(upload_id)
        
        print(f"\n✓ Upload complete!")
        print(f"  Status: {upload.status}")
        print(f"  S3 URI (for future): {upload.s3_uri}")
        print(f"  Storage type: {upload.upload_metadata.get('storage_type', 'unknown')}")
        print(f"  Local path: {upload.upload_metadata.get('local_path', 'N/A')}")
        print(f"  File size: {upload.upload_metadata.get('file_size', 0):,} bytes")
        
        # Verify assembled file
        final_path = upload.upload_metadata.get('local_path')
        if final_path and os.path.exists(final_path):
            final_size = os.path.getsize(final_path)
            print(f"\n✓ Assembled file verified:")
            print(f"  Size matches: {final_size == file_size} ({final_size:,} bytes)")
        
    except Exception as e:
        print(f"\n❌ Error: {str(e)}")
        import traceback
        traceback.print_exc()


if __name__ == "__main__":
    # Set up logging
    import logging
    logging.getLogger("percolate").setLevel(logging.WARNING)  # Less verbose
    
    print("Testing TUS Upload with T8.wav")
    print("=" * 50)
    
    # Run test
    asyncio.run(test_upload())