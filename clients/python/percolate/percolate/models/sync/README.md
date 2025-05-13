# File Synchronization Models

This package contains models for synchronizing files from external providers into Percolate's storage system, enabling content to be ingested and analyzed in a structured manner.

## Overview

The synchronization framework is designed to periodically sync files from multiple external sources (such as Google Drive, Dropbox, Box, etc.) into Percolate's S3 storage. The framework:

1. Authenticates with external providers using OAuth2 
2. Lists files and folders based on user-defined criteria
3. Tracks sync status and timestamps to efficiently update only modified files
4. Syncs files to S3 storage
5. Triggers ingestion of synchronized content into the Percolate knowledge graph

## Model Architecture

### Provider Models

- `SyncProvider`: Abstract base class for all sync providers
- `GoogleDriveProvider`: Implementation for Google Drive
- Extensible to other providers (Box, Dropbox, OneDrive, etc.)

### Sync Models

- `SyncConfig`: Configuration for a sync operation, including provider settings, filters, and scheduling
- `SyncCredential`: Storage for OAuth tokens and refresh tokens with secure handling
- `SyncFile`: Metadata about a file being tracked for synchronization
- `SyncLog`: Log of sync operations for auditing and troubleshooting

## Authentication Flow

The sync system uses OAuth2 with offline access to maintain long-term access to external services:

1. User initiates the authorization flow via the API
2. User consents to scope permissions with `access_type=offline` to enable refresh tokens
3. Tokens are securely stored in the `SyncCredential` model
4. Refresh tokens are used to generate new access tokens when needed
5. Background jobs run with the latest valid tokens to sync content

## Synchronization Process

Each sync operation follows this process:

1. Load sync configuration for the user
2. Authenticate with the provider using stored credentials
3. List files matching configured filters
4. Compare with previously synced files to identify changes
5. Download and sync new/modified files to S3
6. Update sync records with new timestamps and metadata
7. Trigger ingestion process for new/updated content:
   - Text files are ingested directly into resources
   - Audio files (.wav, .mp3) are sent through the audio transcription pipeline
   - Other files are stored in S3 for reference
8. Log the results of the sync operation

## Usage

The models in this package are used by the `FileSync` service, which can be scheduled to run periodically (e.g., daily) to keep content up-to-date.

```python
from percolate.services.sync import FileSync

# Run a sync for a specific user
sync_service = FileSync()
result = sync_service.sync_user_content(user_id="user123")

# Or schedule via the task system
from percolate.services.tasks import TaskManager
task_manager = TaskManager()
task_manager.schedule_task(
    "sync_files",
    schedule="0 1 * * *",  # Daily at 1 AM
    spec={
        "handler": "file_sync",
        "user_id": "user123"
    }
)
```

## How to Test

This section provides instructions for testing the file synchronization system.

### Setting Up Test Environment

1. **Test Database Connection**:
   
   Connect to the test database running on port 15432. The correct way to configure the connection is by setting environment variables:

   ```bash
   # Set the test database port
   export P8_PG_PORT=15432
   
   # Set the test database password from the P8_TEST_BEARER_TOKEN
   export P8_PG_PASSWORD=$P8_TEST_BEARER_TOKEN
   ```

   Then, the PostgresService will automatically use these settings:

   ```python
   import os
   import percolate as p8
   from percolate.services import PostgresService

   # Verify environment variables are set correctly
   print(f"Using database port: {os.environ.get('P8_PG_PORT', '5438')} (should be 15432)")
   print(f"Database password is {'set' if os.environ.get('P8_PG_PASSWORD') else 'NOT SET'}")
   
   # PostgresService will automatically use the environment variables
   pg = PostgresService()
   print(f"Connection string: {pg._connection_string.replace(':PASSWORD_HIDDEN@', ':******@')}")
   
   # Set this as the default database connection
   p8.set_database(pg)
   ```

   Alternatively, you can explicitly provide connection parameters:

   ```python
   import os
   import percolate as p8
   from percolate.services import PostgresService

   # Configure test database connection
   connection_string = "postgresql://percolate:{}@localhost:15432/percolate".format(
       os.environ.get('P8_TEST_BEARER_TOKEN')
   )

   # Initialize connection with explicit connection string
   pg = PostgresService(connection_string=connection_string)
   p8.set_database(pg)
   ```

2. **Register Sync Models in Database**:
   
   Before using the sync functionality, register the models in the database:

   ```python
   from percolate.models.sync import register_sync_models

   # First set environment variables
   import os
   os.environ['P8_PG_PORT'] = '15432'  # Use the test database port
   os.environ['P8_PG_PASSWORD'] = os.environ.get('P8_TEST_BEARER_TOKEN')  # Set password from bearer token
   
   # Register the models (creates tables in the p8 schema)
   registered_models = register_sync_models()
   
   # Check registration results
   for model, result in registered_models.items():
       print(f"{model}: {result}")
   ```

   This will:
   1. Create all necessary tables in the `p8` schema (not in a separate `sync` schema)
   2. Create embedding tables in the `p8_embeddings` schema
   3. Register model fields and entity metadata
   
   If you run into any issues, you can use the test script:
   
   ```bash
   # Set environment variables and run the test script
   export P8_PG_PORT=15432
   export P8_PG_PASSWORD=$P8_TEST_BEARER_TOKEN
   python -m percolate.models.sync.test_connection
   ```

