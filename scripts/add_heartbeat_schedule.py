#!/usr/bin/env python3
"""
Script to add a heartbeat schedule to the database for testing scheduler reload functionality
"""
import percolate as p8
from percolate.models import Schedule
import uuid

# Create a heartbeat schedule
heartbeat_schedule = Schedule(
    id=str(uuid.uuid4()),
    name="Scheduler Heartbeat Test",
    spec={
        "task_type": "heartbeat",
        "message": "Testing heartbeat functionality",
        "pod_info": "Will be updated by scheduler"
    },
    schedule="*/5 * * * *"  # Run every 5 minutes
)

# Add to database
repo = p8.repository(Schedule)
repo.update_records([heartbeat_schedule])

print(f"✓ Added heartbeat schedule with ID: {heartbeat_schedule.id}")
print(f"  Name: {heartbeat_schedule.name}")
print(f"  Schedule: {heartbeat_schedule.schedule} (every 5 minutes)")
print("\nThe scheduler should pick this up within 60 seconds via its reload mechanism.")