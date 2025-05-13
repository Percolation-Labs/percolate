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
        
 
        
        if schedule.name == "Daily Digest" or schedule.name == "Weekly Digest":
            """
            TODO: This is a temporary hack to make sure the memories are ready - it should be a separate task
            """
            """returning some kind of graph diff would be very useful here"""
            data = Engram._add_memory_from_user_sessions(since_days_ago=1)
            
            users = p8.repository(User).execute(f""" SELECT * from p8."User" where email_subscription_active = True """)

            if not users:
                logger.warning("Did not find any users subscribed to email - is this expected?")
            for u in users:
                # #test mode
                if u['email'] != 'amartey@gmail.com':
                   continue
                   
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
                    """
                    content = DigestAgent.get_daily_digest(schedule.name, user_name= u['email'])
                    
                    if not content.get('recent_resources_upload') and not (content.get('session_count') or 0) > 0:
                        logger.warning(f"Because there are no changes to the resources or session entries we are skipping user {u['email']}")
                        continue
                    
                    content = p8.Agent(DigestAgent).run(f""" Format the daily digest for the user using the provided content ```{content}```""")
                    
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
                    """Send the digest email to the user - markdown is converted to HTML email"""     
                    _ = e.send_digest_email_from_markdown( subject=f"Your {schedule.name}", 
                                                          markdown_content=content, 
                                                          to_addrs=u['email'])
                    
                    a.audit(EmailService, AuditStatus.Success, status_payload)
                except:
                    logger.warning(f"Failing to send the digest email to user")
                    logger.warning(traceback.format_exc())
                    a.audit(EmailService, AuditStatus.Fail, status_payload, traceback.format_exc())
                
        
        
        