### Authentication Flow

1. **Initial Authentication**:
   ```
   # Access the Google login endpoint with the sync_files flag
   GET /auth/google/login?sync_files=true
   ```

   This will direct you to Google's OAuth consent screen. Ensure you grant:
   - Drive access permissions
   - "Access to maintain even when you're not using the application"

2. **Callback Handling**:
   After granting permission, Google will redirect back to:
   ```
   /auth/google/callback
   ```
   
   The system will:
   - Receive the tokens from Google (including refresh_token)
   - Store the tokens in the database via `SyncCredential` model
   - Redirect to your app or display confirmation

3. **Persistence of Tokens**:
   - Access tokens (short-lived) and refresh tokens (long-lived) are stored in the `SyncCredential` table
   - The schema requires a database with the following tables:
     ```sql
     CREATE TABLE IF NOT EXISTS p8."SyncCredential" (
       id UUID PRIMARY KEY,
       provider VARCHAR NOT NULL,
       userid UUID NOT NULL,
       access_token TEXT NOT NULL,
       refresh_token TEXT,
       token_expiry TIMESTAMP,
       provider_user_id VARCHAR,
       provider_metadata JSONB,
       created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
       updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
     );
     
     CREATE TABLE IF NOT EXISTS p8."SyncConfig" (
       id UUID PRIMARY KEY,
       name VARCHAR NOT NULL,
       provider VARCHAR NOT NULL,
       userid UUID NOT NULL,
       enabled BOOLEAN DEFAULT TRUE,
       sync_interval_hours INTEGER DEFAULT 24,
       last_sync_at TIMESTAMP,
       next_sync_at TIMESTAMP,
       include_folders JSONB,
       exclude_folders JSONB,
       include_file_types JSONB,
       exclude_file_types JSONB,
       provider_config JSONB,
       created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
       updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
     );
     ```

### Running Tests Manually

1. **Set up a sync configuration**:
   ```python
   import uuid
   import percolate as p8
   from percolate.models.sync import SyncConfig
   
   # Create a sync configuration for a specific folder
   config = SyncConfig(
       name="My Documents",
       provider="google_drive",
       userid="your_user_id",  # UUID or string
       include_folders=["Documents", "Work"],  # Optional, will sync everything if empty
       include_file_types=["pdf", "docx", "txt", "wav", "mp3"]  # Optional
   )
   
   # Save the configuration
   p8.repository(SyncConfig).update_records(config)
   ```

2. **Run an immediate sync**:
   ```python
   from percolate.services.sync import FileSync
   
   # Initialize the sync service
   sync_service = FileSync()
   
   # Run a sync for your user
   result = await sync_service.sync_user_content("your_user_id")
   
   # Check the results
   print(f"Sync completed: {result.success}")
   print(f"Files synced: {result.files_synced}")
   print(f"Files failed: {result.files_failed}")
   print(f"Message: {result.message}")
   ```

3. **Test specific folders**:
   ```python
   import asyncio
   from percolate.api.routes.integrations.services.GoogleService import DriveService
   
   async def test_folder_listing():
       # Get credentials for your user
       drive_service = await DriveService.from_user_id("your_user_id")
       
       # List files in a specific folder (use "root" for root folder)
       files = await drive_service.list_files(folder_id="folder_id", recursive=True)
       
       # Print file names
       for file in files:
           print(f"{file['name']} - {file['mimeType']}")
   
   # Run the async function
   asyncio.run(test_folder_listing())
   ```

4. **Check synced files**:
   ```python
   from percolate.models.sync import SyncFile
   import percolate as p8
   
   # Retrieve synced files for your configuration
   synced_files = p8.repository(SyncFile).select(config_id="your_config_id")
   
   # Print details
   for file in synced_files:
       print(f"File: {file.remote_name}")
       print(f"Status: {file.status}")
       print(f"S3 URI: {file.s3_uri}")
       print(f"Last sync: {file.last_sync_at}")
       print("-" * 50)
   ```

5. **Check audio transcriptions** (for .wav and .mp3 files):
   ```python
   from percolate.models.media.audio import AudioFile
   import percolate as p8
   
   # Get all audio files from sync
   audio_files = p8.repository(AudioFile).select()
   
   # Print status and transcriptions
   for audio in audio_files:
       print(f"Audio: {audio.filename}")
       print(f"Status: {audio.status}")
       print(f"S3 URI: {audio.s3_uri}")
       
       # Get chunks and transcriptions
       chunks = p8.repository("AudioChunk").select(audio_file_id=str(audio.id))
       print(f"Chunks: {len(chunks)}")
       
       for chunk in chunks:
           print(f"  Chunk {chunk.id}: {chunk.transcription[:100]}...")
       print("-" * 50)
   ```

