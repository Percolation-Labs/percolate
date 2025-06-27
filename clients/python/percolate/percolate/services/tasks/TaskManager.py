"""
The Task Manager will manage system tasks like sending digests or user custom models
"""

from percolate.models import Schedule, User, Audit, AuditStatus, DigestAgent, Engram
import percolate as p8
from percolate.services import EmailService
from percolate.utils import logger
import traceback
from enum import Enum
from percolate.services import AuditService

class TaskManager:
    """the task manager will evolve to handle system tasks and reminders"""
    def __init__(self):
        """"""
        pass
    
    def _get_user_upload_analytics(self, user_id: str):
        """
        Get upload analytics for a user from the TUS analytics view
        Returns summary of uploads and resource creation in the last 24 hours
        """
        from percolate.utils import get_days_ago_iso_timestamp
        
        # Query the analytics view for user's recent uploads
        query = """
        SELECT 
            COUNT(DISTINCT upload_id) as total_uploads_24h,
            COUNT(DISTINCT upload_id) FILTER (WHERE upload_status = 'completed') as completed_uploads_24h,
            COUNT(DISTINCT upload_id) FILTER (WHERE upload_status = 'failed') as failed_uploads_24h,
            COUNT(DISTINCT upload_id) FILTER (WHERE resource_status = 'resources_created') as uploads_with_resources_24h,
            SUM(resource_chunk_count) as total_resources_created_24h,
            COUNT(DISTINCT upload_id) FILTER (WHERE resource_count > 0) as successful_resource_creations_24h,
            ARRAY_AGG(DISTINCT filename ORDER BY filename) FILTER (WHERE filename IS NOT NULL) as uploaded_files_24h,
            ARRAY_AGG(DISTINCT resource_categories) FILTER (WHERE resource_categories IS NOT NULL) as resource_categories_24h,
            SUM(total_size)::bigint as total_bytes_uploaded_24h,
            AVG(upload_progress_pct)::numeric(5,2) as avg_upload_progress_24h
        FROM p8.tus_upload_analytics
        WHERE userid = %s 
        AND upload_created_at >= %s
        """
        
        analytics = p8.repository(User).execute(query, data=(user_id, get_days_ago_iso_timestamp(n=1)))
        
        if analytics and len(analytics) > 0:
            result = analytics[0]
            
            # Convert bytes to human-readable format
            total_bytes = result.get('total_bytes_uploaded_24h', 0) or 0
            result['total_size_human_readable'] = self._format_bytes(total_bytes)
            
            # Get details of recent uploads with resource creation status
            details_query = """
            SELECT 
                filename,
                upload_status,
                resource_status,
                resource_count,
                resource_chunk_count,
                upload_created_at,
                upload_updated_at,
                upload_progress_pct,
                total_size,
                resource_categories as categories,
                upload_duration_seconds,
                CASE 
                    WHEN upload_status = 'completed' AND resource_count > 0 THEN 'Successfully processed'
                    WHEN upload_status = 'completed' AND resource_count = 0 THEN 'Uploaded (no resources created)'
                    WHEN upload_status = 'failed' THEN 'Upload failed'
                    ELSE 'In progress'
                END as status_summary
            FROM p8.tus_upload_analytics
            WHERE userid = %s 
            AND upload_created_at >= %s
            ORDER BY upload_created_at DESC
            LIMIT 10
            """
            
            recent_uploads = p8.repository(User).execute(details_query, data=(user_id, get_days_ago_iso_timestamp(n=1)))
            result['recent_upload_details'] = recent_uploads
            
            return result
        
        return {
            'total_uploads_24h': 0,
            'completed_uploads_24h': 0,
            'failed_uploads_24h': 0,
            'uploads_with_resources_24h': 0,
            'total_resources_created_24h': 0,
            'successful_resource_creations_24h': 0,
            'uploaded_files_24h': [],
            'resource_categories_24h': [],
            'total_bytes_uploaded_24h': 0,
            'total_size_human_readable': '0 B',
            'avg_upload_progress_24h': 0,
            'recent_upload_details': []
        }
    
    def _format_bytes(self, bytes_value):
        """Convert bytes to human-readable format"""
        if bytes_value == 0:
            return '0 B'
        
        units = ['B', 'KB', 'MB', 'GB', 'TB']
        unit_index = 0
        size = float(bytes_value)
        
        while size >= 1024 and unit_index < len(units) - 1:
            size /= 1024
            unit_index += 1
        
        return f"{size:.2f} {units[unit_index]}"
    
    def dispatch_task(self, schedule: Schedule, **kwargs):
        """
        dispatch a task by name - still want to determine how this works in general
        this test model is building and sending for small number of users
        but in reality we will probably schedule generating agentic outputs and then sending them as emails in a short time window when prepared
        This allows for better control of scheduling times and also costs
        However to test the concept of digests for ~10 users, this complexity is unwarranted
        """
        
        logger.debug(f"Dispatching {schedule}")
        e = EmailService()
        a = AuditService()
        
        # Check if this is a file sync task
        if schedule.spec and schedule.spec.get("task_type") == "file_sync":
            """Handle file sync task"""
            try:
                sync_config_id = schedule.spec.get("sync_config_id")
                user_id = schedule.spec.get("user_id")
                
                if not sync_config_id or not user_id:
                    logger.error(f"Missing sync_config_id or user_id in schedule spec: {schedule.spec}")
                    return
                
                # Import async sync service
                from percolate.services.sync.file_sync import FileSync
                import asyncio
                
                # Create sync service
                sync_service = FileSync()
                
                # Run the sync in an event loop
                loop = asyncio.new_event_loop()
                asyncio.set_event_loop(loop)
                
                try:
                    result = loop.run_until_complete(
                        sync_service.sync_user_content(user_id=user_id, force=False)
                    )
                    logger.info(f"File sync completed for user {user_id}: {result}")
                    
                    # Audit the sync
                    status_payload = {
                        'user_id': user_id,
                        'sync_config_id': sync_config_id,
                        'files_synced': result.files_synced,
                        'files_failed': result.files_failed,
                        'success': result.success
                    }
                    a.audit(FileSync, AuditStatus.Success if result.success else AuditStatus.Fail, status_payload)
                    
                except Exception as e:
                    logger.error(f"File sync failed for user {user_id}: {str(e)}")
                    logger.error(traceback.format_exc())
                    status_payload = {
                        'user_id': user_id,
                        'sync_config_id': sync_config_id,
                        'error': str(e)
                    }
                    a.audit(FileSync, AuditStatus.Fail, status_payload, traceback.format_exc())
                finally:
                    loop.close()
                    
            except Exception as e:
                logger.error(f"Error in file sync task: {str(e)}")
                logger.error(traceback.format_exc())
            return
        
        if schedule.name in ["Daily Digest", "Weekly Digest", "daily-digest", "weekly-digest"]:
            """
            TODO: This is a temporary hack to make sure the memories are ready - it should be a separate task
            """
            users = p8.repository(User).execute(f""" SELECT * from p8."User" where email_subscription_active = True """)

            if not users:
                logger.warning("Did not find any users subscribed to email - is this expected?")
            for u in users:
                # Generate memories for this specific user
                """returning some kind of graph diff would be very useful here"""
                data = Engram._add_memory_from_user_sessions(since_days_ago=1, user_email=u['email'])
                   
                status_payload = {
                    'user_id': u['id'],
                    'event': f'building digest {schedule.name}'
                }
                try:
                    """this pattern needs to reliably compile all content and format it - in the first version of testing we will 
                    do a deterministic fetch of the data and then just format it but in future this can be purely agentic
                    The daily digest should
                    - read recent sessions
                    - read the user model and their graph expansion (a tool could be used to save the networkx graph plot and embed it in the email as base64 image)
                    - read recent documents uploaded
                    - include analytics about file uploads and resource creation
                    """
                    # Pass the user engram data generated above
                    content = DigestAgent.get_daily_digest(schedule.name, user_name=u['email'], user_engram=data)
                    
                    # Add upload analytics from the TUS analytics view
                    upload_analytics = self._get_user_upload_analytics(u['id'])
                    content['upload_analytics'] = upload_analytics
                    
                    # Check if there's any meaningful content to include in the digest
                    # Check for resources using the new summary format
                    resource_summary = content.get('recent_resources_summary', {})
                    has_resources = resource_summary.get('total_resources', 0) > 0
                    has_sessions = (content.get('session_count') or 0) > 0
                    has_uploads = upload_analytics.get('total_uploads_24h', 0) > 0
                    
                    if not has_resources and not has_sessions and not has_uploads:
                        logger.warning(f"No activity (resources, sessions, or uploads) found for user {u['email']} - skipping digest")
                        continue
                    
                    # Use the new HTML formatting method
                    formatted_html = DigestAgent.format_daily_digest_html(content, upload_analytics)
                    
                    """LOG te daily digest to s3 for our records"""
                    
                    a.audit(DigestAgent, AuditStatus.Success, status_payload)
                except:
                    logger.warning(f"Failing to run the digest agent after retries")
                    logger.warning(traceback.format_exc())
                    a.audit(DigestAgent, AuditStatus.Fail, status_payload, traceback.format_exc())
                    continue
                
                status_payload = {
                    'user_id': u['id'],
                    'event': f'sending digest {schedule.name}'
                }
                try:           
                    """Send the digest email to the user - HTML email directly"""     
                    _ = e.send_email(subject=f"Your {schedule.name}", 
                                    html_content=formatted_html, 
                                    to_addrs=u['email'])
                    
                    a.audit(EmailService, AuditStatus.Success, status_payload)
                except:
                    logger.warning(f"Failing to send the digest email to user")
                    logger.warning(traceback.format_exc())
                    a.audit(EmailService, AuditStatus.Fail, status_payload, traceback.format_exc())
                
        
        
        