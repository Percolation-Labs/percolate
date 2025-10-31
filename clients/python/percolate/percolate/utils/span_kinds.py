"""
OpenInference span kind constants for Phoenix AI observability.

Phoenix uses the 'openinference.span.kind' attribute to categorize and visualize
different types of AI operations in its UI. This module provides constants and
utilities for working with OpenInference span kinds.

References:
- OpenInference Semantic Conventions: https://arize-ai.github.io/openinference/spec/semantic_conventions.html
- Phoenix Documentation: https://docs.arize.com/phoenix
"""

from enum import Enum


class OpenInferenceSpanKind(str, Enum):
    """
    OpenInference span kinds for Phoenix AI observability.

    These values are set on the 'openinference.span.kind' attribute
    to help Phoenix categorize and visualize different types of operations.
    """

    LLM = "LLM"
    """Large Language Model API calls (OpenAI, Anthropic, etc.)"""

    AGENT = "AGENT"
    """Autonomous agent operations and workflows"""

    CHAIN = "CHAIN"
    """Workflow steps, sequences, or pipeline operations"""

    TOOL = "TOOL"
    """Function/tool calls used by agents"""

    RETRIEVER = "RETRIEVER"
    """Vector search, document retrieval, or RAG operations"""

    RERANKER = "RERANKER"
    """Document reranking operations"""

    EMBEDDING = "EMBEDDING"
    """Text or multimodal embedding generation"""

    UNKNOWN = "UNKNOWN"
    """Fallback for unclassified operations"""


# Attribute name constant for OpenInference span kind
OPENINFERENCE_SPAN_KIND = "openinference.span.kind"

# Attribute name constant for OpenInference project name
OPENINFERENCE_PROJECT_NAME = "openinference.project.name"
