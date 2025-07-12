from percolate.utils import logger
from apscheduler.schedulers.blocking import BlockingScheduler
import os
import socket
from percolate.models import Schedule
import percolate as p8
from apscheduler.triggers.cron import CronTrigger
from apscheduler.triggers.interval import IntervalTrigger
import threading
from datetime import datetime
import uuid


class SchedulerSingleton:
    """Singleton scheduler that manages all scheduled jobs"""
    _instance = None
    _lock = threading.Lock()
    
    def __new__(cls):
        if cls._instance is None:
            with cls._lock:
                if cls._instance is None:
                    cls._instance = super(SchedulerSingleton, cls).__new__(cls)
                    cls._instance._initialized = False
        return cls._instance
    
    def __init__(self):
        if self._initialized:
            return
            
        self.scheduler = BlockingScheduler({"apscheduler.timezone": "UTC"})
        self.pod_id = f"{socket.gethostname()}-{os.getpid()}"
        self.loaded_schedules = set()  # Track loaded schedule IDs
        self._initialized = True
        
        # Add heartbeat job that runs every minute
        self.scheduler.add_job(
            self._heartbeat_and_reload,
            IntervalTrigger(seconds=60),
            id="scheduler-heartbeat",
            name="Scheduler Heartbeat and Reload"
        )
        logger.info(f"Scheduler singleton initialized on pod {self.pod_id}")
    
    def _heartbeat_and_reload(self):
        """Heartbeat function that logs status and reloads schedules from database"""
        logger.info(f"♥ Scheduler heartbeat on pod {self.pod_id} - Active jobs: {len(self.scheduler.get_jobs())}")
        
        try:
            # Reload schedules from database
            repo = p8.repository(Schedule)
            table = Schedule.get_model_table_name()
            
            # Get all active schedules from database
            data = repo.execute(f"SELECT * FROM {table} WHERE disabled_at IS NULL ")
            db_schedule_ids = set()
            
            for d in data:
                try:
                    record = Schedule(**d)
                    schedule_id = str(record.id)
                    db_schedule_ids.add(schedule_id)
                    
                    # Skip if already loaded (unless it's the heartbeat itself)
                    if schedule_id in self.loaded_schedules and schedule_id != "scheduler-heartbeat":
                        continue
                    
                    # Add new schedule
                    trigger = CronTrigger.from_crontab(record.schedule)
                    self.scheduler.add_job(
                        run_scheduled_job, 
                        trigger, 
                        args=[record], 
                        id=schedule_id,
                        replace_existing=True,
                        name=record.name
                    )
                    
                    # if schedule_id not in self.loaded_schedules:
                    #     logger.info(f"➕ Added new schedule: {record.name} (ID: {schedule_id})")
                    #     self.loaded_schedules.add(schedule_id)
                        
                except Exception as e:
                    logger.warning(f"Failed to add/update schedule {d.get('id')}: {e}")
            
            # Remove schedules that are no longer in database
            removed_schedules = self.loaded_schedules - db_schedule_ids - {"scheduler-heartbeat"}
            for schedule_id in removed_schedules:
                try:
                    self.scheduler.remove_job(schedule_id)
                    self.loaded_schedules.remove(schedule_id)
                    logger.info(f"➖ Removed schedule: {schedule_id}")
                except Exception as e:
                    logger.warning(f"Failed to remove schedule {schedule_id}: {e}")
                    
        except Exception as ex:
            logger.error(f"Error during heartbeat reload: {ex}")
    
    def load_initial_schedules(self):
        """Load schedules from database on startup"""
        try:
            repo = p8.repository(Schedule)
            table = Schedule.get_model_table_name()
            
            data = repo.execute(f"SELECT * FROM {table} WHERE disabled_at IS NULL")
            for d in data:
                try:
                    record = Schedule(**d)
                    schedule_id = str(record.id)
                    trigger = CronTrigger.from_crontab(record.schedule)
                    self.scheduler.add_job(
                        run_scheduled_job, 
                        trigger, 
                        args=[record], 
                        id=schedule_id,
                        name=record.name
                    )
                    self.loaded_schedules.add(schedule_id)
                except Exception as e:
                    logger.warning(f"Failed to schedule job for record {d.get('id')}: {e}")
                    
            logger.info(f"✓ Loaded {len(self.loaded_schedules)} schedules from database")
            
        except Exception as ex:
            logger.warning(f"Failed to load scheduler data: {ex}")
    
    def start(self):
        """Start the scheduler"""
        logger.info(f"✓ Scheduler started on pod {self.pod_id} with jobs: {[j.id for j in self.scheduler.get_jobs()]}")
        
        # Send startup notification email
        self._send_startup_email()
        
        try:
            self.scheduler.start()
        except KeyboardInterrupt:
            logger.info(f"Scheduler interrupted on pod {self.pod_id}")
        finally:
            # Shutdown scheduler
            self.scheduler.shutdown()
            logger.info(f"Scheduler shutdown complete on pod {self.pod_id}")
    
    def _send_startup_email(self):
        """Send startup notification email"""
        try:
            from percolate.services.EmailService import EmailService
            email_service = EmailService()
            
            job_count = len(self.scheduler.get_jobs())
            job_ids = [j.id for j in self.scheduler.get_jobs()]
            
            html_content = f"""
            <html>
            <body>
                <h2>Percolate Scheduler Started</h2>
                <p>The Percolate scheduler has successfully started on pod <strong>{self.pod_id}</strong></p>
                <p>Number of scheduled jobs loaded: <strong>{job_count}</strong></p>
                {f'<p>Job IDs: {", ".join(job_ids)}</p>' if job_ids else '<p>No jobs currently scheduled.</p>'}
                <p style="margin-top: 20px;"><strong>Note:</strong> The scheduler will check for new schedules every minute via heartbeat.</p>
                <hr>
                <p style="color: gray; font-size: 12px;">This is an automated notification from the Percolate system.</p>
            </body>
            </html>
            """
            
            text_content = f"Percolate Scheduler Started\n\nThe scheduler has started on pod {self.pod_id}\nNumber of jobs: {job_count}\nJob IDs: {', '.join(job_ids) if job_ids else 'No jobs scheduled'}\n\nNote: The scheduler will check for new schedules every minute via heartbeat."
            
            email_service.send_email(
                subject="Percolate Status Email",
                html_content=html_content,
                to_addrs="amartey@gmail.com",
                text_content=text_content
            )
            logger.info("✓ Startup notification email sent to amartey@gmail.com")
        except Exception as e:
            logger.error(f"Failed to send startup notification email: {str(e)}")


