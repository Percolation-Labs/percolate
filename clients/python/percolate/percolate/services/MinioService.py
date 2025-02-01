from minio import Minio
from percolate.utils.env import MINIO_SECRET, MINIO_SERVER,MINIO_P8_BUCKET
import io
from minio.error import S3Error

class MinioService:
    """a service wrapper for minio"""
    def __init__(self):
        self.minio_client = Minio(
            MINIO_SERVER,
            access_key="percolate",
            secret_key=MINIO_SECRET,
            secure=False
        )
        self.ensure_bucket_exists(MINIO_P8_BUCKET)
        
    def ensure_bucket_exists(self, bucket_name):
        """setup percolate"""
        try:
            if not self.minio_client.bucket_exists(bucket_name):
                self.minio_client.make_bucket(bucket_name)
            else:
                pass
        except S3Error as e:
            raise e
        
    def add_file(self, filename:str, content : bytes, content_type:str):
        """
        add a file to minio
        """
        length = len(content)
        content = io.BytesIO(content)
        try:
            self.minio_client.put_object(
                MINIO_P8_BUCKET,
                filename,
                data=content,
                length=length,
                content_type=content_type
            )
        except Exception as ex:
            ##TODO
            raise ex

    #add from http