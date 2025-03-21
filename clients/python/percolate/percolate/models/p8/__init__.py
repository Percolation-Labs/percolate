"""the p8 schema models for registration"""

from .types import Function
from .types import *
from .PlanModel import PlanModel

sample_models = [
    LanguageModelApi(id = make_uuid('gpt-4o-2024-08-06'), name = 'gpt-4o-2024-08-06', scheme='openai', completions_uri='https://api.openai.com/v1/chat/completions', token_env_key='OPENAI_API_KEY'),
    LanguageModelApi(id = make_uuid('gpt-4o-mini'), name = 'gpt-4o-mini', scheme='openai', completions_uri='https://api.openai.com/v1/chat/completions', token_env_key='OPENAI_API_KEY'),
    LanguageModelApi(id = make_uuid('cerebras-llama3.1-8b'), name = 'cerebras-llama3.1-8b', model='llama3.1-8b', scheme='openai', completions_uri='https://api.cerebras.ai/v1/chat/completions', token_env_key='CEREBRAS_API_KEY'),
    LanguageModelApi(id = make_uuid('groq-llama-3.3-70b-versatile'), name = 'groq-llama-3.3-70b-versatile', model='llama-3.3-70b-versatile', scheme='openai', completions_uri='https://api.groq.com/openai/v1/chat/completions', token_env_key='GROQ_API_KEY'),
    LanguageModelApi(id = make_uuid('claude-3-5-sonnet-20241022'), name = 'claude-3-5-sonnet-20241022', scheme='anthropic', completions_uri='https://api.anthropic.com/v1/messages', token_env_key='ANTHROPIC_API_KEY'),
    LanguageModelApi(id = make_uuid('claude-3-7-sonnet-20250219'), name = 'claude-3-7-sonnet-20250219', scheme='anthropic', completions_uri='https://api.anthropic.com/v1/messages', token_env_key='ANTHROPIC_API_KEY'),
    LanguageModelApi(id = make_uuid('gemini-1.5-flash'), name = 'gemini-1.5-flash', scheme='google', completions_uri='https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent', token_env_key='GEMINI_API_KEY'),
    LanguageModelApi(id = make_uuid('gemini-2.0-flash'), name = 'gemini-2.0-flash', scheme='google', completions_uri='https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent', token_env_key='GEMINI_API_KEY'),
    LanguageModelApi(id = make_uuid('gemini-2.0-flash-thinking-exp-01-21'), name = 'gemini-2.0-flash-thinking-exp-01-21', scheme='google', completions_uri='https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash-thinking-exp-01-21:generateContent', token_env_key='GEMINI_API_KEY'),
    LanguageModelApi(id = make_uuid('gemini-2.0-pro-exp-02-05'), name = 'gemini-2.0-pro-exp-02-05', scheme='google', completions_uri='https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-pro-exp-02-05:generateContent', token_env_key='GEMINI_API_KEY'),
    LanguageModelApi(id = make_uuid('deepseek-chat'), name = 'deepseek-chat', scheme='openai', completions_uri='https://api.deepseek.com/chat/completions', token_env_key='DEEPSEEK_API_KEY'),
    LanguageModelApi(id = make_uuid('grok-2-latest'), name = 'grok-2-latest', scheme='openai', completions_uri='https://api.x.ai/v1/chat/completions', token_env_key='XAI_API_KEY'),    
]

 
"""
#here is an example of how to add model - you can pull the token from your env if you are ok to save in your database for testing etc.
from percolate.services import PostgresService
from percolate.models.p8 import LanguageModelApi
from percolate.utils import make_uuid
PostgresService().update_records(LanguageModelApi(id = make_uuid('grok-2-latest'), name = 'grok-2-latest', scheme='openai', completions_uri='https://api.x.ai/v1/chat/completions', token_env_key='XAI_API_KEY'))
"""