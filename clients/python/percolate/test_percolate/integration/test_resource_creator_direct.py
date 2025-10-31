#!/usr/bin/env python3
"""
Direct integration test for resource creator with extended mode
"""
import asyncio
import os
from pathlib import Path
import sys

# Add the package to the path
sys.path.insert(0, str(Path(__file__).parent.parent.parent))

import percolate as p8
from percolate.models.media.tus import TusFileUpload
from percolate.api.controllers.resource_creator import create_resources_from_upload
from percolate.services.FileSystemService import FileSystemService

# Test PDF path
PDF_PATH = "/Users/sirsh/Downloads/test_parsing.pdf"


async def test_create_resources_extended_mode():
    """Test resource creation with extended mode directly"""
    print("\n" + "="*80)
    print("Direct Integration Test - Resource Creator Extended Mode")
    print("="*80)
    
    # Check prerequisites
    if not Path(PDF_PATH).exists():
        print(f"❌ PDF not found at {PDF_PATH}")
        return
    
    if not os.environ.get('OPENAI_API_KEY'):
        print("⚠️  WARNING: OPENAI_API_KEY not set. Extended mode will fall back to simple extraction.")
    else:
        print("✅ OpenAI API key is set - OCR will be used")
    
    # Create a mock TUS upload record
    file_size = os.path.getsize(PDF_PATH)
    mock_upload = TusFileUpload(
        id="test_extended_upload",
        filename="test_parsing.pdf",
        content_type="application/pdf", 
        s3_uri=f"file://{PDF_PATH}",  # Use local file path
        upload_uri=f"file://{PDF_PATH}",  # Required field
        userid="test_extended_user",
        total_size=file_size,
        uploaded_size=file_size,
        project_name="test_project",
        upload_metadata={"test": "extended_mode"}
    )
    
    # Save the mock upload to database
    print(f"\n1. Creating mock upload record...")
    try:
        p8.repository(TusFileUpload).update_records(mock_upload)
        print(f"✅ Created upload: {mock_upload.id}")
    except Exception as e:
        print(f"❌ Failed to create upload: {e}")
        return
    
    # Call create_resources_from_upload
    print(f"\n2. Processing with create_resources_from_upload...")
    print("   (This will use extended mode with OCR)")
    
    try:
        resources = await create_resources_from_upload(
            upload_id=mock_upload.id,
            save_resources=False  # Don't save to DB, just return them
        )
        
        print(f"\n✅ Created {len(resources)} resource chunks")
        
        # Analyze the chunks
        print("\n3. Analyzing chunks:")
        print("-" * 40)
        
        if len(resources) < 20:
            print(f"✅ Good! Less than 20 chunks ({len(resources)} chunks)")
        else:
            print(f"⚠️  Warning: {len(resources)} chunks (>= 20)")
        
        # Check metadata to confirm mode
        if resources:
            metadata = resources[0].metadata
            print(f"\nFirst chunk metadata:")
            print(f"  Parsing mode: {metadata.get('parsing_mode', 'unknown')}")
            print(f"  Chunk size: {metadata.get('chunk_size')}")
            print(f"  Total chunks: {metadata.get('total_chunks')}")
            
        # Analyze content
        total_chars = sum(len(r.content) for r in resources)
        print(f"\nContent analysis:")
        print(f"  Total characters: {total_chars}")
        
        # Check first few chunks for OCR markers
        has_ocr_content = False
        for i, resource in enumerate(resources[:3]):
            print(f"\nChunk {i+1}:")
            print(f"  Name: {resource.name}")
            print(f"  Length: {len(resource.content)} chars")
            
            # Check for extended mode markers
            if "=== PAGE" in resource.content or "DOCUMENT ANALYSIS" in resource.content:
                has_ocr_content = True
                print("  ✅ Contains OCR/extended mode content")
            
            print(f"  Preview: {resource.content[:150]}...")
        
        if has_ocr_content:
            print("\n✅ Extended mode OCR processing confirmed!")
        else:
            print("\n⚠️  No clear OCR markers found. Check if OPENAI_API_KEY is set.")
            
    except Exception as e:
        print(f"❌ Error processing: {e}")
        import traceback
        traceback.print_exc()
    
    finally:
        # Clean up
        print("\n4. Cleaning up...")
        try:
            p8.repository(TusFileUpload).delete(id=mock_upload.id)
            print("✅ Cleaned up test upload")
        except:
            pass


def test_filesystem_service_modes():
    """Compare simple vs extended mode directly"""
    print("\n\n" + "="*80)
    print("FileSystemService Mode Comparison")
    print("="*80)
    
    fs = FileSystemService()
    
    # Test simple mode
    print("\n1. Simple mode:")
    simple_chunks = list(fs.read_chunks(
        path=PDF_PATH,
        mode='simple',
        chunk_size=2000,
        chunk_overlap=200
    ))
    print(f"  Chunks: {len(simple_chunks)}")
    print(f"  Total chars: {sum(len(c.content) for c in simple_chunks)}")
    
    # Test extended mode  
    print("\n2. Extended mode:")
    print("  (Processing with OCR - this may take 30-60 seconds...)")
    
    try:
        extended_chunks = list(fs.read_chunks(
            path=PDF_PATH,
            mode='extended',
            chunk_size=2000,
            chunk_overlap=200
        ))
        print(f"  Chunks: {len(extended_chunks)}")
        print(f"  Total chars: {sum(len(c.content) for c in extended_chunks)}")
        
        # Compare content
        if extended_chunks and simple_chunks:
            extended_content = extended_chunks[0].content[:200]
            simple_content = simple_chunks[0].content[:200]
            
            if extended_content != simple_content:
                print("\n✅ Extended mode produced different (richer) content!")
            else:
                print("\n⚠️  Content appears similar - OCR may not have activated")
                
    except Exception as e:
        print(f"  ❌ Error in extended mode: {e}")


if __name__ == "__main__":
    # Run the async test
    print("Running integration tests...")
    asyncio.run(test_create_resources_extended_mode())
    
    # Run the direct comparison
    test_filesystem_service_modes()
    
    print("\n\nDone!")