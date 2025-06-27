"""
Sample script for creating scheduled tasks in the database
"""

import percolate as p8
from percolate.models import Schedule, User
import uuid
from datetime import datetime

def create_daily_digest_for_user(user_email: str):
    """
    Create a daily digest schedule for a specific user
    """
    # First, check if the user exists
    users = p8.repository(User).execute(
        f""" SELECT * from p8."User" where email = '{user_email}' """
    )
    
    if not users:
        print(f"User {user_email} not found. Creating user...")
        # In a real scenario, you'd create the user properly
        # For this example, we'll just show the structure
        user_id = str(uuid.uuid4())
        print(f"Would create user with ID: {user_id}")
    else:
        user_id = users[0]['id']
        print(f"Found user {user_email} with ID: {user_id}")
    
    # Create the daily digest schedule
    daily_digest = Schedule(
        id=str(uuid.uuid4()),
        userid=user_id,
        name="Daily Digest",
        spec={
            "task_type": "digest",
            "frequency": "daily",
            "user_email": user_email,
            "include_sessions": True,
            "include_resources": True,
            "include_graph": True
        },
        schedule="0 9 * * *"  # 9 AM daily
    )
    
    # Save to database
    saved_schedule = p8.repository(Schedule).add(daily_digest)
    print(f"Created daily digest schedule: {saved_schedule}")
    
    return saved_schedule


def create_weekly_digest_for_user(user_email: str):
    """
    Create a weekly digest schedule for a specific user
    """
    # First, check if the user exists
    users = p8.repository(User).execute(
        f""" SELECT * from p8."User" where email = '{user_email}' """
    )
    
    if not users:
        print(f"User {user_email} not found")
        return None
        
    user_id = users[0]['id']
    
    # Create the weekly digest schedule
    weekly_digest = Schedule(
        id=str(uuid.uuid4()),
        userid=user_id,
        name="Weekly Digest",
        spec={
            "task_type": "digest",
            "frequency": "weekly",
            "user_email": user_email,
            "include_sessions": True,
            "include_resources": True,
            "include_graph": True,
            "summary_depth": "detailed"
        },
        schedule="0 9 * * 1"  # 9 AM every Monday
    )
    
    # Save to database
    saved_schedule = p8.repository(Schedule).add(weekly_digest)
    print(f"Created weekly digest schedule: {saved_schedule}")
    
    return saved_schedule


def create_file_sync_schedule(user_id: str, sync_config_id: str):
    """
    Create a file sync schedule for a user
    """
    # Create the file sync schedule
    file_sync = Schedule(
        id=str(uuid.uuid4()),
        userid=user_id,
        name="File Sync",
        spec={
            "task_type": "file_sync",
            "sync_config_id": sync_config_id,
            "user_id": user_id,
            "retry_on_failure": True,
            "max_retries": 3
        },
        schedule="0 */6 * * *"  # Every 6 hours
    )
    
    # Save to database
    saved_schedule = p8.repository(Schedule).add(file_sync)
    print(f"Created file sync schedule: {saved_schedule}")
    
    return saved_schedule


def list_user_schedules(user_email: str):
    """
    List all schedules for a specific user
    """
    # Get user
    users = p8.repository(User).execute(
        f""" SELECT * from p8."User" where email = '{user_email}' """
    )
    
    if not users:
        print(f"User {user_email} not found")
        return []
        
    user_id = users[0]['id']
    
    # Get all schedules for the user
    schedules = p8.repository(Schedule).execute(
        f""" SELECT * from p8."Schedule" where userid = '{user_id}' """
    )
    
    print(f"\nSchedules for {user_email}:")
    for schedule in schedules:
        print(f"- {schedule['name']} ({schedule['id']})")
        print(f"  Schedule: {schedule['schedule']}")
        print(f"  Spec: {schedule['spec']}")
        print(f"  Active: {schedule.get('disabled_at') is None}")
        print()
    
    return schedules


def disable_schedule(schedule_id: str):
    """
    Disable a schedule by setting disabled_at timestamp
    """
    # In a real implementation, you'd update the schedule
    # This is a conceptual example
    update_data = {
        "disabled_at": datetime.utcnow()
    }
    
    # Update in database
    # p8.repository(Schedule).update(schedule_id, update_data)
    print(f"Schedule {schedule_id} would be disabled")


# Example usage for amartey@gmail.com
if __name__ == "__main__":
    # Create sample user email
    sample_user_email = "amartey@gmail.com"
    
    print("Creating scheduled tasks for amartey@gmail.com...")
    
    # Create daily digest
    daily_schedule = create_daily_digest_for_user(sample_user_email)
    
    # Create weekly digest
    weekly_schedule = create_weekly_digest_for_user(sample_user_email)
    
    # List all schedules for the user
    list_user_schedules(sample_user_email)
    
    # Example of creating a system-wide daily digest (no specific user)
    system_daily_digest = Schedule(
        id=str(uuid.uuid4()),
        userid=None,  # System task, not user-specific
        name="Daily Digest",
        spec={
            "task_type": "digest",
            "frequency": "daily",
            "scope": "all_subscribed_users"
        },
        schedule="0 9 * * *"  # 9 AM daily
    )
    
    print("\nSystem-wide daily digest schedule created (example)")
    print(f"Schedule ID: {system_daily_digest.id}")
    print(f"Schedule: {system_daily_digest.schedule}")