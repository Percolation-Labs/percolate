#!/usr/bin/env python3
"""Test PDF handler registration"""

import sys
sys.path.insert(0, '/Users/sirsh/code/mr_saoirse/percolate/clients/python/percolate')

from percolate.services.FileSystemService import FileSystemService
from percolate.utils.parsing.pdf_handler import HAS_PYPDF, HAS_FITZ

print("PDF Libraries Status:")
print(f"  HAS_PYPDF: {HAS_PYPDF}")
print(f"  HAS_FITZ: {HAS_FITZ}")

# Create FileSystemService and check handlers
fs = FileSystemService()

print(f"\nRegistered handlers: {len(fs._handlers)}")
for i, handler in enumerate(fs._handlers):
    print(f"  {i+1}. {handler.__class__.__name__}")

# Check if PDF handler can handle a PDF file
pdf_path = "test.pdf"
pdf_handler = fs._get_handler(pdf_path)
print(f"\nHandler for '{pdf_path}': {pdf_handler.__class__.__name__ if pdf_handler else 'None'}")

# Test with S3 URI
s3_uri = "s3://res-data-platform/gdrive-sync/v1/1dBLUf0DfR7QmVRnGTyrtzg0o67AfUqeU/Investment_Pitch_Strategy_Lee_Fixel.pdf"
s3_handler = fs._get_handler(s3_uri)
print(f"Handler for S3 PDF: {s3_handler.__class__.__name__ if s3_handler else 'None'}")

# Check if read_chunks method exists
print(f"\nDoes FileSystemService have read_chunks method? {hasattr(fs, 'read_chunks')}")
print(f"FileSystemService methods: {[m for m in dir(fs) if not m.startswith('_') and callable(getattr(fs, m))]}")