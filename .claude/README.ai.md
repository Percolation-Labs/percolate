# AI Assistant Notes

This document captures high-level notes, guidelines, and structural overviews for future reference when working on the repository.

## 1. Repository Structure Overview
- `percolate/`
  - `api/`: FastAPI application with modular route packages (auth, entities, tasks, tools, integrations, etc.)
  - `models/`: Pydantic-based data models and helper classes (AbstractModel, MessageStack, p8 types)
  - `services/`: Business logic layers encapsulating operations beyond simple CRUD
  - `utils/`: Utility functions and helpers (e.g., SQL model helpers)
  - `cli.py`, `interface.py`: Entry points for command-line interfaces and programmatic access
- `notebooks/`: Example and exploratory Jupyter notebooks
- `scripts/`: Helper scripts for setup, migrations, or utilities
- `dist/`, `build artifacts`: Compiled/distribution packages (ignored in source)
- Root files: `README.md`, `pyproject.toml`, `Dockerfile`, tests, etc.

## 2. Development Guidelines
1. **Modular Design**: Break features into small, single-responsibility functions or classes. Keep layers separated:
   - API routes: HTTP handling, request/response models
   - Services: Business operations and orchestration
   - Repository/DAO: Data persistence (generic repository pattern over Pydantic models)
   - Models: Pure data structures (Pydantic) and domain entities
2. **Code Robustness**: Write clear docstrings, type hints, and input validation. Use Pydantic schemas for request/response validation.
3. **Repository Pattern**: Utilize the existing generic repository to implement CRUD for any model:
   - Define a repository interface or base class in `percolate/services` or `utils`
   - Extend per-entity repositories as needed
4. **Testing**: Cover:
   - Unit tests for services, repositories, and utility functions
   - Integration tests for API endpoints using `TestClient` (FastAPI)
   - Use fixtures for database setup/teardown
5. **Commits & Diff Awareness**: Commit frequently with descriptive messages. Keep changes scoped to logical units to ease code review.
6. **Documentation**: Update `README.md` and in-code docstrings for new features. Include usage examples and API specs where applicable.

## 3. Future Tasks and Priorities
- Audit existing API routes for missing CRUD operations
- Implement generic repository adapters for each data store (SQL, DuckDB, Iceberg)
- Build out authentication/authorization flows in `percolate/api/routes/auth`
- Add unit/integration tests around core business workflows
-- Create CI/CD pipelines to automate tests and linting
  
## 4. Agentic Streaming & ModelRunner Proxy
This section describes how the `ModelRunner.iter_lines` method and `HybridResponse` class work together to provide a seamless
Server-Sent Events (SSE) streaming experience, while supporting function/tool calls, activity auditing, and multi-model
schemes (OpenAI, Anthropic, Google).
  
### 4.1 Streaming Loop with Tool Interception
- **HybridResponse** wraps any streaming HTTP response (e.g. OpenAI SSE, Anthropic SSE) to:
  - Buffer SSE-formatted text chunks (`data: ...\n\n`).
  - Detect and collect LLM-initiated tool/function calls (`function_call` deltas).
  - Optionally emit dedicated SSE events (`event: function_call`) when tools are invoked.
  - Accumulate full text content (`.content`) and a list of parsed `FunctionCall` objects (`.tool_calls`).
- **ModelRunner.iter_lines** orchestrates an agentic loop:
  1. Constructs a hybrid-streaming `CallingContext` so that the language model client returns a `HybridResponse`.
  2. Builds the initial `MessageStack` (system prompt, user question, any preload data).
  3. Enters up to `max_iterations` loops:
     - Calls the LLM in hybrid-streaming mode, receiving a `HybridResponse`.
     - Reads its SSE stream until the first `event: function_call` or end-of-stream:
         * Yields normal `data: ...` text chunks for the user.
         * On intercepting a tool call, yields a placeholder SSE notification (e.g. `data: I'm working on it...`).
     - If a tool call was detected:
         * `ModelRunner.invoke()` executes each `FunctionCall` via the `FunctionManager`.
         * The function results are formatted and appended back into `self.messages` which are used internally for sub sequent calls and not shown by default to the user.
         * Loop repeats to stream the function-augmented LLM output.
     - If no tool calls remain:
         * Drains remaining text chunks to the user.
         * Converts the buffered stream into a structured `AIResponse` via `LanguageModel.parse()` so that we can audit AI responses in a unified format in Percolate DB.
         * Exits the loop.
  
### 4.2 Audit & Memory Proxy
- On completion (with or without tool calls), the final structured `AIResponse` (including tokens, status,
  and any tool call results) is recorded via `p8.dump(...)`, together with:
  - Original question
  - Full message history (`self.messages.data`)
  - The streaming context (session ID, model settings)
  - Agent identifier
- This audit serves as a **memory proxy**, enabling:
  - Persisted user/agent exchanges.
  - Detailed tooling evaluation records.
  - Rehydration of conversation state or tool-use in downstream processes.
  
### 4.3 Supported Schemes and Extensibility
- Out of the box, **OpenAI**, **Anthropic**, and **Google** streaming schemes are supported via separate adapters
  (`stream_openai_response`, `stream_anthropic_response`, `stream_google_response`).
- `HybridResponse` currently focuses on OpenAI-style JSON deltas; non-OpenAI schemes should be tested:
  - Ensure function calls in Anthropic SSE are detected and buffered correctly.
  - Verify Google SSE adaptation aligns with its `candidates`/`parts` format.
- The pattern is general and can be extended to additional SSE-based LLM providers by adding new adapters.
  
### 4.4 Gotchas & Considerations
- **Buffer Growth**: `HybridResponse` buffers all SSE lines and function calls in memory; for very large responses, consider
  streaming raw chunks to disk or windowing the buffer.
- **Ordering**: Concurrent or interleaved function calls must be carefully re-ordered; complex multi-tool workflows may need
  priority rules or tooling-specific markers.
- **Error Handling**: Partial JSON chunks or HTTP errors may interrupt the SSE stream; adapters should robustly catch and
  relay errors as SSE events (e.g. `event: error`).
- **Session Context**: `session_id` and `CallingContext` must propagate correctly through recursive calls to support audit and
  rehydration; ensure any context overrides (e.g. `in_streaming_mode`) preserve critical metadata.
- **ToolResponse Formatting**: The `MessageStackFormatter` must format function results correctly across schemes (JSON vs list
  of blocks); cross-check tool result schemas for Anthropic and Google.
  
_This framework provides a solid foundation for agent-based SSE streaming with LLMs, tool calling, and audit logging._

> _These notes will evolve as the project grows and new modules are added._