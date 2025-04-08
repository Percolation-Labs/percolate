# The Chat interface

The Chat interface is a proxy for language models like OpenAI, Anthropic and Google. It provides a unified API to work with different LLM providers.

## Implementation Plan

1. **Dialect Support**: We will implement each dialect one at a time in both streaming and non-streaming modes:
   - OpenAI (default model) - completions API
   - Anthropic - Claude models
   - Google - Gemini models
   
2. **Streaming Support**: 
   - Server-Sent Events (SSE) for real-time responses
   - Toggle regular request streaming based on a request parameter `use_sse`

3. **Cross-Dialect Compatibility**:
   - Enable calling ANY model in any dialect
   - For example, use OpenAI specification to call Anthropic models or use Anthropic's schema to call OpenAI/Google models
   - The API will detect the desired dialect based on the request format and translate parameters appropriately

4. **Implementation Strategy**:
   - Implement one feature at a time with thorough testing
   - Reuse code from `percolate.services.llm` including:
     - `utils.py` - Streaming adapters for different LLM providers
     - `LanguageModel.py` - Conversion logic between different dialects to canonical OpenAI format
   - The existing Pydantic models in `models.py` will be enhanced to support validation and parameter transformation

5. **Core Functionality**:
   - `completions` endpoint to map between any dialect and call underlying LLM APIs
   - Parameter translation between dialects
   - Token usage tracking
   - Tool/function calling support

6. **Auditing and Monitoring**:
   - Implement finalizers in both streaming and non-streaming modes
   - Audit all requests and responses in the Percolate database
   - Track token usage and other metrics

7. **Metadata Support**: Add these parameters to completions endpoint:
   - `user_id` - ID of the end user making the request
   - `session_id` - ID for grouping related interactions
   - `channel_id` - ID of the channel where the interaction happens
   - `channel_type` - Type of channel (e.g., slack, web, etc.)
   - `api_provider` - Override the default provider (defaults to null)
   - `use_sse` - Whether to use Server-Sent Events for streaming

## Needed Refactoring

1. Refactor `LanguageModel.py` to make it more general and support a cleaner interface for cross-dialect calls
2. Update streaming utilities in `utils.py` to better handle edge cases with function/tool calls
3. Create handler functions for each dialect (`handle_request`, `handle_anthropic_request`, `handle_google_request`)
4. Enhance the Pydantic models to detect dialect type from request format

## Test Coverage Required

1. **Unit Tests**:
   - Test all combinations of request dialects (OpenAI, Anthropic, Google)
   - Test all combinations of model providers (OpenAI, Anthropic, Google)
   - Test both streaming and non-streaming modes
   - Test with and without SSE
   - Test function/tool calling across all dialects

2. **Integration Tests**:
   - Full request-response cycle including auditing
   - Error handling and rate limiting
   - Token counting and usage tracking

3. **Test Payloads**:
   - Create example payloads for each dialect
   - Include function calling examples for each dialect
   - Test conversion between dialects with the same payload

## Auditing in Percolate

We will implement a comprehensive auditing system to track:
- All requests to LLMs
- User questions in sessions
- Token usage
- Function/tool calls
- Response time and quality metrics
- Error rates and types

This will be implemented in both streaming and non-streaming modes using finalizer callbacks.


``` 
⏺ We've implemented a comprehensive chat proxy API for Percolate that can handle different LLM provider dialects. Here's a summary of what we've accomplished:

  1. Enhanced README documentation:
    - Detailed the implementation plan for the chat proxy
    - Outlined the testing strategy and requirements
    - Documented needed refactoring for services
  2. Pydantic Models for Different Dialects:
    - Updated the models.py with comprehensive models for all dialects (OpenAI, Anthropic, Google)
    - Added conversion methods between formats
    - Implemented dialect detection logic
    - Added metadata support
  3. Router Implementation:
    - Created specialized handler functions for each dialect
    - Added streaming support with both standard and SSE options
    - Implemented dialect detection and routing
    - Added metadata extraction and auditing placeholders
    - Added agent integration endpoints
  4. Testing Framework:
    - Created a comprehensive test file with test cases for:
        - Dialect detection
      - Format conversion between dialects
      - Response conversion
      - Handler functions
      - Metadata extraction

  The implementation provides:

  1. Unified API - The ability to call any LLM provider using any dialect format
  2. Streaming Support - Both standard streaming and SSE for real-time responses
  3. Cross-Dialect Compatibility - Transparent parameter translation between dialects
  4. Metadata Support - For tracking, auditing, and session management
  5. Auditing Capabilities - With hooks for database logging
  6. Agent Integration - For more complex workflows

  Next steps to complete the implementation:

  1. Implement actual database auditing (currently placeholders)
  2. Add support for function/tool calling across all dialects
  3. Complete the integration tests
  4. Implement rate limiting and error handling
  5. Add more comprehensive error messages and logging

  This implementation establishes a solid foundation for the chat proxy, allowing Percolate to provide a unified interface to different LLM providers while maintaining consistent behavior and tracking.
```