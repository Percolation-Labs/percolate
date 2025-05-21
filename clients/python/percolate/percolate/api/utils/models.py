"""
Shared utility functions for listing models across different endpoints.
"""
from percolate.models.p8 import LanguageModelApi
import percolate as p8


def list_available_models():
    """
    List the models that have configured tokens in the Percolate database.
    Only models with tokens set will be shown.
    
    Returns:
        dict: OpenAI-compatible model list response
    """
    data = p8.repository(LanguageModelApi).execute(
        """SELECT name as id, token_env_key, created_at as created, updated_at as updated 
           FROM p8."LanguageModelApi" 
           WHERE token IS NOT NULL"""
    )
    
    models = [{
        'id': r['id'],
        'created': r['created'],
        'updated': r['updated'],
        'object': 'model',
    } for r in data]
    
    return {'object': 'list', 'data': models}