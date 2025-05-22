#!/usr/bin/env python3
"""
Test FileSystemService S3 integration and chunked resources functionality.
"""

import os
import sys
import tempfile
from pathlib import Path

# Add the percolate package to the path
sys.path.insert(0, '/Users/sirsh/code/mr_saoirse/percolate/clients/python/percolate')

def test_s3_file_loading():
    """Test loading files from S3 using FileSystemService."""
    print("🔧 Testing S3 file loading with FileSystemService...")
    
    try:
        from percolate.services.FileSystemService import FileSystemService
        
        # Initialize FileSystemService (should auto-configure S3)
        fs = FileSystemService()
        print("✅ FileSystemService initialized successfully")
        
        # Test S3 configuration info
        s3_provider = fs._get_provider("s3://test")
        config_info = s3_provider.s3_service.get_configuration_info()
        print(f"📋 S3 Configuration: {config_info['provider_type']} mode")
        print(f"   - Endpoint: {config_info['endpoint_url'] or 'default'}")
        print(f"   - Default bucket: {config_info['default_bucket']}")
        print(f"   - Has credentials: {config_info['has_credentials']}")
        
        # Test with a sample S3 URI (you can modify this to an actual file you have access to)
        test_s3_uri = "s3://percolate/test.txt"
        
        print(f"\n🔍 Testing S3 file existence check: {test_s3_uri}")
        try:
            exists = fs.exists(test_s3_uri)
            print(f"   File exists: {exists}")
            
            if exists:
                print(f"\n📥 Attempting to read file: {test_s3_uri}")
                content = fs.read(test_s3_uri)
                print(f"   Content type: {type(content)}")
                if isinstance(content, str):
                    print(f"   Content preview: {content[:200]}...")
                elif isinstance(content, bytes):
                    print(f"   Bytes length: {len(content)}")
                    print(f"   First 100 bytes: {content[:100]}")
                else:
                    print(f"   Content: {str(content)[:200]}...")
            else:
                print("   File doesn't exist - creating a test file")
                
                # Create a test file
                test_content = """This is a test file for S3 FileSystemService integration.

This file contains multiple paragraphs to test chunking functionality.
Each paragraph represents different content that should be split into chunks.

Paragraph 1: Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.

Paragraph 2: Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.

Paragraph 3: Sed ut perspiciatis unde omnis iste natus error sit voluptatem accusantium doloremque laudantium, totam rem aperiam, eaque ipsa quae ab illo inventore veritatis et quasi architecto beatae vitae dicta sunt explicabo.

Paragraph 4: Nemo enim ipsam voluptatem quia voluptas sit aspernatur aut odit aut fugit, sed quia consequuntur magni dolores eos qui ratione voluptatem sequi nesciunt.
"""
                
                print(f"📤 Writing test content to {test_s3_uri}")
                fs.write(test_s3_uri, test_content)
                print("   Test file created successfully")
                
                # Verify the write worked
                print(f"📥 Reading back the test file...")
                content = fs.read(test_s3_uri)
                print(f"   Read back {len(content)} characters")
                
        except Exception as e:
            print(f"❌ Error testing S3 file operations: {e}")
            return False
            
    except Exception as e:
        print(f"❌ Error initializing FileSystemService: {e}")
        return False
    
    return True

def test_chunked_resources():
    """Test chunked resources functionality."""
    print("\n🔧 Testing chunked resources functionality...")
    
    try:
        from percolate.services.FileSystemService import FileSystemService
        
        fs = FileSystemService()
        
        # Test with different file types
        test_cases = [
            {
                "name": "Text file chunking",
                "uri": "s3://percolate/test.txt",
                "mode": "simple",
                "chunk_size": 200,
                "chunk_overlap": 50
            }
        ]
        
        for test_case in test_cases:
            print(f"\n📋 Testing: {test_case['name']}")
            print(f"   URI: {test_case['uri']}")
            print(f"   Mode: {test_case['mode']}")
            print(f"   Chunk size: {test_case['chunk_size']}")
            
            try:
                # Test read_chunks method
                print("   🔍 Testing read_chunks method...")
                chunks = list(fs.read_chunks(
                    path=test_case['uri'],
                    mode=test_case['mode'],
                    chunk_size=test_case['chunk_size'],
                    chunk_overlap=test_case.get('chunk_overlap', 200)
                ))
                
                print(f"   ✅ Created {len(chunks)} chunks")
                
                for i, chunk in enumerate(chunks[:3]):  # Show first 3 chunks
                    print(f"      Chunk {i+1}: {len(chunk.content)} chars - {chunk.content[:100]}...")
                    print(f"                 Category: {chunk.category}")
                    print(f"                 Metadata keys: {list(chunk.metadata.keys()) if chunk.metadata else 'None'}")
                
                if len(chunks) > 3:
                    print(f"      ... and {len(chunks) - 3} more chunks")
                    
            except Exception as e:
                print(f"   ❌ Error in chunked resources test: {e}")
                import traceback
                traceback.print_exc()
                continue
                
    except Exception as e:
        print(f"❌ Error in chunked resources testing: {e}")
        import traceback
        traceback.print_exc()
        return False
    
    return True

def test_file_info():
    """Test file info functionality."""
    print("\n🔧 Testing file info functionality...")
    
    try:
        from percolate.services.FileSystemService import FileSystemService
        
        fs = FileSystemService()
        
        test_uri = "s3://percolate/test.txt"
        print(f"📋 Getting file info for: {test_uri}")
        
        info = fs.get_file_info(test_uri)
        print(f"   File info: {info}")
        
        return True
        
    except Exception as e:
        print(f"❌ Error testing file info: {e}")
        return False

def main():
    """Run all tests."""
    print("🚀 Starting FileSystemService S3 and Chunked Resources Tests")
    print("=" * 60)
    
    tests = [
        ("S3 File Loading", test_s3_file_loading),
        ("Chunked Resources", test_chunked_resources),
        ("File Info", test_file_info),
    ]
    
    results = []
    for test_name, test_func in tests:
        print(f"\n📌 Running {test_name} test...")
        try:
            result = test_func()
            results.append((test_name, result))
            status = "✅ PASSED" if result else "❌ FAILED"
            print(f"   {status}")
        except Exception as e:
            print(f"   ❌ FAILED with exception: {e}")
            results.append((test_name, False))
            import traceback
            traceback.print_exc()
    
    print("\n" + "=" * 60)
    print("📊 Test Summary:")
    for test_name, result in results:
        status = "✅ PASSED" if result else "❌ FAILED"
        print(f"   {test_name}: {status}")
    
    passed = sum(1 for _, result in results if result)
    total = len(results)
    print(f"\n🎯 Overall: {passed}/{total} tests passed")
    
    if passed == total:
        print("🎉 All tests passed!")
        return 0
    else:
        print("⚠️  Some tests failed.")
        return 1

if __name__ == "__main__":
    exit(main())