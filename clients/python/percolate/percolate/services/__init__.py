from .PostgresService import PostgresService
from .OpenApiService import OpenApiSpec, OpenApiService
from .FunctionManager import FunctionManager
from .MinioService import MinioService
from .S3Service import S3Service
from .EmailService import EmailService
from .FileSystemService import FileSystemService
from .ModelCache import get_model, cache_model, clear_cache, get_cache_stats, ModelCache
from .ModelRunnerCache import get_runner, cache_runner, clear_runner_cache, get_runner_cache_stats, ModelRunnerCache
from percolate.models import Audit, AuditStatus
import traceback
from percolate.utils import logger
import uuid

"""some system services"""
class AuditService:
    """generic audit service to make it easy to log generic events"""
    def audit(self, caller, status:AuditStatus, payload:dict, error_trace:str=None):
        """
        generic audit 
        """
        
        import percolate as p8
        
        try:
            a = Audit(id=str(uuid.uuid1()),caller=str(caller), status = status.value, status_payload=payload, error_trace=error_trace)
        except:
            logger.warning(f"Fatal - {traceback.format_exc()}")
            raise
            #a = Audit.safe_audit_fail(str(caller), traceback.format_exc())
        
        return p8.repository(Audit).update_records(a)
        
