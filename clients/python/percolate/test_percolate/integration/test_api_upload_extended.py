#!/usr/bin/env python3
"""
Integration test for API upload with extended mode parsing
"""
import os
import requests
import time
import sys
from pathlib import Path

# Add the package to the path
sys.path.insert(0, str(Path(__file__).parent.parent.parent))

import percolate as p8
from percolate.models.p8.types import Resources

# Configuration
API_URL = "http://localhost:5008"
PDF_PATH = "/Users/sirsh/Downloads/test_parsing.pdf"
BEARER_TOKEN = os.environ.get("P8_TEST_BEARER_TOKEN", "p8-HsByeefq3unTFJDuf6cRh6GDQpo3laj0AMoyc2Etfqma6Coz73TdBPDfek_LQIMv")


def test_api_upload_extended():
    """Test uploading PDF to API and verify extended mode processing"""
    print("\n" + "="*80)
    print("Testing API Upload with Extended Mode")
    print("="*80)
    
    # Check prerequisites
    if not Path(PDF_PATH).exists():
        print(f"❌ PDF not found at {PDF_PATH}")
        return False
        
    if not os.environ.get('OPENAI_API_KEY'):
        print("⚠️  WARNING: OPENAI_API_KEY not set. Extended mode OCR will not work!")
        print("   Set it with: export OPENAI_API_KEY='your-key-here'")
    
    # Check if API is running
    try:
        response = requests.get(f"{API_URL}/health")
        if response.status_code != 200:
            raise Exception("API not healthy")
        print("✅ API is running")
    except Exception as e:
        print(f"❌ API is not running at {API_URL}")
        print("   Start it with:")
        print("   cd /Users/sirsh/code/mr_saoirse/percolate/clients/python/percolate")
        print("   poetry shell")
        print("   source set_res_env.sh") 
        print("   uvicorn percolate.api.main:app --port 5008 --reload")
        return False
    
    # Upload the PDF
    print(f"\n1. Uploading PDF: {PDF_PATH}")
    print("-" * 40)
    
    task_id = f"test_extended_{int(time.time())}"
    
    with open(PDF_PATH, 'rb') as f:
        files = {'file': ('test_parsing.pdf', f, 'application/pdf')}
        data = {
            'add_resource': 'true',
            'task_id': task_id,
            'user_id': 'test_extended_user',
            'namespace': 'p8',
            'entity_name': 'Resources'
        }
        headers = {
            'Authorization': f'Bearer {BEARER_TOKEN}'
        }
        
        response = requests.post(
            f"{API_URL}/admin/content/upload",
            files=files,
            data=data,
            headers=headers
        )
    
    if response.status_code != 200:
        print(f"❌ Upload failed: {response.status_code}")
        print(f"   Response: {response.text}")
        return False
        
    result = response.json()
    print(f"✅ Upload successful!")
    print(f"   Key: {result.get('key')}")
    print(f"   Size: {result.get('size')} bytes")
    
    # Wait for background processing
    print("\n2. Waiting for extended mode processing (OCR)...")
    print("   (This may take 30-60 seconds due to OCR analysis)")
    time.sleep(30)  # Extended mode takes longer
    
    # Check the database
    print("\n3. Checking database for chunks...")
    print("-" * 40)
    
    # Query for resources
    recent_resources = p8.repository(Resources).select(
        userid='test_extended_user',
        limit=50
    )
    
    # Find chunks for our upload
    pdf_chunks = [r for r in recent_resources if task_id in str(r.get('uri', ''))]
    
    print(f"Found {len(pdf_chunks)} chunks for this upload")
    
    if len(pdf_chunks) == 0:
        print("⚠️  No chunks found. Processing may still be in progress.")
        return False
    
    if len(pdf_chunks) < 20:
        print(f"✅ Good! Less than 20 chunks ({len(pdf_chunks)} chunks)")
    else:
        print(f"⚠️  Warning: {len(pdf_chunks)} chunks (>= 20)")
    
    # Analyze the content
    print("\n4. Analyzing chunk content...")
    print("-" * 40)
    
    total_content_length = 0
    has_ocr_markers = False
    
    for i, chunk in enumerate(pdf_chunks[:3]):  # First 3 chunks
        content = chunk.get('content', '')
        total_content_length += len(content)
        
        print(f"\nChunk {i+1}:")
        print(f"  Name: {chunk.get('name')}")
        print(f"  Length: {len(content)} chars")
        
        # Check for OCR/extended mode markers
        if "PAGE" in content and "===" in content:
            has_ocr_markers = True
            print("  ✅ Contains OCR page markers")
        
        # Check content type
        if isinstance(content, bytes):
            print(f"  ❌ Content is BINARY!")
        else:
            print(f"  ✅ Content is TEXT")
            print(f"  Preview: {content[:150]}...")
    
    if has_ocr_markers:
        print("\n✅ Extended mode OCR processing detected!")
    else:
        print("\n⚠️  No clear OCR markers found. Mode may have fallen back to simple.")
    
    print(f"\nTotal content length: {total_content_length} characters")
    
    # Check metadata
    if pdf_chunks:
        metadata = pdf_chunks[0].get('metadata', {})
        if metadata:
            print(f"\nMetadata:")
            print(f"  Parsing mode: {metadata.get('parsing_mode', 'unknown')}")
            print(f"  Chunk size: {metadata.get('chunk_size')}")
            print(f"  Total chunks: {metadata.get('total_chunks')}")
    
    return True


def cleanup_test_data():
    """Clean up test data from database"""
    print("\n5. Cleaning up test data...")
    try:
        # Delete test resources
        p8.repository(Resources).execute(
            "DELETE FROM p8.\"Resources\" WHERE userid = 'test_extended_user'"
        )
        print("✅ Cleaned up test resources")
    except Exception as e:
        print(f"⚠️  Cleanup error: {e}")


if __name__ == "__main__":
    # Run the test
    success = test_api_upload_extended()
    
    if success:
        cleanup_test_data()
        print("\n✅ Test completed successfully!")
    else:
        print("\n❌ Test failed!")
    
    print("\nDone!")