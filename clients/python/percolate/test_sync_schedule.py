#!/usr/bin/env python
"""
Test script for the sync schedule endpoint.
This creates a scheduled sync configuration that:
1. Syncs from a Google Drive folder
2. Creates a custom target table
3. Sets appropriate access levels
"""

import requests
import json
import os
from percolate.models.sync import SyncProvider
from percolate.models.p8.db_types import AccessLevel

# Configuration
API_KEY = os.getenv("PERCOLATE_API_KEY", "your-api-key-here")
BASE_URL = os.getenv("PERCOLATE_API_URL", "http://localhost:8000")
ADMIN_ENDPOINT = f"{BASE_URL}/admin/sync/schedule"

# Test data for creating a sync schedule
test_sync_config = {
    "provider": "google_drive",  # SyncProvider.GOOGLE_DRIVE
    "folder_id": "root",  # Sync from root folder (you can specify a specific folder ID)
    "target_namespace": "executive",  # Custom namespace
    "target_model_name": "SyncedDocs",  # Custom model name
    "access_level": "ADMIN",  # AccessLevel.ADMIN - restricted access
    "include_folders": ["Important", "Documents"],  # Only sync these folders
    "exclude_folders": ["Temp", "Archive"],  # Exclude these folders
    "include_file_types": ["pdf", "docx", "txt"],  # Only sync these file types
    "exclude_file_types": ["mp4", "exe"],  # Never sync these file types
    "sync_interval_hours": 24,  # Daily sync
    "enabled": True
}

def test_create_sync_schedule():
    """Test creating a new sync schedule."""
    headers = {
        "Authorization": f"Bearer {API_KEY}",
        "Content-Type": "application/json"
    }
    
    print("Creating sync schedule with configuration:")
    print(json.dumps(test_sync_config, indent=2))
    
    try:
        response = requests.post(
            ADMIN_ENDPOINT,
            headers=headers,
            json=test_sync_config
        )
        
        print(f"\nResponse Status: {response.status_code}")
        
        if response.status_code == 200:
            result = response.json()
            print("\nSync schedule created successfully!")
            print(json.dumps(result, indent=2))
            
            # The result should include:
            # - sync_config_id: ID of the sync configuration
            # - schedule_id: ID of the scheduled task
            # - provider: The sync provider used
            # - folder_id: The folder being synced
            # - target_model: The full model name (namespace.name)
            # - access_level: The access level set
            # - cron_schedule: The cron expression for scheduling
            
            return result
        else:
            print(f"\nError creating sync schedule: {response.status_code}")
            print(response.text)
            return None
            
    except Exception as e:
        print(f"\nError calling API: {str(e)}")
        return None

def test_list_schedules():
    """List all active schedules to verify our sync was created."""
    headers = {
        "Authorization": f"Bearer {API_KEY}",
        "Content-Type": "application/json"
    }
    
    try:
        response = requests.get(
            f"{BASE_URL}/admin/schedules",
            headers=headers
        )
        
        if response.status_code == 200:
            schedules = response.json()
            print("\n\nActive Schedules:")
            
            # Filter for file sync schedules
            sync_schedules = [
                s for s in schedules 
                if s.get("spec", {}).get("task_type") == "file_sync"
            ]
            
            if sync_schedules:
                print(f"\nFound {len(sync_schedules)} file sync schedule(s):")
                for schedule in sync_schedules:
                    print(f"\n- ID: {schedule['id']}")
                    print(f"  Name: {schedule['name']}")
                    print(f"  Schedule: {schedule['schedule']}")
                    print(f"  Target Model: {schedule['spec'].get('target_model')}")
                    print(f"  Provider: {schedule['spec'].get('provider')}")
            else:
                print("\nNo file sync schedules found.")
                
            return schedules
        else:
            print(f"\nError listing schedules: {response.status_code}")
            print(response.text)
            return None
            
    except Exception as e:
        print(f"\nError calling API: {str(e)}")
        return None

def test_check_model_created():
    """Check if the target model/table was created."""
    # This would require database access to verify
    # For now, we'll just note that the model should be created
    print("\n\nTo verify the model was created, check your database for:")
    print(f"- Schema: {test_sync_config['target_namespace']}")
    print(f"- Table: {test_sync_config['target_model_name']}")
    print(f"- Full name: {test_sync_config['target_namespace']}.{test_sync_config['target_model_name']}")
    print("\nThe table should inherit from p8.Resources with the specified access level.")

if __name__ == "__main__":
    print("=== Testing Sync Schedule Endpoint ===\n")
    
    # Create a sync schedule
    result = test_create_sync_schedule()
    
    if result:
        # List all schedules to verify
        test_list_schedules()
        
        # Note about model creation
        test_check_model_created()
        
        print("\n\n=== Test Complete ===")
        print("\nNext steps:")
        print("1. The initial sync should be running in the background")
        print("2. Check the logs for sync progress")
        print("3. Query the target table for synced content")
        print("4. The sync will run automatically based on the cron schedule")
        
        if result.get("schedule_id"):
            print(f"\nTo disable this sync, call DELETE /admin/schedules/{result['schedule_id']}")