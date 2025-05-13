## Scheduled Tasks

This document describes the scheduled tasks feature in the Percolate API.

### Overview
- Uses the `apscheduler` library to run background jobs defined by cron-like schedules stored in PostgreSQL.
- Schedules are represented by the `Schedule` model and managed via admin API endpoints.

### Installation
1. The `apscheduler` dependency has been added to `pyproject.toml`:
   ```toml
   [tool.poetry.dependencies]
   apscheduler = "^3.10.1"
   ```

### Schedule Model
Located in `percolate.models.p8.types`:
```python
class Schedule(AbstractModel):
    id: UUID                  # Unique schedule id
    userid: UUID             # User id associated with schedule
    task: str                # Task to execute
    schedule: str            # Cron schedule string, e.g. "0 0 * * *"
    disabled_at: datetime    # Soft-delete timestamp (null = active)
```

### Admin API Endpoints
Under the `/admin` router:
- `POST   /admin/schedules` — Create a new schedule
- `GET    /admin/schedules` — List active schedules
- `DELETE /admin/schedules/{schedule_id}` — Disable (soft-delete) a schedule

### Scheduler Setup
The scheduler is managed via FastAPI's lifespan context. Define a lifespan function to start and stop the APScheduler:
```python
from fastapi import FastAPI
from contextlib import asynccontextmanager
from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.cron import CronTrigger
import percolate as p8
from percolate.models.p8.types import Schedule

def run_scheduled_job(schedule_record):
    """Placeholder job runner for scheduled tasks."""
    print(f"Running scheduled task {schedule_record.id}: {schedule_record.task}")

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Initialize scheduler
    scheduler = BackgroundScheduler()
    # Load and schedule active jobs
    repo = p8.repository(Schedule)
    table = Schedule.get_model_table_name()
    rows = repo.execute(f"SELECT * FROM {table} WHERE disabled_at IS NULL")
    for row in rows:
        rec = Schedule(**row)
        trigger = CronTrigger.from_crontab(rec.schedule)
        scheduler.add_job(run_scheduled_job, trigger, args=[rec], id=str(rec.id))
    scheduler.start()
    try:
        yield
    finally:
        scheduler.shutdown()

# Pass the lifespan to the FastAPI app
app = FastAPI(
    ...,  # other settings
    lifespan=lifespan,
)
```

Implement your task logic inside `run_scheduled_job`.
  
### Runtime Scheduling
When you create or update schedules at runtime via the Admin API, they are persisted to the database but not automatically added to the in-memory scheduler. To schedule a new task without restarting the service, follow these steps:

1. Export the scheduler and job runner from your main module (e.g., `percolate/api/main.py`):
   ```python
   # percolate/api/main.py
   from apscheduler.schedulers.background import BackgroundScheduler

   # Define once at module level
   scheduler = BackgroundScheduler()
   def run_scheduled_job(schedule_record):
       # your logic here
       ...
   ```

2. In your `POST /admin/schedules` handler, after saving the Schedule to the database, add it to the scheduler:
   ```python
   from percolate.api.main import scheduler, run_scheduled_job
   from apscheduler.triggers.cron import CronTrigger

   # Assume `new_schedule` is the Pydantic model you just saved
   trigger = CronTrigger.from_crontab(new_schedule.schedule)
   scheduler.add_job(
       run_scheduled_job,
       trigger,
       args=[new_schedule],
       id=str(new_schedule.id)
   )
   ```

3. To disable or delete a running job when a schedule is disabled:
   ```python
   # In your DELETE /admin/schedules/{id} handler
   scheduler.remove_job(job_id=str(schedule_id))
   ```


### For example create a schedule every minute
```python
import os
import requests

# Configuration
url = "http://localhost:5008/admin/schedules"
bearer_token = os.getenv("P8_TEST_BEARER_TOKEN")

if not bearer_token:
    raise EnvironmentError("Environment variable P8_TEST_BEARER_TOKEN not set.")

headers = {
    "Authorization": f"Bearer {bearer_token}",
    "Content-Type": "application/json"
}

payload = {
    "userid": "10e0a97d-a064-553a-9043-3c1f0a6e6725",
    "name": "test",
    "spec": {
        "system_prompt": "agent do something" 
    },
    "schedule": "* * * * *"  
}

# POST request
response = requests.post(url, json=payload, headers=headers)

# Output response
print("Status Code:", response.status_code)
print("Response:", response.json())
```
