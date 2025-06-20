#!/usr/bin/env python3
"""
Script to check the uploaded audio file from S3 and diagnose the transcription issue.
"""

import os
import sys
import wave
import struct
from percolate.services.S3Service import S3Service

def check_wav_header(file_path):
    """Check if a WAV file has a valid header."""
    print(f"\nChecking WAV file: {file_path}")
    print(f"File size: {os.path.getsize(file_path)} bytes")
    
    try:
        # Read the first 44 bytes (standard WAV header size)
        with open(file_path, 'rb') as f:
            header = f.read(44)
            
        if len(header) < 44:
            print("ERROR: File is too small to be a valid WAV file")
            return False
            
        # Check RIFF header
        riff = header[0:4]
        print(f"First 4 bytes (should be 'RIFF'): {riff}")
        print(f"As hex: {riff.hex()}")
        
        if riff != b'RIFF':
            print("ERROR: File does not start with RIFF header")
            print(f"Expected: b'RIFF' (52494646 in hex)")
            print(f"Got: {riff} ({riff.hex()} in hex)")
            return False
            
        # Try to open with wave module
        try:
            with wave.open(file_path, 'rb') as wav:
                print(f"\nWAV file details:")
                print(f"  Channels: {wav.getnchannels()}")
                print(f"  Sample width: {wav.getsampwidth()} bytes")
                print(f"  Framerate: {wav.getframerate()} Hz")
                print(f"  Frames: {wav.getnframes()}")
                print(f"  Duration: {wav.getnframes() / wav.getframerate():.2f} seconds")
                print("\nFile appears to be a valid WAV file!")
                return True
        except Exception as e:
            print(f"\nERROR: wave module failed to read file: {e}")
            return False
            
    except Exception as e:
        print(f"ERROR reading file: {e}")
        return False

def main():
    # S3 URI from the logs
    s3_uri = "s3://percolate/default/uploads/anonymous/6caf5065-6851-c05b-8d8c-b870f5184c97/INST_020_20250618-151317.wav"
    
    print(f"Downloading file from: {s3_uri}")
    
    try:
        # Initialize S3 service
        s3_service = S3Service()
        
        # Download to a local file
        local_path = "/tmp/test_audio.wav"
        result = s3_service.download_file_from_uri(s3_uri, local_path=local_path)
        
        print(f"Downloaded to: {local_path}")
        print(f"File size: {result['size']} bytes")
        print(f"Content type: {result['content_type']}")
        
        # Check the WAV file
        is_valid = check_wav_header(local_path)
        
        if not is_valid:
            # Show first 100 bytes of the file for debugging
            print("\nFirst 100 bytes of the file:")
            with open(local_path, 'rb') as f:
                data = f.read(100)
                print(f"Raw bytes: {data[:50]}...")
                print(f"As hex: {data.hex()[:100]}...")
                
                # Check if it might be a chunk file
                if data.startswith(b'RIFF'):
                    print("\nFile starts with RIFF - should be valid WAV")
                elif all(b == 0 for b in data[:20]):
                    print("\nFile starts with null bytes - might be corrupted")
                else:
                    print("\nFile has unexpected format")
        
    except Exception as e:
        print(f"ERROR: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    main()