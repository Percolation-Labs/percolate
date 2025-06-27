# Scheduler Task Lock Mechanism

## Overview

The Percolate API implements a per-task lock mechanism to ensure that scheduled tasks are executed exactly once across multiple pods. All pods run schedulers, but only one pod can execute a specific task at any given time.

## How It Works

### Architecture

1. **All Pods Run Schedulers**: Every pod loads and starts the scheduler with all scheduled tasks
2. **Per-Task Locking**: When a task is triggered, the pod tries to acquire a lock specific to that task
3. **Lock-Protected Execution**: Only the pod that successfully acquires the lock executes the task
4. **Automatic Lock Release**: Locks are released after task completion or timeout

### Task Execution Flow

```
1. Cron trigger fires on all pods simultaneously
2. Each pod attempts to acquire lock for task "daily-digest:abc-123"
3. First pod to acquire lock executes the task
4. Other pods skip execution (task already running)
5. Lock is released after task completes
```

### Lock Details

- **Lock Key Format**: `task_lock:{task_name}:{task_id}`
- **Lock Timeout**: 5 minutes (300 seconds) by default
- **Lock Storage**: `p8.Settings` table
- **Lock Content**:
  ```json
  {
    "process_id": "hostname-pid-uuid",
    "acquired_at": 1719509520.5,
    "expires_at": 1719509820.5
  }
  ```

## Benefits

1. **High Availability**: Any pod can execute tasks - no single point of failure
2. **Automatic Failover**: If a pod crashes, another pod executes the task on next trigger
3. **No Coordination Required**: Pods don't need to know about each other
4. **Simple Implementation**: Just acquire lock before executing task
5. **Prevents Duplicate Execution**: Guaranteed single execution across all pods

## Code Implementation

### Task Lock Functions

```python
def acquire_task_lock(process_id, task_name, timeout_seconds=300):
    """Try to acquire a lock for running a specific task."""
    # Check if lock exists and is valid
    # If expired or not exists, acquire new lock
    # Return True if acquired, False if already locked

def release_task_lock(process_id, task_name):
    """Release the lock for a task."""
    # Update lock with release information

def run_scheduled_job(schedule_record):
    """Run a scheduled job with lock protection."""
    process_id = f"{hostname}-{pid}-{uuid}"
    task_name = f"{schedule_record.name}:{schedule_record.id}"
    
    if not acquire_task_lock(process_id, task_name):
        # Task already running on another pod
        return
    
    try:
        # Execute task
    finally:
        release_task_lock(process_id, task_name)
```

## Database Schema

Uses the existing `p8.Settings` table:

```sql
-- Example task lock record
INSERT INTO p8."Settings" (id, key, value) VALUES (
    'generated-uuid',
    'task_lock:daily-digest:abc-123',
    '{"process_id": "pod1-12345-a1b2c3", "acquired_at": 1719509520.5, "expires_at": 1719509820.5}'
);
```

## Monitoring

### Check Active Task Locks

```sql
SELECT key, value 
FROM p8."Settings" 
WHERE key LIKE 'task_lock:%'
AND value::json->>'expires_at' > extract(epoch from now())::text;
```

### View Task Execution History

```sql
SELECT key, value 
FROM p8."Settings" 
WHERE key LIKE 'task_lock:%'
ORDER BY (value::json->>'acquired_at')::float DESC
LIMIT 20;
```

## Logging

The system provides clear logging for task execution:

```
INFO - Acquired lock for task: daily-digest:abc-123
INFO - Running scheduled task: daily-digest
INFO - Executing Daily Digest task for user: user@example.com
DEBUG - Released lock for task: daily-digest:abc-123
```

Or when skipping:

```
DEBUG - Skipping daily-digest:abc-123 - already running on another pod
```

## Testing

### Test Basic Lock Mechanism

```python
# Simulate multiple pods trying to run same task
process1 = "pod1-123-abc"
process2 = "pod2-456-def"
task = "test-task:123"

# First pod acquires lock
assert acquire_task_lock(process1, task) == True

# Second pod fails to acquire
assert acquire_task_lock(process2, task) == False

# Release and second pod can acquire
release_task_lock(process1, task)
assert acquire_task_lock(process2, task) == True
```

## Troubleshooting

### Issue: Task not executing

1. Check if task lock is stuck:
   ```sql
   SELECT * FROM p8."Settings" 
   WHERE key = 'task_lock:daily-digest:task-id';
   ```

2. If lock is expired but still present, it will be automatically overridden on next execution

### Issue: Tasks executing multiple times

- This should not happen with proper lock implementation
- Check that all pods are using the same database
- Verify lock acquisition is working correctly

### Manual Lock Cleanup

If needed, clear a stuck lock:

```sql
DELETE FROM p8."Settings" 
WHERE key = 'task_lock:daily-digest:task-id';
```

## Configuration

- **Lock Timeout**: Default 300 seconds (5 minutes)
- Can be adjusted in `acquire_task_lock()` function
- Should be longer than expected task execution time

## Best Practices

1. Keep task execution time under lock timeout
2. Always release locks in finally block
3. Use descriptive task names for easier monitoring
4. Monitor for stuck locks in production
5. Set appropriate lock timeouts based on task duration