#!/usr/bin/env python3
"""
Test the filesystem-only TUS implementation
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
    """Test file upload using filesystem-only TUS."""
    
    # Create test file
    test_file = "test_file.bin"
    file_size = 15 * 1024 * 1024  # 15MB
    
    print(f"Creating {file_size // 1024 // 1024}MB test file...")
    with open(test_file, 'wb') as f:
        for i in range(file_size // (1024 * 1024)):
            f.write(b'X' * (1024 * 1024))
    
    try:
        # 1. Create upload
        print("\n1. Creating upload...")
        request = MockRequest()
        
        result = await controller.create_upload(
            request=request,
            filename=test_file,
            file_size=file_size,
            metadata={'test': 'true'},
            user_id=None,
            project_name="test",
            content_type="application/octet-stream"
        )
        
        upload_id = result.upload_id
        print(f"✓ Created upload: {upload_id}")
        print(f"  Location: {result.location}")
        print(f"  Expires: {result.expires_at}")
        
        # 2. Upload in chunks
        print("\n2. Uploading chunks...")
        bg_tasks = MockBackgroundTasks()
        
        chunk_size = 5 * 1024 * 1024  # 5MB chunks
        with open(test_file, 'rb') as f:
            offset = 0
            chunk_num = 0
            
            while offset < file_size:
                chunk_data = f.read(chunk_size)
                if not chunk_data:
                    break
                
                chunk_num += 1
                print(f"\n  Chunk {chunk_num}: {len(chunk_data):,} bytes at offset {offset:,}")
                
                result = await controller.process_chunk(
                    upload_id=upload_id,
                    chunk_data=chunk_data,
                    content_length=len(chunk_data),
                    offset=offset,
                    background_tasks=bg_tasks
                )
                
                print(f"  ✓ Saved to filesystem, new offset: {result.offset:,}")
                offset = result.offset
        
        print(f"\n✓ All chunks uploaded to filesystem")
        
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
        print(f"  Finalized: {upload.upload_metadata.get('finalized', False)}")
        
        if upload.upload_metadata.get('resource_count'):
            print(f"  Resources: {upload.upload_metadata['resource_count']} created")
        elif upload.upload_metadata.get('resource_creation_error'):
            print(f"  Resource Error: {upload.upload_metadata['resource_creation_error']}")
        
        # Check if assembled file exists
        final_path = upload.upload_metadata.get('local_path')
        if final_path and os.path.exists(final_path):
            final_size = os.path.getsize(final_path)
            print(f"\n✓ Assembled file verified:")
            print(f"  Path: {final_path}")
            print(f"  Size: {final_size:,} bytes")
            print(f"  Matches original: {final_size == file_size}")
        
    finally:
        # Clean up
        if os.path.exists(test_file):
            os.remove(test_file)
            print("\n✓ Cleaned up test file")


if __name__ == "__main__":
    # Set up logging
    import logging
    logging.getLogger("percolate").setLevel(logging.INFO)
    
    print("Testing Filesystem-Only TUS Implementation")
    print("=" * 50)
    
    # Run test
    asyncio.run(test_upload())