### Monitoring

- View sync logs in the `SyncLog` table to monitor the synchronization process
- Check `AudioFile` status for audio transcription progress
- Use the `Resources` table to see ingested content from synced files

### Troubleshooting

- If authentication fails, verify that your Google project has Drive API enabled
- For token refresh errors, check that your app has offline access permission
- If files aren't syncing, verify the filter criteria in your `SyncConfig`
- For audio processing errors, check the `AudioFile` status and metadata for error details

### Complete Test Script

Here's a complete script to test the file sync process from end to end:

```python
import os
import asyncio
import percolate as p8
from percolate.services import PostgresService
from percolate.models.sync import register_sync_models, SyncConfig
from percolate.services.sync import FileSync

async def test_file_sync():
    # 1. Configure and connect to test database
    # Set environment variables first (can be done before running script)
    # os.environ['P8_PG_PORT'] = '15432'
    # os.environ['P8_PG_PASSWORD'] = os.environ.get('P8_TEST_BEARER_TOKEN')
    
    # Verify environment variables
    port = os.environ.get('P8_PG_PORT', '5438')
    password = os.environ.get('P8_PG_PASSWORD')
    
    print(f"Using database port: {port} (should be 15432)")
    print(f"Database password is {'set' if password else 'NOT SET'}")
    
    # Initialize database connection
    pg = PostgresService()
    # Hide password in output
    conn_str = pg._connection_string
    if '@' in conn_str:
        user_part = conn_str.split('@')[0]
        host_part = conn_str.split('@')[1]
        masked = f"{user_part.split(':')[0]}:PASSWORD_HIDDEN@{host_part}"
        print(f"Using connection string: {masked}")
    
    p8.set_database(pg)
    
    # 2. Register models
    register_results = register_sync_models()
    # The register_sync_models function now handles printing results
    
    # 3. Set up the test user
    # For testing, you need to have already authenticated with Google
    # and stored the credentials in the SyncCredential table
    user_id = "your_user_id"  # Replace with your test user ID
    
    # 4. Create a sync configuration for specific folders
    config = SyncConfig(
        name="Test Google Drive Sync",
        provider="google_drive",
        userid=user_id,
        include_folders=["Test"],  # Sync only files in a 'Test' folder
        include_file_types=["pdf", "txt", "docx", "wav", "mp3"]  # Only sync these file types
    )
    p8.repository(SyncConfig).update_records(config)
    print(f"Created sync config with ID: {config.id}")
    
    # 5. Run the sync process
    sync_service = FileSync()
    result = await sync_service.sync_user_content(user_id)
    
    # 6. Print results
    print("\nSync Results:")
    print(f"Success: {result.success}")
    print(f"Files synced: {result.files_synced}")
    print(f"Files failed: {result.files_failed}")
    print(f"Message: {result.message}")
    
    # 7. Check what was synced
    from percolate.models.sync import SyncFile
    synced_files = p8.repository(SyncFile).select(config_id=str(config.id))
    
    print(f"\nSynced {len(synced_files)} files:")
    for file in synced_files:
        print(f"File: {file.remote_name}")
        print(f"Status: {file.status}")
        print(f"S3 URI: {file.s3_uri}")
        print("-" * 50)
    
    # 8. Check if any audio files were processed
    from percolate.models.media.audio import AudioFile
    audio_files = p8.repository(AudioFile).select(userid=user_id)
    
    if audio_files:
        print(f"\nProcessed {len(audio_files)} audio files:")
        for audio in audio_files:
            print(f"Audio: {audio.filename}")
            print(f"Status: {audio.status}")
            
            # Check for transcription chunks
            from percolate.models.media.audio import AudioChunk
            chunks = p8.repository(AudioChunk).select(audio_file_id=str(audio.id))
            
            if chunks:
                print(f"Transcription chunks: {len(chunks)}")
                for chunk in chunks:
                    if chunk.transcription:
                        print(f"  Transcription: {chunk.transcription[:100]}...")
            else:
                print("No transcription chunks found")
                
            print("-" * 50)
    else:
        print("\nNo audio files processed")

# Run the test
if __name__ == "__main__":
    # Ensure environment variables are set before running
    if not os.environ.get('P8_PG_PORT') or not os.environ.get('P8_PG_PASSWORD'):
        print("WARNING: Required environment variables not set!")
        print("Please set the following before running:")
        print("  export P8_PG_PORT=15432")
        print("  export P8_PG_PASSWORD=$P8_TEST_BEARER_TOKEN")
        print("Continuing anyway, but connection may fail...")
    
    asyncio.run(test_file_sync())
```

Save this script as `test_file_sync.py` and run it after you've authenticated with Google.