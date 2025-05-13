"""
Sync models for maintaining file synchronization state with external providers.
"""

from .models import (
    SyncProvider,
    SyncConfig,
    SyncCredential,
    SyncFile,
    SyncStatus,
    SyncFileStatus,
    SyncLog,
    GoogleDriveProvider,
    register_sync_models
)

__all__ = [
    "SyncProvider",
    "SyncConfig",
    "SyncCredential",
    "SyncFile",
    "SyncLog",
    "SyncStatus",
    "SyncFileStatus",
    "GoogleDriveProvider",
    "register_sync_models"
]

if __name__ == "__main__":
    """this is a convenience to sync this module which is optional
    for example set the P8_PG_PORT to your test port if different e.g. maybe its 15432
    also set the password to the databases password e.g. set  P8_PG_PASSWORD=$P8_TEST_BEARER_TOKEN
    """
    register_sync_models()