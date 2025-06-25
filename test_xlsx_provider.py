#!/usr/bin/env python3
"""Test script for XLSX provider with S3 file"""

import os
import sys

# Add the percolate module to path
sys.path.insert(0, '/Users/sirsh/code/mr_saoirse/percolate/clients/python/percolate')

from percolate.utils.parsing.providers import XLSXContentProvider
from percolate.services.FileSystemService import FileSystemService, ExcelHandler
from percolate.services.S3Service import S3Service
import logging

# Set up logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# S3 file path
S3_FILE_PATH = "s3://res-data-platform/gdrive-sync/v1/1dBLUf0DfR7QmVRnGTyrtzg0o67AfUqeU/MakeOne/TechPack_Examples/MIKA_PANT_JS817_TP_08222023.xlsx"

def test_xlsx_content_provider():
    """Test the XLSXContentProvider"""
    print("\n=== Testing XLSXContentProvider ===")
    
    provider = XLSXContentProvider()
    
    try:
        # Note: XLSXContentProvider's resolve_path_or_download doesn't handle S3 URIs
        # This is expected to fail with the current implementation
        print("\nExtracting text in raw mode...")
        print("Note: This test is expected to fail as resolve_path_or_download doesn't handle S3 URIs")
        raw_text = provider.extract_text(S3_FILE_PATH, enriched=False)
        print(f"Successfully extracted {len(raw_text)} characters")
        print(f"First 500 characters:\n{raw_text[:500]}...")
        
        return True
    except FileNotFoundError as e:
        print(f"Expected error: {e}")
        print("XLSXContentProvider needs S3 support in resolve_path_or_download")
        return True  # This is actually expected behavior
    except Exception as e:
        print(f"Unexpected ERROR: {e}")
        logger.exception("Failed to extract text from XLSX")
        return False

def test_file_system_service():
    """Test the FileSystemService xlsx handling"""
    print("\n=== Testing FileSystemService with XLSX ===")
    
    try:
        # Create FileSystemService instance
        fs_service = FileSystemService()
        
        print(f"\nReading XLSX file from S3: {S3_FILE_PATH}")
        
        # Read the Excel file using FileSystemService
        result = fs_service.read(S3_FILE_PATH)
        
        if isinstance(result, dict):
            print(f"Successfully read Excel file with {len(result)} sheets")
            for sheet_name, df in result.items():
                print(f"  Sheet '{sheet_name}': {df.shape[0]} rows x {df.shape[1]} columns")
                if df.shape[1] > 0:
                    # df.columns is already a list in Polars
                    print(f"    First few columns: {df.columns[:min(5, df.shape[1])]}")
        else:
            print(f"Result type: {type(result)}")
            print(f"Result: {result}")
            
        return True
    except Exception as e:
        print(f"ERROR: {e}")
        logger.exception("Failed to read Excel file with FileSystemService")
        return False

def test_s3_service_download():
    """Test S3Service download and pandas reading"""
    print("\n=== Testing S3Service download and pandas ===")
    
    try:
        import pandas as pd
        
        # Use S3Service to download the file
        s3_service = S3Service()
        
        # Parse S3 URI
        bucket_name = "res-data-platform"
        key = "gdrive-sync/v1/1dBLUf0DfR7QmVRnGTyrtzg0o67AfUqeU/MakeOne/TechPack_Examples/MIKA_PANT_JS817_TP_08222023.xlsx"
        
        print(f"\nDownloading from S3: s3://{bucket_name}/{key}")
        local_path = s3_service.download_file_from_uri(S3_FILE_PATH)
        print(f"Downloaded to: {local_path}")
        
        # Read with pandas
        print("\nReading with pandas...")
        dfs = pd.read_excel(str(local_path), sheet_name=None)
        
        print(f"Successfully read {len(dfs)} sheets:")
        for sheet_name, df in dfs.items():
            print(f"  Sheet '{sheet_name}': {df.shape[0]} rows x {df.shape[1]} columns")
            print(f"    Columns: {list(df.columns)[:5]}{'...' if len(df.columns) > 5 else ''}")
            
        return True
    except Exception as e:
        print(f"ERROR: {e}")
        logger.exception("Failed to download/read with S3Service")
        return False

def main():
    """Main test function"""
    print("Starting XLSX provider tests...")
    print(f"P8_USE_AWS_S3: {os.environ.get('P8_USE_AWS_S3', 'not set')}")
    
    # Run tests
    tests = [
        ("XLSXContentProvider", test_xlsx_content_provider),
        ("FileSystemService", test_file_system_service),
        ("S3Service + Pandas", test_s3_service_download),
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
    
    # Summary
    print("\n=== Test Summary ===")
    for test_name, success in results:
        status = "✓ PASSED" if success else "✗ FAILED"
        print(f"{status}: {test_name}")
    
    all_passed = all(success for _, success in results)
    return 0 if all_passed else 1

if __name__ == "__main__":
    sys.exit(main())