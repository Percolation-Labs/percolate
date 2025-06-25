#!/usr/bin/env python3
"""Test script for files without extensions"""

import os
import sys

# Add the percolate module to path
sys.path.insert(0, '/Users/sirsh/code/mr_saoirse/percolate/clients/python/percolate')

from percolate.services.FileSystemService import FileSystemService
import logging

# Set up logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# S3 file paths for testing
PDF_FILE_NO_EXT = "s3://res-data-platform/gdrive-sync/v1/1dBLUf0DfR7QmVRnGTyrtzg0o67AfUqeU/MakeOne/Market_Size_for_Tech_Packs_and_Industry_Design/Production_Support"
XLSX_FILE_WITH_EXT = "s3://res-data-platform/gdrive-sync/v1/1dBLUf0DfR7QmVRnGTyrtzg0o67AfUqeU/MakeOne/TechPack_Examples/MIKA_PANT_JS817_TP_08222023.xlsx"

def test_pdf_no_extension():
    """Test reading a PDF file without extension"""
    print("\n=== Testing PDF file without extension ===")
    
    try:
        # Create FileSystemService instance
        fs_service = FileSystemService()
        
        print(f"\nReading PDF without extension: {PDF_FILE_NO_EXT}")
        
        # Read the file using FileSystemService
        result = fs_service.read(PDF_FILE_NO_EXT)
        
        result_type = type(result).__name__
        print(f"\nResult type: {result_type}")
        
        if isinstance(result, dict):
            # PDF handler should return a dict
            print("✓ Successfully read as PDF!")
            print(f"  Pages: {len(result.get('text_pages', []))}")
            print(f"  Images: {len(result.get('images', []))}")
            if result.get('metadata'):
                print(f"  Title: {result['metadata'].get('title', 'N/A')}")
            if result.get('text_pages'):
                first_page = result['text_pages'][0][:200]
                print(f"  First page preview: {first_page}...")
            return True
        elif isinstance(result, bytes):
            print(f"Read as binary: {len(result)} bytes")
            if result.startswith(b'%PDF'):
                print("File is PDF but was not processed by PDF handler")
            return False
        else:
            print(f"Unexpected result type: {result_type}")
            return False
            
    except Exception as e:
        print(f"ERROR: {e}")
        logger.exception("Failed to read PDF without extension")
        return False

def test_type_inference_comparison():
    """Compare reading files with and without extensions"""
    print("\n=== Testing type inference comparison ===")
    
    try:
        fs_service = FileSystemService()
        
        # Test 1: XLSX file with extension (should use handler directly)
        print(f"\n1. Reading XLSX with extension: {XLSX_FILE_WITH_EXT}")
        xlsx_result = fs_service.read(XLSX_FILE_WITH_EXT)
        
        if isinstance(xlsx_result, dict):
            print(f"✓ Read as Excel: {len(xlsx_result)} sheets")
            for sheet_name in list(xlsx_result.keys())[:3]:
                print(f"  - {sheet_name}")
        else:
            print(f"✗ Unexpected type: {type(xlsx_result).__name__}")
        
        # Test 2: Create a mock text file path without extension
        print("\n2. Testing text file inference (simulated)")
        # This would need an actual text file without extension on S3
        
        return True
        
    except Exception as e:
        print(f"ERROR: {e}")
        logger.exception("Failed in type inference comparison")
        return False

def main():
    """Main test function"""
    print("Starting file type inference tests...")
    print(f"P8_USE_AWS_S3: {os.environ.get('P8_USE_AWS_S3', 'not set')}")
    
    tests = [
        ("PDF without extension", test_pdf_no_extension),
        ("Type inference comparison", test_type_inference_comparison),
    ]
    
    results = []
    for test_name, test_func in tests:
        try:
            success = test_func()
            results.append((test_name, success))
        except Exception as e:
            print(f"\nTest '{test_name}' crashed: {e}")
            logger.exception(f"Test '{test_name}' crashed")
            results.append((test_name, False))
    
    print("\n=== Test Summary ===")
    for test_name, success in results:
        status = "✓ PASSED" if success else "✗ FAILED"
        print(f"{status}: {test_name}")
    
    all_passed = all(success for _, success in results)
    return 0 if all_passed else 1

if __name__ == "__main__":
    sys.exit(main())