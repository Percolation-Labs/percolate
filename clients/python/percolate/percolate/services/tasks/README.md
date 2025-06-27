# TaskManager Service

The TaskManager service is responsible for executing scheduled tasks in the Percolate system. It handles various types of scheduled operations including email digests, file synchronization, and other system tasks.

## Overview

The `TaskManager` class provides a central dispatch mechanism for scheduled tasks defined in the `Schedule` model. It processes tasks based on their specifications and handles different task types with appropriate services.

## Features

- **Daily/Weekly Digest Emails**: Automatically generates and sends digest emails to subscribed users
- **File Synchronization**: Handles periodic file sync tasks for users
- **Extensible Design**: Easy to add new task types through the dispatch mechanism

## Task Types

### 1. Email Digests (Daily/Weekly)
- Builds user memories from recent sessions
- Compiles recent resources and session activities
- **NEW: Includes comprehensive upload analytics from TUS upload view**
  - Total files uploaded in last 24 hours
  - Number of successful resource creations
  - Total data volume uploaded (human-readable format)
  - Lists specific files uploaded
  - Highlights failed uploads requiring attention
  - Groups uploads by resource categories
- Formats content using AI agents
- Sends formatted digests via email

### 2. File Sync Tasks
- Synchronizes user content from configured sources
- Tracks sync status and audits results
- Handles async operations within the task framework

## Usage

### Creating a Scheduled Task

To create a scheduled task in the database, you need to create a `Schedule` instance with the following fields:

```python
from percolate.models import Schedule
import uuid

# Example: Create a daily digest task
daily_digest = Schedule(
    id=str(uuid.uuid4()),
    userid="user-id-here",  # Optional: specific user or None for system tasks
    name="Daily Digest",
    spec={
        "task_type": "digest",
        "frequency": "daily"
    },
    schedule="0 9 * * *"  # Cron format: 9 AM daily
)

# Example: Create a file sync task
file_sync = Schedule(
    id=str(uuid.uuid4()),
    userid="user-id-here",
    name="File Sync",
    spec={
        "task_type": "file_sync",
        "sync_config_id": "config-id-here",
        "user_id": "user-id-here"
    },
    schedule="0 */6 * * *"  # Every 6 hours
)
```

### Schedule Model Fields

- `id`: Unique identifier for the schedule (UUID)
- `userid`: Associated user ID (optional for system-wide tasks)
- `name`: Task name (e.g., "Daily Digest", "Weekly Digest", "File Sync")
- `spec`: JSON object containing task-specific configuration
- `schedule`: Cron expression defining when the task runs
- `disabled_at`: Timestamp when the schedule was disabled (None if active)

### Dispatching Tasks

The TaskManager is typically invoked by a scheduler service:

```python
from percolate.services.tasks import TaskManager
from percolate.models import Schedule

# Initialize the task manager
task_manager = TaskManager()

# Fetch and dispatch a schedule
schedule = # ... fetch from database
task_manager.dispatch_task(schedule)
```

## Dependencies

- `EmailService`: For sending digest emails
- `AuditService`: For tracking task execution status
- `FileSync`: For file synchronization tasks
- `DigestAgent`: AI agent for formatting digest content
- `tus_upload_analytics`: SQL view providing upload and resource creation metrics

## Audit Trail

All task executions are audited with:
- Success/failure status
- Relevant metadata (user_id, files synced, errors)
- Stack traces for debugging failures

## Configuration

Email subscriptions are controlled by the `email_subscription_active` field in the User model. Only users with this flag set to `True` will receive digest emails.

## Multi-Pod Deployment

In multi-pod deployments, all pods run schedulers but use per-task locking to ensure each task executes exactly once:

1. **All Pods Run Schedulers**: Every pod loads and starts the scheduler with all tasks
2. **Per-Task Locking**: When a cron trigger fires, all pods attempt to acquire a task-specific lock
3. **Single Execution**: Only the pod that acquires the lock executes the task
4. **Automatic Failover**: If a pod crashes, another pod will execute on the next trigger

Benefits:
- No single point of failure
- Automatic failover without coordination
- Simple implementation
- Prevents duplicate execution

See `/percolate/api/docs/scheduler_lock.md` for implementation details.

## Future Enhancements

- Separate task for memory preparation (currently bundled with digest)
- More sophisticated scheduling for cost optimization
- Support for custom user-defined tasks
- Graph visualization embeddings in digest emails