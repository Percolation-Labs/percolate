"""
Tests for the TaskManager service, specifically Daily Digest functionality
"""

import pytest
import uuid
from unittest.mock import Mock, patch, MagicMock
from datetime import datetime
import percolate as p8
from percolate.services.tasks.TaskManager import TaskManager
from percolate.models import Schedule, User, AuditStatus
from percolate.models.p8.types import DigestAgent


class TestTaskManager:
    """Test suite for TaskManager focusing on Daily Digest functionality"""
    
    @pytest.fixture
    def task_manager(self):
        """Create a TaskManager instance for testing"""
        return TaskManager()
    
    @pytest.fixture
    def sample_user(self):
        """Create a sample user for testing"""
        return {
            'id': str(uuid.uuid4()),
            'email': 'amartey@gmail.com',
            'email_subscription_active': True
        }
    
    @pytest.fixture
    def daily_digest_schedule(self, sample_user):
        """Create a daily digest schedule for testing"""
        return Schedule(
            id=str(uuid.uuid4()),
            userid=sample_user['id'],
            name="Daily Digest",
            spec={
                "task_type": "digest",
                "frequency": "daily"
            },
            schedule="0 9 * * *"
        )
    
    @patch('percolate.services.tasks.TaskManager.EmailService')
    @patch('percolate.services.tasks.TaskManager.AuditService')
    @patch('percolate.services.tasks.TaskManager.Engram')
    @patch('percolate.services.tasks.TaskManager.DigestAgent')
    @patch('percolate.repository')
    def test_daily_digest_sends_email_to_user(self, mock_repository, mock_digest_agent, 
                                              mock_engram, mock_audit_service, mock_email_service,
                                              task_manager, daily_digest_schedule, sample_user):
        """
        Test that the Daily Digest task successfully sends an email to amartey@gmail.com
        with upload analytics from the TUS analytics view
        """
        # Mock the repository to return our sample user
        mock_user_repo = Mock()
        mock_user_repo.execute.return_value = [sample_user]
        
        # Create a second mock for the analytics query
        def mock_execute(query, data=None):
            if 'email_subscription_active' in query:
                return [sample_user]
            elif 'tus_upload_analytics' in query and 'COUNT(DISTINCT upload_id)' in query:
                # Return upload analytics summary
                return [{
                    'total_uploads_24h': 5,
                    'completed_uploads_24h': 4,
                    'failed_uploads_24h': 1,
                    'uploads_with_resources_24h': 4,
                    'total_resources_created_24h': 12,
                    'successful_resource_creations_24h': 4,
                    'uploaded_files_24h': ['report.pdf', 'data.csv', 'image.png', 'notes.txt'],
                    'resource_categories_24h': ['document', 'data', 'image'],
                    'total_bytes_uploaded_24h': 52428800,  # 50 MB
                    'avg_upload_progress_24h': 95.5
                }]
            elif 'tus_upload_analytics' in query and 'filename' in query:
                # Return recent upload details
                return [
                    {
                        'filename': 'report.pdf',
                        'upload_status': 'completed',
                        'resource_status': 'resources_created',
                        'resource_count': 3,
                        'upload_created_at': '2024-01-15T10:30:00Z',
                        'upload_progress_pct': 100.0,
                        'total_size': 10485760,
                        'categories': ['document']
                    },
                    {
                        'filename': 'data.csv',
                        'upload_status': 'completed',
                        'resource_status': 'resources_created',
                        'resource_count': 1,
                        'upload_created_at': '2024-01-15T11:00:00Z',
                        'upload_progress_pct': 100.0,
                        'total_size': 1048576,
                        'categories': ['data']
                    }
                ]
            return []
        
        mock_user_repo.execute = mock_execute
        mock_repository.return_value = mock_user_repo
        
        # Mock Engram memory addition
        mock_engram._add_memory_from_user_sessions.return_value = {'memories_added': 5}
        
        # Mock DigestAgent to return sample content
        sample_digest_content = {
            'recent_resources_upload': ['document1.pdf', 'notes.txt'],
            'session_count': 3,
            'recent_sessions': [
                {'session_id': '123', 'summary': 'Discussed project planning'},
                {'session_id': '456', 'summary': 'Reviewed technical documentation'}
            ],
            'graph_expansion': {'nodes': 15, 'edges': 23}
        }
        mock_digest_agent.get_daily_digest.return_value = sample_digest_content
        
        # Mock the agent formatting with upload analytics
        formatted_content = """
# Your Daily Digest

## Upload Activity Summary
- **Files Uploaded**: 5 files in the last 24 hours
- **Successful Resources Created**: 4 uploads created 12 resources
- **Total Data Volume**: 50.00 MB uploaded
- **Files**: report.pdf, data.csv, image.png, notes.txt
- **Failed Uploads**: 1 upload failed and needs attention

## Recent Activity
- You had 3 sessions today
- Uploaded 2 new resources: document1.pdf, notes.txt

## Session Highlights
1. Discussed project planning
2. Reviewed technical documentation

## Knowledge Graph Update
Your knowledge graph has expanded to 15 nodes and 23 connections.
"""
        mock_agent_instance = Mock()
        mock_agent_instance.run.return_value = formatted_content
        mock_agent = Mock(return_value=mock_agent_instance)
        
        with patch('percolate.Agent', mock_agent):
            # Mock email and audit service instances
            mock_email_instance = Mock()
            mock_email_service.return_value = mock_email_instance
            
            mock_audit_instance = Mock()
            mock_audit_service.return_value = mock_audit_instance
            
            # Execute the task
            task_manager.dispatch_task(daily_digest_schedule)
            
            # Verify that the user was fetched
            mock_user_repo.execute.assert_called_once()
            assert 'email_subscription_active = True' in mock_user_repo.execute.call_args[0][0]
            
            # Verify that digest content was generated
            mock_digest_agent.get_daily_digest.assert_called_once_with(
                "Daily Digest", 
                user_name='amartey@gmail.com'
            )
            
            # Verify that the agent formatted the content
            mock_agent.assert_called_once_with(DigestAgent)
            mock_agent_instance.run.assert_called_once()
            
            # Verify that the email was sent
            mock_email_instance.send_digest_email_from_markdown.assert_called_once_with(
                subject="Your Daily Digest",
                markdown_content=formatted_content,
                to_addrs='amartey@gmail.com'
            )
            
            # Verify that successful audits were recorded
            assert mock_audit_instance.audit.call_count >= 2
            
            # Check that at least one successful email audit was recorded
            email_audit_calls = [
                call for call in mock_audit_instance.audit.call_args_list
                if call[0][0] == mock_email_service and call[0][1] == AuditStatus.Success
            ]
            assert len(email_audit_calls) == 1
    
    @patch('percolate.services.tasks.TaskManager.EmailService')
    @patch('percolate.services.tasks.TaskManager.AuditService')
    @patch('percolate.services.tasks.TaskManager.Engram')
    @patch('percolate.services.tasks.TaskManager.DigestAgent')
    @patch('percolate.repository')
    def test_daily_digest_skips_inactive_users(self, mock_repository, mock_digest_agent,
                                               mock_engram, mock_audit_service, mock_email_service,
                                               task_manager, daily_digest_schedule, sample_user):
        """
        Test that the Daily Digest task skips users without email_subscription_active
        """
        # Create an inactive user
        inactive_user = sample_user.copy()
        inactive_user['email_subscription_active'] = False
        
        # Mock the repository to return only inactive users
        mock_user_repo = Mock()
        mock_user_repo.execute.return_value = [inactive_user]
        mock_repository.return_value = mock_user_repo
        
        # Mock other services
        mock_engram._add_memory_from_user_sessions.return_value = {}
        mock_email_instance = Mock()
        mock_email_service.return_value = mock_email_instance
        
        # Execute the task
        task_manager.dispatch_task(daily_digest_schedule)
        
        # Verify that no email was sent
        mock_email_instance.send_digest_email_from_markdown.assert_not_called()
    
    @patch('percolate.services.tasks.TaskManager.EmailService')
    @patch('percolate.services.tasks.TaskManager.AuditService')
    @patch('percolate.services.tasks.TaskManager.Engram')
    @patch('percolate.services.tasks.TaskManager.DigestAgent')
    @patch('percolate.repository')
    def test_daily_digest_handles_email_failure(self, mock_repository, mock_digest_agent,
                                                mock_engram, mock_audit_service, mock_email_service,
                                                task_manager, daily_digest_schedule, sample_user):
        """
        Test that the Daily Digest task properly handles and audits email sending failures
        """
        # Mock the repository to return our sample user
        mock_user_repo = Mock()
        mock_user_repo.execute.return_value = [sample_user]
        mock_repository.return_value = mock_user_repo
        
        # Mock successful content generation
        mock_engram._add_memory_from_user_sessions.return_value = {}
        mock_digest_agent.get_daily_digest.return_value = {
            'recent_resources_upload': ['test.pdf'],
            'session_count': 1
        }
        
        # Mock agent formatting
        mock_agent_instance = Mock()
        mock_agent_instance.run.return_value = "Test digest content"
        mock_agent = Mock(return_value=mock_agent_instance)
        
        with patch('percolate.Agent', mock_agent):
            # Mock email service to raise an exception
            mock_email_instance = Mock()
            mock_email_instance.send_digest_email_from_markdown.side_effect = Exception("Email service error")
            mock_email_service.return_value = mock_email_instance
            
            mock_audit_instance = Mock()
            mock_audit_service.return_value = mock_audit_instance
            
            # Execute the task
            task_manager.dispatch_task(daily_digest_schedule)
            
            # Verify that email sending was attempted
            mock_email_instance.send_digest_email_from_markdown.assert_called_once()
            
            # Verify that a failure audit was recorded
            failure_audit_calls = [
                call for call in mock_audit_instance.audit.call_args_list
                if call[0][0] == mock_email_service and call[0][1] == AuditStatus.Fail
            ]
            assert len(failure_audit_calls) == 1
            
            # Verify the failure audit contains error information
            failure_call = failure_audit_calls[0]
            assert failure_call[0][2]['user_id'] == sample_user['id']
            assert 'sending digest' in failure_call[0][2]['event']
    
    @patch('percolate.services.tasks.TaskManager.EmailService')
    @patch('percolate.services.tasks.TaskManager.AuditService')
    @patch('percolate.services.tasks.TaskManager.Engram')
    @patch('percolate.services.tasks.TaskManager.DigestAgent')
    @patch('percolate.repository')
    def test_daily_digest_skips_users_without_content(self, mock_repository, mock_digest_agent,
                                                      mock_engram, mock_audit_service, mock_email_service,
                                                      task_manager, daily_digest_schedule, sample_user):
        """
        Test that the Daily Digest task skips users who have no new content (no uploads, sessions, or resources)
        """
        # Mock the repository to return our sample user
        mock_user_repo = Mock()
        
        def mock_execute(query, data=None):
            if 'email_subscription_active' in query:
                return [sample_user]
            elif 'tus_upload_analytics' in query and 'COUNT(DISTINCT upload_id)' in query:
                # Return empty upload analytics
                return [{
                    'total_uploads_24h': 0,
                    'completed_uploads_24h': 0,
                    'failed_uploads_24h': 0,
                    'uploads_with_resources_24h': 0,
                    'total_resources_created_24h': 0,
                    'successful_resource_creations_24h': 0,
                    'uploaded_files_24h': [],
                    'resource_categories_24h': [],
                    'total_bytes_uploaded_24h': 0,
                    'avg_upload_progress_24h': 0
                }]
            elif 'tus_upload_analytics' in query and 'filename' in query:
                return []
            return []
        
        mock_user_repo.execute = mock_execute
        mock_repository.return_value = mock_user_repo
        
        # Mock DigestAgent to return empty content
        mock_engram._add_memory_from_user_sessions.return_value = {}
        mock_digest_agent.get_daily_digest.return_value = {
            'recent_resources_upload': None,
            'session_count': 0
        }
        
        # Mock services
        mock_email_instance = Mock()
        mock_email_service.return_value = mock_email_instance
        
        # Execute the task
        task_manager.dispatch_task(daily_digest_schedule)
        
        # Verify that no email was sent for users without content
        mock_email_instance.send_digest_email_from_markdown.assert_not_called()


    @patch('percolate.services.tasks.TaskManager.EmailService')
    @patch('percolate.services.tasks.TaskManager.AuditService')
    @patch('percolate.services.tasks.TaskManager.Engram')
    @patch('percolate.services.tasks.TaskManager.DigestAgent')
    @patch('percolate.repository')
    def test_daily_digest_includes_upload_analytics(self, mock_repository, mock_digest_agent,
                                                    mock_engram, mock_audit_service, mock_email_service,
                                                    task_manager, daily_digest_schedule, sample_user):
        """
        Test that the Daily Digest properly includes upload analytics from the TUS view
        """
        # Mock the repository
        mock_user_repo = Mock()
        
        def mock_execute(query, data=None):
            if 'email_subscription_active' in query:
                return [sample_user]
            elif 'tus_upload_analytics' in query and 'COUNT(DISTINCT upload_id)' in query:
                # Return comprehensive upload analytics
                return [{
                    'total_uploads_24h': 10,
                    'completed_uploads_24h': 8,
                    'failed_uploads_24h': 2,
                    'uploads_with_resources_24h': 7,
                    'total_resources_created_24h': 25,
                    'successful_resource_creations_24h': 7,
                    'uploaded_files_24h': ['report1.pdf', 'report2.pdf', 'data.csv', 'image1.png', 'image2.jpg'],
                    'resource_categories_24h': ['document', 'data', 'image'],
                    'total_bytes_uploaded_24h': 157286400,  # 150 MB
                    'avg_upload_progress_24h': 85.0
                }]
            elif 'tus_upload_analytics' in query and 'filename' in query:
                return [
                    {
                        'filename': 'large_report.pdf',
                        'upload_status': 'failed',
                        'resource_status': 'no_resources_created',
                        'resource_count': 0,
                        'upload_created_at': '2024-01-15T09:00:00Z',
                        'upload_progress_pct': 45.0,
                        'total_size': 52428800,
                        'categories': []
                    }
                ]
            return []
        
        mock_user_repo.execute = mock_execute
        mock_repository.return_value = mock_user_repo
        
        # Mock other services
        mock_engram._add_memory_from_user_sessions.return_value = {}
        mock_digest_agent.get_daily_digest.return_value = {
            'recent_resources_upload': [],
            'session_count': 0  # No sessions, only uploads
        }
        
        # Mock agent formatting
        mock_agent_instance = Mock()
        mock_agent_instance.run.return_value = "Digest with upload analytics"
        mock_agent = Mock(return_value=mock_agent_instance)
        
        with patch('percolate.Agent', mock_agent):
            mock_email_instance = Mock()
            mock_email_service.return_value = mock_email_instance
            
            mock_audit_instance = Mock()
            mock_audit_service.return_value = mock_audit_instance
            
            # Execute the task
            task_manager.dispatch_task(daily_digest_schedule)
            
            # Verify the agent was called with content including upload analytics
            mock_agent.assert_called_once_with(DigestAgent)
            agent_run_call = mock_agent_instance.run.call_args[0][0]
            
            # Check that upload analytics was included in the content
            assert 'upload_analytics' in agent_run_call
            assert 'total_uploads_24h' in agent_run_call
            assert 'total_size_human_readable' in agent_run_call
            
            # Verify email was sent (because there were uploads)
            mock_email_instance.send_digest_email_from_markdown.assert_called_once()


if __name__ == "__main__":
    pytest.main([__file__, "-v"])