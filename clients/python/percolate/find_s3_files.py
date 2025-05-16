"""
EXAMPLES 
=== Finding PDF file ===
    PDF ID: 691d660f-871f-4f25-9fa3-81b7fdff5900
    Filename: test_document.pdf
    S3 URI: s3://test-bucket/test-key/691d660f-871f-4f25-9fa3-81b7fdff5900/test_document.pdf

    === Finding WAV file ===
    WAV ID: 2a04c6e5-f9c5-b331-512a-a87e108b48b0
    Filename: INST_018.wav
    S3 URI: s3://percolate/default/uploads/034368fc-07df-4dc3-8dee-1bdbf6ddcaa7/2a04c6e5-f9c5-b331-512a-a87e108b48b0/INST_018.wav
"""

import percolate as p8
from percolate.models.media.tus import TusFileUpload
from percolate.services.S3Service import S3Service

# Find PDFs that actually exist
print('=== Finding PDFs in S3 ===')
pdfs = p8.repository(TusFileUpload).execute('''
    SELECT id, filename, s3_uri, s3_bucket, s3_key, created_at 
    FROM public."TusFileUpload"
    WHERE s3_uri IS NOT NULL 
    AND LOWER(filename) LIKE '%.pdf'
    AND s3_bucket IS NOT NULL
    AND s3_key IS NOT NULL
    ORDER BY created_at DESC
    LIMIT 5
''')

for pdf in pdfs:
    print(f"\nID: {pdf['id']}")
    print(f"Filename: {pdf['filename']}")
    print(f"S3 URI: {pdf['s3_uri']}")
    print(f"Bucket: {pdf['s3_bucket']}")
    print(f"Key: {pdf['s3_key']}")
    
    # Check if file exists in S3
    s3 = S3Service()
    try:
        exists = s3.file_exists(pdf['s3_bucket'], pdf['s3_key'])
        print(f"Exists in S3: {exists}")
    except Exception as e:
        print(f"Error checking S3: {e}")

print('\n=== Finding WAVs in S3 ===')
wavs = p8.repository(TusFileUpload).execute('''
    SELECT id, filename, s3_uri, s3_bucket, s3_key, created_at 
    FROM public."TusFileUpload"
    WHERE s3_uri IS NOT NULL 
    AND LOWER(filename) LIKE '%.wav'
    AND s3_bucket IS NOT NULL
    AND s3_key IS NOT NULL
    ORDER BY created_at DESC
    LIMIT 5
''')

for wav in wavs:
    print(f"\nID: {wav['id']}")
    print(f"Filename: {wav['filename']}")
    print(f"S3 URI: {wav['s3_uri']}")
    print(f"Bucket: {wav['s3_bucket']}")
    print(f"Key: {wav['s3_key']}")
    
    # Check if file exists in S3
    s3 = S3Service()
    try:
        exists = s3.file_exists(wav['s3_bucket'], wav['s3_key'])
        print(f"Exists in S3: {exists}")
    except Exception as e:
        print(f"Error checking S3: {e}")

# Check if Resources table exists
print('\n=== Checking Resources table ===')
try:
    resources_check = p8.repository('Resources').execute('SELECT COUNT(*) FROM p8."Resources"')
    print(f"Resources table exists with {resources_check[0]['count']} rows")
except Exception as e:
    print(f"Resources table error: {e}")
    
# Try with different schema
try:
    resources_check = p8.repository('Resources').execute('SELECT COUNT(*) FROM public."Resources"')
    print(f"Resources table exists in public schema with {resources_check[0]['count']} rows")
except Exception as e:
    print(f"Resources table error in public schema: {e}")