def run_scheduled_job(schedule_record):
    """Run a scheduled job based on its specification."""
    import uuid, socket
    
    # Generate unique process ID for this execution
    process_id = f"{socket.gethostname()}-{os.getpid()}-{uuid.uuid4().hex[:8]}"
    task_name = f"{schedule_record.name}:{schedule_record.id}"
    
    try:
        logger.info(f"🏃 Running scheduled task: {schedule_record.name} (ID: {schedule_record.id})")
        
        # Handle different task types
        if schedule_record.name and schedule_record.name.lower() == "daily-digest":
            logger.info(f"Executing Daily Digest task for user: {schedule_record.userid}")
            from percolate.services.tasks.TaskManager import TaskManager
            task_manager = TaskManager()
            task_manager.dispatch_task(schedule_record)
        elif schedule_record.spec and "task_type" in schedule_record.spec:
            task_type = schedule_record.spec["task_type"]
            logger.info(f"Executing task type: {task_type}")
            
            if task_type == "digest":
                # Handle digest tasks
                from percolate.services.tasks.TaskManager import TaskManager
                task_manager = TaskManager()
                task_manager.dispatch_task(schedule_record)
            elif task_type == "file_sync":
                # Handle file sync tasks
                logger.info(f"Running file sync task: {schedule_record.spec}")
                # File sync logic would go here
            elif task_type == "heartbeat":
                # Log heartbeat
                logger.info(f"♥ Heartbeat task executed: {schedule_record.spec}")
            else:
                logger.warning(f"Unknown task type: {task_type}")
        elif schedule_record.spec and "task" in schedule_record.spec:
            task_name = schedule_record.spec["task"]
            logger.info(f"Executing task: {task_name}")
        else:
            logger.warning(f"No task specified in schedule record: {schedule_record.id}")
            
    except Exception as e:
        logger.error(f"Error running scheduled task {schedule_record.id}: {str(e)}")
    finally:
        pass


def start_scheduler():
    """Start the singleton scheduler"""
    scheduler = SchedulerSingleton()
    scheduler.load_initial_schedules()
    scheduler.start()