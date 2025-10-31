#!/usr/bin/env python3
"""
Test resource_creator controller with extended parsing
"""
import asyncio
import os
from pathlib import Path
from unittest.mock import Mock
import percolate as p8
from percolate.models.p8.types import Resources
from percolate.models.media.tus import TusFileUpload
from percolate.api.controllers.resource_creator import create_resources_from_upload

# Test PDF path
PDF_PATH = "/Users/sirsh/Downloads/test_parsing.pdf"


async def test_resource_creator_controller():
    """Test the resource creator controller directly"""
    print("\n" + "="*80)
    print("Testing Resource Creator Controller - Extended Mode")
    print("="*80)
    
    # Check OpenAI key
    if not os.environ.get('OPENAI_API_KEY'):
        print("⚠️  WARNING: OPENAI_API_KEY not set. Extended mode will fall back.")
    
    # First, let's check the current default mode in resource_creator.py
    print("\n1. Checking current mode selection logic:")
    print("-" * 40)
    
    # Show the relevant code
    creator_path = Path(__file__).parent.parent.parent / "api/controllers/resource_creator.py"
    with open(creator_path, 'r') as f:
        lines = f.readlines()
        for i, line in enumerate(lines[85:92]):  # Lines around mode selection
            print(f"{86+i}: {line.rstrip()}")
    
    # Create a mock TUS upload for testing
    mock_upload = TusFileUpload(
        id="test_upload_123",
        filename="test_parsing.pdf", 
        content_type="application/pdf",
        s3_uri=f"file://{PDF_PATH}",  # Use local file
        userid="test_user",
        total_size=os.path.getsize(PDF_PATH),
        uploaded_size=os.path.getsize(PDF_PATH)
    )
    
    # Save the mock upload
    saved = p8.repository(TusFileUpload).update_records(mock_upload)
    print(f"\n2. Created test upload: {mock_upload.id}")
    
    # Test with current mode (should be 'simple' for PDFs)
    print("\n3. Testing with CURRENT mode (simple):")
    print("-" * 40)
    
    try:
        resources = await create_resources_from_upload(
            upload_id=mock_upload.id,
            save_resources=False  # Don't save to DB yet
        )
        
        print(f"✅ Created {len(resources)} chunks")
        if resources:
            print(f"   First chunk length: {len(resources[0].content)} chars")
            print(f"   Total content: {sum(len(r.content) for r in resources)} chars")
            
    except Exception as e:
        print(f"❌ Error: {str(e)}")
    
    # Now let's modify the mode to 'extended' and test
    print("\n4. Testing with EXTENDED mode (modified):")
    print("-" * 40)
    
    # We'll need to temporarily patch the mode selection
    # For now, let's just show what would need to change
    print("To enable extended mode by default, change line 89-90 to:")
    print("   # Use extended mode for all files by default")
    print("   mode = 'extended'")
    print("   # Optionally keep simple mode for very large files")
    print("   # if file_size > 50_000_000:  # 50MB")
    print("   #     mode = 'simple'")
    
    # Clean up
    p8.repository(TusFileUpload).delete(id=mock_upload.id)


def test_chunk_count():
    """Test that extended mode produces reasonable chunk count"""
    print("\n\n" + "="*80)
    print("Testing Chunk Count for Extended Mode")
    print("="*80)
    
    from percolate.services.FileSystemService import FileSystemService
    fs = FileSystemService()
    
    # Test with larger chunk size to get < 20 chunks
    chunk_sizes = [1000, 2000, 3000]
    
    for chunk_size in chunk_sizes:
        print(f"\nTesting with chunk_size={chunk_size}:")
        chunks = list(fs.read_chunks(
            path=PDF_PATH,
            mode='simple',  # Start with simple
            chunk_size=chunk_size,
            chunk_overlap=200
        ))
        print(f"  Simple mode: {len(chunks)} chunks")
        
        # Don't run extended in loop to avoid timeout
        if chunk_size == 2000:
            print("\n  Extended mode test (chunk_size=2000):")
            print("  (This will use OCR and take longer...)")
            try:
                extended_chunks = list(fs.read_chunks(
                    path=PDF_PATH,
                    mode='extended',
                    chunk_size=chunk_size,
                    chunk_overlap=200
                ))
                print(f"  Extended mode: {len(extended_chunks)} chunks")
                
                if len(extended_chunks) < 20:
                    print(f"  ✅ Good! Less than 20 chunks ({len(extended_chunks)})")
                else:
                    print(f"  ⚠️  Warning: {len(extended_chunks)} chunks (>= 20)")
                    
            except Exception as e:
                print(f"  ❌ Extended mode error: {str(e)}")


if __name__ == "__main__":
    # Check if PDF exists
    if not Path(PDF_PATH).exists():
        print(f"❌ PDF not found at {PDF_PATH}")
        exit(1)
    
    # Run async test
    asyncio.run(test_resource_creator_controller())
    
    # Run chunk count test
    test_chunk_count()
    
    print("\n\nDone!")