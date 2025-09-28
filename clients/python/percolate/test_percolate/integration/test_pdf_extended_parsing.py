#!/usr/bin/env python3
"""
Test PDF parsing in extended mode with OCR capabilities
"""
import os
from pathlib import Path
from percolate.services.FileSystemService import FileSystemService
from percolate.utils.parsing.pdf_handler import get_pdf_handler
from percolate.utils import logger

# Test PDF path
PDF_PATH = "/Users/sirsh/Downloads/test_parsing.pdf"


def test_pdf_simple_vs_extended():
    """Compare simple vs extended parsing modes"""
    print("\n" + "="*80)
    print("Testing PDF Parsing: Simple vs Extended Mode")
    print("="*80)
    
    # Initialize FileSystemService
    fs = FileSystemService()
    
    # Test 1: Simple mode parsing
    print("\n1. SIMPLE MODE PARSING:")
    print("-" * 40)
    
    simple_chunks = list(fs.read_chunks(
        path=PDF_PATH,
        mode='simple',
        chunk_size=1000,
        chunk_overlap=200
    ))
    
    print(f"Number of chunks: {len(simple_chunks)}")
    if simple_chunks:
        print(f"First chunk preview: {simple_chunks[0].content[:200]}...")
        print(f"Total characters: {sum(len(c.content) for c in simple_chunks)}")
    
    # Test 2: Extended mode parsing (with OCR)
    print("\n\n2. EXTENDED MODE PARSING (with OCR):")
    print("-" * 40)
    
    # Check if OpenAI API key is available
    openai_key = os.environ.get('OPENAI_API_KEY')
    if not openai_key:
        print("⚠️  WARNING: OPENAI_API_KEY not set. Extended mode will fall back to simple parsing.")
        print("   Set it with: export OPENAI_API_KEY='your-key-here'")
    else:
        print("✅ OpenAI API key found")
    
    try:
        extended_chunks = list(fs.read_chunks(
            path=PDF_PATH,
            mode='extended',  # This should trigger OCR
            chunk_size=1000,
            chunk_overlap=200
        ))
        
        print(f"Number of chunks: {len(extended_chunks)}")
        if extended_chunks:
            print(f"First chunk preview: {extended_chunks[0].content[:200]}...")
            print(f"Total characters: {sum(len(c.content) for c in extended_chunks)}")
            
            # Check if content is different (indicating OCR was used)
            if simple_chunks and extended_chunks:
                simple_content = ''.join(c.content for c in simple_chunks)
                extended_content = ''.join(c.content for c in extended_chunks)
                
                if simple_content != extended_content:
                    print("\n✅ Extended mode produced DIFFERENT content (OCR was likely used)")
                    print(f"   Simple mode length: {len(simple_content)} chars")
                    print(f"   Extended mode length: {len(extended_content)} chars")
                else:
                    print("\n⚠️  Extended mode produced SAME content (OCR may not have been triggered)")
                    
    except Exception as e:
        print(f"❌ Error in extended mode: {str(e)}")
        import traceback
        traceback.print_exc()


def test_pdf_handler_extended():
    """Test PDF handler's extended content extraction directly"""
    print("\n\n" + "="*80)
    print("Testing PDF Handler Extended Content Extraction")
    print("="*80)
    
    pdf_handler = get_pdf_handler()
    
    # Read PDF file
    with open(PDF_PATH, 'rb') as f:
        pdf_data = pdf_handler.read(f)
    
    print(f"PDF has {pdf_data['num_pages']} pages")
    print(f"Text pages extracted: {len(pdf_data['text_pages'])}")
    
    # Test extended content extraction
    print("\nTesting extract_extended_content method...")
    try:
        extended_content = pdf_handler.extract_extended_content(
            pdf_data=pdf_data,
            file_name="test_parsing.pdf",
            uri=f"file://{PDF_PATH}"
        )
        
        print(f"Extended content length: {len(extended_content)} characters")
        print("\nExtended content preview:")
        print("-" * 40)
        print(extended_content[:500])
        print("-" * 40)
        
        # Check if it contains OCR analysis markers
        if "DOCUMENT ANALYSIS SUMMARY" in extended_content:
            print("\n✅ Extended content includes LLM analysis")
        if "=== PAGE" in extended_content:
            print("✅ Extended content includes page-by-page analysis")
            
    except Exception as e:
        print(f"❌ Error in extended content extraction: {str(e)}")
        import traceback
        traceback.print_exc()


if __name__ == "__main__":
    # Check if PDF exists
    if not Path(PDF_PATH).exists():
        print(f"❌ PDF not found at {PDF_PATH}")
        print("Please ensure test_parsing.pdf is in ~/Downloads/")
        exit(1)
    
    # Run tests
    test_pdf_simple_vs_extended()
    test_pdf_handler_extended()
    
    print("\n\nDone!")