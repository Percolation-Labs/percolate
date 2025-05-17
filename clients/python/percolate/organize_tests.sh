#!/bin/bash

# Script to organize test files into active and deprecated directories
# Usage: ./organize_tests.sh [--dry-run]

DRY_RUN=false
if [ "$1" == "--dry-run" ]; then
    DRY_RUN=true
    echo "DRY RUN MODE - No files will be moved"
fi

# Create deprecated directory structure
if [ "$DRY_RUN" == false ]; then
    mkdir -p .deprecated/auth
    mkdir -p .deprecated/tus
    mkdir -p .deprecated/s3
    mkdir -p .deprecated/audio
    mkdir -p .deprecated/resource_creator
    mkdir -p .deprecated/session
fi

# Function to move file with logging
move_file() {
    local src=$1
    local dest=$2
    
    if [ -f "$src" ]; then
        echo "Moving: $src -> $dest"
        if [ "$DRY_RUN" == false ]; then
            mv "$src" "$dest"
        fi
    else
        echo "Warning: File not found: $src"
    fi
}

echo "=== Organizing Test Files ==="

# Auth/Session related deprecated files
echo -e "\n--- Moving deprecated auth/session tests ---"
move_file ".aiscripts/test_auth_system.py" ".deprecated/auth/"
move_file ".aiscripts/test_fresh_session.py" ".deprecated/session/"
move_file ".aiscripts/test_session_persistence.py" ".deprecated/session/"
move_file ".aiscripts/test_session_verification.py" ".deprecated/session/"
move_file ".aiscripts/verify_session_fix.py" ".deprecated/session/"
move_file ".aiscripts/demo_session_fix.py" ".deprecated/session/"
move_file ".aiscripts/debug_session_contents.py" ".deprecated/session/"

# TUS related deprecated files  
echo -e "\n--- Moving deprecated TUS tests ---"
move_file ".eepis/test_tus_https_fix.py" ".deprecated/tus/"
move_file ".eepis/test_upload_simple.py" ".deprecated/tus/"
move_file ".aiscripts/test_tus_curl.sh" ".deprecated/tus/"
move_file ".aiscripts/test_tus_db.py" ".deprecated/tus/"
move_file ".aiscripts/verify_tus_uploads.py" ".deprecated/tus/"
move_file ".eepis/tus_location_fix.py" ".deprecated/tus/"

# S3 related deprecated files
echo -e "\n--- Moving deprecated S3 tests ---"
move_file ".eepis/test_s3_direct.py" ".deprecated/s3/"
move_file ".eepis/test_s3_minimal.py" ".deprecated/s3/"
move_file ".eepis/s3_service_patch.py" ".deprecated/s3/"

# Audio related deprecated files
echo -e "\n--- Moving deprecated audio tests ---"
move_file ".aiscripts/test_audio_api_end_to_end.py" ".deprecated/audio/"
move_file ".aiscripts/test_transcription_endpoint.py" ".deprecated/audio/"
move_file ".aiscripts/check_audio_upload.py" ".deprecated/audio/"
move_file ".aiscripts/check_audio_chunks.py" ".deprecated/audio/"
move_file ".aiscripts/check_audio_file.py" ".deprecated/audio/"
move_file ".aiscripts/create_test_chunks.py" ".deprecated/audio/"
move_file ".aiscripts/audio_transcription_test.py" ".deprecated/audio/"
move_file ".aiscripts/test_large_file_transcription.py" ".deprecated/audio/"
move_file ".aiscripts/check_for_chunks.py" ".deprecated/audio/"
move_file ".aiscripts/fix_transcriptions.py" ".deprecated/audio/"
move_file ".aiscripts/debug_audio_api.py" ".deprecated/audio/"

# Resource creator deprecated files
echo -e "\n--- Moving deprecated resource creator tests ---"
move_file ".aiscripts/test_resource_creator.py" ".deprecated/resource_creator/"
move_file ".aiscripts/test_resource_creator_demo.py" ".deprecated/resource_creator/"
move_file ".aiscripts/test_resource_creator_e2e.py" ".deprecated/resource_creator/"
move_file ".aiscripts/test_resource_creator_mock.py" ".deprecated/resource_creator/"
move_file ".aiscripts/verify_controller_saving.py" ".deprecated/resource_creator/"

# Create index file for deprecated tests
if [ "$DRY_RUN" == false ]; then
    echo "# Deprecated Tests" > .deprecated/README.md
    echo "" >> .deprecated/README.md
    echo "This directory contains deprecated test files that have been superseded by newer implementations." >> .deprecated/README.md
    echo "" >> .deprecated/README.md
    echo "## Directory Structure:" >> .deprecated/README.md
    echo "- auth/ - Old authentication tests" >> .deprecated/README.md
    echo "- session/ - Old session management tests" >> .deprecated/README.md
    echo "- tus/ - Old TUS upload tests" >> .deprecated/README.md
    echo "- s3/ - Old S3 integration tests" >> .deprecated/README.md
    echo "- audio/ - Old audio processing tests" >> .deprecated/README.md
    echo "- resource_creator/ - Old resource creator tests" >> .deprecated/README.md
    echo "" >> .deprecated/README.md
    echo "These files are kept for reference but should not be used for active testing." >> .deprecated/README.md
fi

echo -e "\n=== Organization Complete ==="
echo "Active tests remain in .eepis/ and .aiscripts/"
echo "Deprecated tests moved to .deprecated/"

if [ "$DRY_RUN" == true ]; then
    echo -e "\nThis was a dry run. Run without --dry-run to actually move files."
fi