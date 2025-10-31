import typing
import traceback
import percolate as p8
from pydantic import BaseModel
from percolate.utils import logger
from percolate.models.p8 import Function
from .FunctionManager import FunctionManager
from percolate.models import AbstractModel, MessageStack
from percolate.services.llm import (
    CallingContext,
    FunctionCall,
    LanguageModel,
    MessageStackFormatter,
)

import uuid
from percolate.services.llm.proxy.unified_stream_adapter import UnifiedStreamAdapter

# OpenTelemetry imports
from opentelemetry import trace
from opentelemetry.trace import SpanKind
from percolate.utils.otel_utils import (
    is_tracing_enabled,
    get_tracer,
    set_llm_attributes,
    set_generation_attributes,
    set_trace_attributes,
    add_tool_call_event,
    add_tool_result_event,
    mark_span_as_error,
    set_span_kind,
)
from percolate.utils.span_kinds import OpenInferenceSpanKind

tracer = get_tracer(__name__)

GENERIC_P8_PROMPT = """\n# General Advice.
Use whatever functions are available to you and use world knowledge only if prompted 
or if there is not other way 
or the user is obviously asking about real world information that is not covered by functions.

- Observe what functions you have to use and check the message history to avoid calling the same functions with the same parameters repeatedly.
- Your Agent Name is given below and you never need to activate [Agent Name] as a function since the context is already loaded.
- If you encounter a function name that is not your name such as those lists under agent functions, you can activate it with the provided tool to activate_function_by_name assuming you have the correct function name. You should do so without asking the user.
- When generating large output observe the notification that needs to be called first, call it and continue.
Of you call a function that is running another agent, you should always pass the full context from the user in the question. Do not shorten or ask simpler questions which loses the users context.
- you can use the users context if you are given -for example it may be useful to use their recent chat history or ai responses if they seem to be referring to older context.
 If you do use recent context do not explain or ask for confirmation as this can be jarring for the user.
            """


class ModelRunner:
    """The model runner manages chaining agents and reasoning steps together in the execution loop
    We had functions implementing the p8 model runner interface which is also in db native functions
    """

    @property
    def name(self):
        return self.agent_model.get_model_full_name()

    def __init__(
        self, model: BaseModel = None, allow_help: bool = True, depth: int = 0, **kwargs
    ):
        """
        A model is passed in or the default is used.
        This supplies the agent context such as prompt and functions.
        If the model has no functions simple Q&A can still be exchanged with LLMs.
        More generally the model can provide a structured response format.
        see TODO: for guidance.
        """
        self._context = None
        self.depth = depth  # TODO consider ways to control depth
        self._init_data = kwargs.get("init_data")
        """the agent model is any Pydantic Base model or Abstract model that implements the agent interface"""
        self.agent_model: AbstractModel = AbstractModel.Abstracted(model)
        """a function manager allows for activating functions at runtime and searching and planning over functions"""
        self._function_manager = FunctionManager()
        """the help option links in to the function manager planner"""
        self._allow_help = allow_help

        # Get user context for row-level security
        self.user_id = kwargs.get("user_id")
        self.user_groups = kwargs.get("user_groups")
        self.role_level = kwargs.get("role_level")

        """the repository provides the Percolate database instance"""
        self.repo = self.get_repo()

        """initialize activates the agent model e.g. functions and prompt for use"""
        self.initialize()
        """the messages stack is the most important control element for llm agent sessions"""
        self.messages = MessageStack(None)
        logger.info(f"******Constructed agent {self.name}******")

    def get_repo(self):
        """
        get the repo and use the user context of its given
        """

        repo = p8.repository(
            self.agent_model,
            user_id=self._context.user_id if self._context is not None else None,
            role_level=self._context.role_level if self._context is not None else None,
        )

        ui_context = self._context.user_id if self._context is not None else None
        logger.debug(
            f"[[{ui_context}]]] got repo for user {ui_context} with roles {repo.user_groups} and {repo.role_level=}"
        )

        return repo

    def __repr__(self):
        return f"Runner({self.name})"

    def initialize(self):
        """Register the functions and other metadata from the agent model"""
        self._context = None
        if self._allow_help:
            self._function_manager.add_function(self.help)  # :)
        """register the model's functions which can include function search"""
        self._function_manager.activate_agent_context(self.agent_model)
        """the basic bootstrapping means asking for help, entities(types) or functions"""
        self._function_manager.add_function(self.get_entities)
        self._function_manager.add_function(self.search)
        self._function_manager.add_function(self.activate_functions_by_name)

        # Conditionally add web search based on agent metadata
        # Check model_config for metadata (from Agent.load) or metadata attribute
        metadata = getattr(self.agent_model, 'metadata', None) or self.agent_model.model_config
        if metadata.get('allow_web_search'):
            self._function_manager.add_function(self.search_the_web)

        # Conditionally add image generation based on agent metadata
        if metadata.get('allow_generate_image'):
            if hasattr(self, 'generate_image'):
                self._function_manager.add_function(self.generate_image)

        # self._function_manager.add_function(self.announce_generate_large_output)
        """more complex things will happen from here when we traverse what comes back"""

    def announce_generate_large_output(self, estimated_length: int = None):
        """When you are about to generate a lot of output, please call this function with a rough estimate of the size of the content.
        You do not need to do this when you are responding with simple structured responses which are typically small or with simple answers.
        However when generating lots of text we would like to request via streaming or async so we want to know before generating a lot of text.
        We use to distinguish internal content gathering nodes from final response generation for users.
        """
        logger.warning(f"The model is requesting to output: {estimated_length=}")
        return {"message": "acknowledged", "output_size_estimate": estimated_length}

    def search(self, questions: typing.List[str], user_id: str | uuid.UUID = None):
        """Search INTERNAL/LOCAL knowledge base and user data using RAG (Retrieval Augmented Generation).
        **IMPORTANT**: This searches LOCAL/INTERNAL data only - NOT the web/internet.
        Use this ONLY for: documents, stored knowledge, internal databases, and user-specific data.

        For web/internet searches, you MUST use search_the_web function instead.
        To find available functions, use help function instead of search.

        If you want to add multiple questions supply a list of strings as an array.
        Do not search for functions if there is already a function on the agent that you can activate.

        Args:
            questions: ask one or more questions to search the LOCAL/INTERNAL data store (NOT the web)
            user_id: optional user identifier (email or UUID) for access control
        """
        # If no user_id provided, try to get from:
        # 1. Explicitly passed user_id parameter
        # 2. Context username
        # 3. ModelRunner's stored user_id
        if user_id is None:
            if self._context and self._context.username:
                user_id = self._context.username
            else:
                user_id = self.user_id

        return self.get_repo().search(questions, user_id=str(user_id))

    def search_the_web(self, query: str, max_results: int = 5):
        """Search the internet using Tavily web search API.
        Use this to find current information, news, or web content - NOT for searching internal data.
        For searching internal knowledge base, use the search function instead.

        Args:
            query: The search query to look up on the internet
            max_results: Maximum number of search results to return (default 5)
        """
        from percolate.utils.env import TAVILY_API_KEY
        import requests

        if not TAVILY_API_KEY:
            return {
                "error": "TAVILY_API_KEY environment variable is not set. Cannot perform web search."
            }

        try:
            response = requests.post(
                "https://api.tavily.com/search",
                json={
                    "api_key": TAVILY_API_KEY,
                    "query": query,
                    "max_results": max_results,
                },
                timeout=30,
            )

            if response.status_code in [200, 201]:
                return response.json()
            else:
                return {
                    "error": f"Tavily API returned status {response.status_code}: {response.text}"
                }

        except Exception as ex:
            logger.error(f"Error calling Tavily search API: {ex}")
            return {"error": f"Failed to perform web search: {str(ex)}"}

    def generate_image(
        self,
        prompt: str,
        size: str = "1024x1024",
        quality: str = "standard",
        style: str = "vivid",
    ):
        """Generate an image from a text description using DALL-E 3.

        Use this when the user asks you to create, generate, or visualize an image.
        The generated image will be returned as a URL that can be displayed to the user.

        Args:
            prompt: Detailed text description of the image to generate
            size: Image dimensions - "1024x1024" (square), "1024x1792" (portrait), or "1792x1024" (landscape)
            quality: Image quality - "standard" or "hd" (higher detail, costs more)
            style: Image style - "vivid" (hyper-real and dramatic) or "natural" (more natural, less hyper-real)

        Returns:
            Dictionary with image URL and metadata
        """
        from percolate.services.llm.ImageGenerator import ImageGenerator

        try:
            generator = ImageGenerator()
            result = generator.generate_image(
                prompt=prompt,
                model=ImageGenerator.DALLE_3,
                size=size,
                quality=quality,
                style=style,
                n=1,
                response_format="url",
            )
            return result
        except Exception as ex:
            logger.error(f"Error generating image: {ex}")
            return {"error": f"Failed to generate image: {str(ex)}"}

    def activate_functions_by_name(self, function_names: typing.List[str], **kwargs):
        """Provide a list of function names to load.
        The names should be fully qualified object_id_function_name and we use underscores in place of periods which are illegal.
        You should not try to activate self as a function. For example if your name is x_Agent, do not try to activate yourself.
        If there are functions on an agent you can activate them without searching.
        """

        logger.debug(
            f"activating function {function_names} - ill replace any '.' with underscores!!"
        )

        for f in function_names:
            f = f.replace(".", "_")

            if f == self.agent_model.get_model_full_name():
                raise Exception(
                    "Error - you should not try to load yourself {f} since you are loaded as a callable agent already. Find another function to use in your available functions"
                )
        missing = self._function_manager.add_functions_by_key(function_names)
        available = set(function_names) - set(missing)
        missing_message = (
            f"" if not missing else f" But the functions {missing} could not be loaded"
        )
        """todo check status"""
        return {
            "status": f"Re: the functions {list(available)} are now ready for use. please go ahead and invoke using the full function name. for example for a function called p8_agent_run do not just call run but call p8_agent_run"
            + missing_message
        }

    def get_entities(self, keys: typing.Optional[str], allow_fuzzy_match: bool = False):
        """Lookup entity by one or more keys. For example if you encounter entity names or keys in question, data etc you can use
        the entity search to learn more about them.

        If you get no results with exact matching, you should try again with allow_fuzzy_match=True. This is especially useful for:
        - SKUs or codes that might be slightly misspelled (e.g., KT2011 instead of KT-2011)
        - Names with typos or variations
        - Any keys that look inexact or may have formatting differences

        Args:
            keys: one or more names to use to lookup the entity or entities
            allow_fuzzy_match: if True, uses fuzzy matching to find entities when exact matches fail
        """
        logger.debug(f"get_entities/{keys=}, {allow_fuzzy_match=}")

        """the function manager can load context and we can also adorn entities with extra metadata"""
        entities = self.get_repo().get_entities(
            keys, allow_fuzzy_match=allow_fuzzy_match
        )

        return entities

    def help(self, questions: str | typing.List[str], context: str = None):
        """If you are stuck ask for help with very detailed questions to help the planner find resources for you. You should execute whatever plan you are given.
        If you know the names of the functions you are looking for you should provide this hint.
        If you have a hint about what the source or tool to use hint that in each question that you ask - you should see ' i need functions or tools to...' do something and ask for a plan that involves tool use.
        For example, you can either just ask a question or you can ask "according to resource X" and then ask the question. This is important context.

        Args:
            questions (str): provide detailed questions to guide the planner. you should augment the users question with the additional context that you have e.g. a known source
            context: any added context e.g. what tool, function, source the user or system suggests may know the answer
        """

        try:
            if context:
                questions = f"Using context: {context}, {questions}"

            """for now strict planning is off"""
            plan = self._function_manager.plan(questions)
        except Exception as ex:
            logger.warning(f"Failed to call help {ex}")
            return {"message": "planning pending - i suggest you use world knowledge"}

        """describe the plan context e.g. its a plan but you need to request the functions and do the thing -> update message stack"""

        return {
            "message": "please execute this plan for the user. any functions that are mentioned can be activated using the `activate_functions_by_name` by tool",
            "plan": plan,
        }

    def invoke(self, function_call: FunctionCall):
        """Invoke function(s) and parse results into messages

        Test calling a function:>

        .invoke(FunctionCall(id='test', name='some_functions', arguments={'arg': 'value'}))

        Args:
            function_call (FunctionCall): the payload send from an LLM to call a function
        """
        logger.info(f"({self.name}){function_call=}")

        # OTEL: Create a TOOL span for this tool invocation
        import json
        tool_span = None
        tool_span_context = None
        if is_tracing_enabled():
            tracer = trace.get_tracer(__name__)
            # Use context manager properly to avoid premature span ending
            tool_span_context = tracer.start_as_current_span(
                f"tool.{function_call.name}",
                kind=SpanKind.CLIENT
            )
            tool_span = tool_span_context.__enter__()

            # Set TOOL span kind for Phoenix
            set_span_kind(tool_span, OpenInferenceSpanKind.TOOL)
            tool_span.set_attribute("tool.name", function_call.name)

            # Set tool arguments in multiple formats for Phoenix compatibility
            args_json = json.dumps(function_call.arguments, default=str)
            tool_span.set_attribute("tool.arguments", args_json)
            tool_span.set_attribute("input.value", args_json)  # Phoenix OpenInference convention
            tool_span.set_attribute("input.mime_type", "application/json")

        try:
            f = self._function_manager[function_call.name]
            if not f:
                message = f"attempting to load function {function_call.name} which is not activated - please activate it"
                data = MessageStackFormatter.format_function_response_error(
                    function_call, ValueError(message), self._context
                )
                # OTEL: Record tool error
                if tool_span:
                    tool_span.set_attribute("tool.error", message)
                    mark_span_as_error(tool_span, message)
            else:
                try:
                    """try call the function - assumes its some sort of json thing that comes back"""
                    data = f(**function_call.arguments) or {}
                    data = MessageStackFormatter.format_function_response_data(
                        function_call, data, self._context
                    )
                    # OTEL: Record tool success
                    if tool_span:
                        result_str = json.dumps(data, default=str)
                        tool_span.set_attribute("tool.result", result_str[:1000])  # Truncate for attribute
                        tool_span.set_attribute("output.value", result_str[:5000])  # Phoenix convention, larger limit
                        tool_span.set_attribute("output.mime_type", "application/json")

                    """if there is an error, how you format the message matters - some generic ones are added
                    its important to make sure the format coincides with the language model being used in context
                    """
                except TypeError as tex:  # type errors are usually the agents fault
                    logger.warning(f"Error calling function {traceback.format_exc()}")
                    data = MessageStackFormatter.format_function_response_type_error(
                        function_call, tex, self._context
                    )
                    # OTEL: Record tool error
                    if tool_span:
                        tool_span.set_attribute("tool.error", str(tex))
                        mark_span_as_error(tool_span, str(tex))
                except Exception as ex:  # general errors are usually our fault
                    logger.warning(f"Error calling function {traceback.format_exc()}")
                    data = MessageStackFormatter.format_function_response_error(
                        function_call, ex, self._context
                    )
                    # OTEL: Record tool error
                    if tool_span:
                        tool_span.set_attribute("tool.error", str(ex))
                        mark_span_as_error(tool_span, str(ex))
        finally:
            # Always close the tool span context manager
            if tool_span_context:
                tool_span_context.__exit__(None, None, None)

        # print(data) # maybe trace here
        """update messages with data if we can or add error messages to notify the language model"""
        self.messages.add(data)
        return data

    @property
    def functions(self) -> typing.Dict[str, Function]:
        """Provide access to the function manager's functions"""
        return self._function_manager.functions

    @property
    def function_descriptions(self) -> typing.List[dict]:
        """Provide function specs filtered by current user's role level"""
        role_level = self._context.role_level if self._context else None
        filtered_functions = self._function_manager.get_functions_for_role_level(
            role_level
        )
        return [f.function_spec for _, f in filtered_functions.items()]

    def _capture_span_ids_to_session_metadata(self, session_id: str) -> None:
        """
        Helper method to capture current span/trace IDs and store them in session metadata.
        This is used for linking Phoenix feedback annotations to traces.

        Args:
            session_id: The session ID to update with span metadata
        """
        if not is_tracing_enabled():
            logger.debug(f"OTEL not enabled, skipping span ID capture for session {session_id}")
            return

        try:
            from percolate.utils.otel_utils import (
                get_current_span_id_as_hex,
                get_current_trace_id_as_hex,
            )
            from percolate.models.p8 import Session
            import percolate as p8

            span_id = get_current_span_id_as_hex()
            trace_id = get_current_trace_id_as_hex()

            logger.info(f"Attempting to capture OTEL IDs for session {session_id}: span_id={span_id}, trace_id={trace_id}")

            if span_id and trace_id:
                # Update session metadata with span/trace IDs for feedback linking
                import json
                repo = p8.repository(Session, user_id=self.user_id)

                # Use parameterized query to prevent SQL injection
                sessions = repo.execute(
                    'SELECT metadata FROM p8."Session" WHERE id = %s',
                    (session_id,)
                )

                if sessions:
                    existing_metadata = sessions[0].get("metadata") or {}
                    existing_metadata["otel_span_id"] = span_id
                    existing_metadata["otel_trace_id"] = trace_id

                    # Serialize dict to JSON string for PostgreSQL JSONB column
                    metadata_json = json.dumps(existing_metadata)
                    repo.execute(
                        'UPDATE p8."Session" SET metadata = %s WHERE id = %s',
                        (metadata_json, session_id)
                    )
                    logger.info(f"✓ Stored span_id={span_id} and trace_id={trace_id} in session {session_id}")
                else:
                    logger.warning(f"Session {session_id} not found in database, cannot store OTEL IDs")
            else:
                logger.warning(f"Could not get span_id or trace_id for session {session_id}: span_id={span_id}, trace_id={trace_id}")
        except Exception as e:
            # Don't fail the request if metadata update fails
            logger.warning(f"Failed to capture span IDs to session metadata: {e}")
            import traceback
            logger.warning(traceback.format_exc())

    def __call__(
        self,
        question: str,
        context: CallingContext = None,
        limit: int = None,
        data: typing.List[dict] = None,
        language_model: str = None,
        audit: bool = False,
    ):
        """
        Ask a question to kick of the agent loop
        """
        return self.run(
            question,
            context,
            data=data,
            limit=limit,
            language_model=language_model,
            audit=audit,
        )

    def stream(
        self,
        question: str,
        context: CallingContext = None,
        limit: int = None,
        data: typing.List[dict] = None,
        language_model: str = None,
        audit: bool = True,
    ):
        """
        Stream the agentic loop as SSE events.  This method orchestrates successive
        LLM calls until no function calls remain.  It always yields SSE-formatted
        text chunks; upon detecting a function call it yields a placeholder event
        (e.g. "data: im performing function X"), invokes the function, updates the
        message stack, and continues streaming from the model.

        Args:
            question: The user question to begin the loop.
            context: Optional CallingContext; if omitted, a new streaming context is used.
            limit: Max number of agent iterations (function call loops).
            data: Initial data payload for the agent.
            language_model: Override the LLM model name.
            audit: If True, dump audit record after completion.

        Yields:
            str: SSE-formatted event strings (e.g. "data: ...\n\n").
        """

        from percolate.models import AIResponse, User

        if context:
            ctx = context.in_streaming_mode(model=language_model)
        else:
            ctx = CallingContext.with_model(language_model).in_streaming_mode()

        # Store the context
        self._context = ctx

        lm_client = LanguageModel.from_context(ctx)
        # The streaming generator will yield AIResponse objects for auditing directly

        # Get agent info for tracing
        agent_name = self.name
        agent_version = self.agent_model.metadata.get("version") if hasattr(self.agent_model, "metadata") else None

        def _generator():
            """the generator manages the agentic loop which in turn manage the streaming loops
            It yields content in the target format i.e. SSE/OpenAI but also sends the internal AIResponse which is not typically sent to the user
            The AIResponses are turns (tool calls + evals) which are used in the agentic loop but also audited (the main reason we yield them)
            This process could be simplified if we flush the AIResponse on another thread to not block the user and save them so that we dont need to collect
            An auditor singleton or repository singleton could just queue up entities and flush them on another thread

            We write events using a protocol event:
            """

            base_prompt = GENERIC_P8_PROMPT

            sys_prompt = (
                base_prompt if not ctx.plan else f"{base_prompt}\n\n{context.plan}"
            )
            # Initialize message stack as in run()
            payload = data if data is not None else self._init_data

            # Get functions filtered by role level
            available_functions = self._function_manager.get_functions_for_role_level(
                ctx.role_level if ctx is not None else None
            )

            self.messages = self.agent_model.build_message_stack(
                question=question,
                functions=list(available_functions.keys()),
                data=payload,
                system_prompt_preamble=sys_prompt,
                user_memory=ctx.get_user_memory(),
            )

            max_loops = limit or ctx.max_iterations
            last_ai_response = None
            saw_stop = False  # this is to kill the entire agent loop

            for iteration_num in range(max_loops):
                turn_content = ""
                saw_tool_call = False
                turn_usage = {}
                last_ai_response = None
                raw_response = lm_client._call_raw(
                    messages=self.messages,
                    functions=self.function_descriptions,
                    context=ctx,
                )

                """if we use non open ai models we have a choice where we want to adapt the deltas TBD
                in v0 ill probably make the contract openai adapter upstream but for example users may want to relay messages in another scheme
                there are essential three adaptations we need; function call aggregation needs to be buffered and does not need relay;
                token usage also needs to be adapted and does not need relay;
                the decisions is simply around if the raw content line should be sent in the open ai or other scheme - here its the raw 'line' that is relayed in one scheme or another
                """

                # Use unified stream adapter for all providers with function call events enabled
                adapter = UnifiedStreamAdapter(lm_client._scheme, "openai")
                for line, chunk in adapter.process_stream(
                    raw_response, emit_function_announcements=True
                ):

                    # ALWAYS yield the SSE line first for the client - this ensures all events are streamed
                    line_to_yield = (
                        line.decode("utf-8") if isinstance(line, bytes) else line
                    )
                    yield line_to_yield

                    # Handle special messages from the stream_utils for backward compatibility
                    if isinstance(chunk, dict) and (
                        chunk.get("status") or chunk.get("content")
                    ):
                        # Status messages are now commented out but this stays for backward compatibility
                        status_type = chunk.get("status")
                        if status_type == "flush":
                            # Already yielded the line above, just continue
                            continue

                        elif status_type == "function_call_started":
                            # Skip status messages - we're using content deltas instead
                            continue

                    # print(chunk)
                    choice = chunk["choices"][0] if chunk.get("choices") else {}

                    finish = choice.get("finish_reason")

                    # Handle tool call batch
                    if finish == "tool_calls":
                        # Tool-call turn: capture usage and mark
                        saw_tool_call = True
                        turn_usage = chunk.get("usage", {}) or {}

                        # Invoke each buffered function call and build aggregate response data
                        tool_call_evals = {}
                        for tc in choice["delta"].get("tool_calls", []):
                            """ADD the function call to the message stack in the correct scheme"""
                            fc = FunctionCall(
                                id=tc["id"], **tc["function"], scheme=lm_client._scheme
                            )
                            # We already sent "Preparing to call" message earlier, now send "executing" message
                            executing_msg = f"event: executing {fc.name}...\n\n"
                            yield executing_msg

                            # pair the tool call expectation with a response that will follow in the invoke
                            # note the SCHEME must be passed into FunctionCall above
                            self.messages.add(fc.to_assistant_message())

                            # Safely invoke the function, catching any exceptions that might occur -> add invocation in the right dialect
                            try:
                                tool_call_evals[fc.id] = self.invoke(fc)
                            except Exception as e:
                                logger.error(
                                    f"Error executing function {fc.name}: {str(e)}"
                                )
                                # Add error to the evaluations to avoid breaking the stream
                                tool_call_evals[fc.id] = {
                                    "error": f"Error executing function: {str(e)}"
                                }

                        last_ai_response = {
                            "tool_calls": choice["delta"].get("tool_calls", []),
                            "tool_eval_data": tool_call_evals,
                            "function_stack": self.functions.keys(),
                        }

                    # Stream content deltas
                    delta = choice.get("delta", {}) or {}
                    if "content" in delta:
                        piece = delta.get("content") or ""
                        # Send to any streaming callback
                        if context.streaming_callback:
                            context.streaming_callback(line)
                        # Accumulate content for this turn
                        turn_content += piece
                        # SSE line already yielded above - no need to yield again

                    """in this single request loop"""
                    if not saw_tool_call:
                        last_ai_response = {"content": turn_content}
                    if finish == "stop":
                        saw_stop = True
                    if turn_usage := chunk.get("usage"):
                        yield lm_client.parse_ai_response(
                            last_ai_response, turn_usage, ctx
                        )
                        # saw stop and usage is always last anyway
                """break out of the agentic loop"""
                if saw_stop:
                    break

        # Create the stream iterator
        stream_iterator = lm_client.get_stream_iterator(
            _generator, context=ctx, user_query=question, audit_on_flush=audit
        )

        # Wrap iterator with OTEL span if tracing is enabled
        if is_tracing_enabled():
            from percolate.services.llm.utils.stream_utils import LLMStreamIterator

            # Store original iter_lines method
            original_iter_lines = stream_iterator.iter_lines

            # Create traced version - manually manage span and activate context
            def traced_iter_lines():
                # Start span manually
                span = tracer.start_span(
                    name=f"agent.{agent_name}.stream",
                    kind=SpanKind.SERVER,
                )

                # Import context utilities to make this the active span
                from opentelemetry import context as otel_context
                from opentelemetry.trace import use_span

                # Activate the span context so child spans (LLM, tools) nest properly
                token = otel_context.attach(otel_context.set_value("current_span", span))

                try:
                    # Activate span as current so LLM and tool spans nest under it
                    # Use manual context management to keep span active while setting attributes
                    span_context = use_span(span, end_on_exit=False)
                    span_context.__enter__()

                    # Set OpenInference span kind for Phoenix
                    # TEMPORARY: Set to LLM to test if structured messages appear
                    set_span_kind(span, OpenInferenceSpanKind.LLM)
                    # set_span_kind(span, OpenInferenceSpanKind.AGENT)

                    # Capture OTEL span/trace IDs while span is active and store in context
                    # This allows audit_response_for_user to use them even after span ends
                    from percolate.utils.otel_utils import get_current_span_id_as_hex, get_current_trace_id_as_hex
                    span_id = get_current_span_id_as_hex()
                    trace_id = get_current_trace_id_as_hex()
                    if span_id and trace_id and ctx:
                        ctx.otel_span_id = span_id
                        ctx.otel_trace_id = trace_id
                        logger.info(f"Captured OTEL IDs to context: trace={trace_id}, span={span_id}")

                    # Set model attributes (but don't use set_llm_attributes as it sets span kind to LLM)
                    span.set_attribute("gen_ai.operation.name", "chat")
                    span.set_attribute("gen_ai.provider.name", lm_client._scheme)
                    span.set_attribute("gen_ai.request.model", ctx.model)
                    span.set_attribute("gen_ai.response.model", ctx.model)

                    # Set trace and session attributes
                    set_trace_attributes(
                        span,
                        user_id=ctx.user_id,
                        session_id=ctx.session_id,
                        code_path=__file__,
                        agent_version=agent_version,
                    )
                    span.set_attribute("gen_ai.is_streaming", True)
                    span.set_attribute("agent.name", agent_name)
                    span.set_attribute("agent.max_iterations", limit or ctx.max_iterations)

                    # Capture span IDs to session metadata for Phoenix feedback linking
                    if ctx and ctx.session_id:
                        self._capture_span_ids_to_session_metadata(str(ctx.session_id))

                    # Yield all items from the original iterator
                    # Child spans (LLM, tools) created during iteration will nest under this span
                    for item in original_iter_lines():
                        yield item

                    # After stream is consumed, capture usage AND messages for Phoenix
                    # Span is still active, so attributes can be set properly
                    try:
                        usage = stream_iterator.usage
                        completion = stream_iterator.content if hasattr(stream_iterator, 'content') else ""

                        # Build structured messages for OTEL
                        structured_messages = []
                        formatted_messages = []

                        # Get system prompt if available
                        system_prompt = self.agent_model.get_model_description() if hasattr(self.agent_model, 'get_model_description') else None
                        if system_prompt:
                            formatted_messages.append(f"[System]: {system_prompt}")
                            structured_messages.append({"role": "system", "content": system_prompt})

                        # Add user query
                        if question:
                            formatted_messages.append(f"[User]: {question}")
                            structured_messages.append({"role": "user", "content": question})

                        prompt_text = "\n\n".join(formatted_messages) if formatted_messages else question

                        if usage:
                            logger.debug(f"Setting OTEL attributes with {len(structured_messages)} messages")
                            set_generation_attributes(
                                span,
                                prompt=prompt_text,           # Formatted input messages
                                messages=structured_messages,  # Structured messages with roles
                                completion=completion,         # Accumulated output
                                input_tokens=usage.get("prompt_tokens", 0),
                                output_tokens=usage.get("completion_tokens", 0),
                                total_tokens=usage.get("total_tokens", 0),
                                is_streaming=True,
                                model=ctx.model  # For Phoenix cost calculation
                            )
                            logger.debug("OTEL attributes set successfully")
                    except Exception as e:
                        logger.error(f"Could not capture OTEL messages for streaming: {e}")
                        import traceback
                        traceback.print_exc()
                        pass  # Don't break on OTEL errors
                finally:
                    # Exit the span context if it was entered
                    if 'span_context' in locals():
                        span_context.__exit__(None, None, None)
                    # Always end the span and detach context
                    span.end()
                    otel_context.detach(token)

            # Replace iter_lines method with traced version
            stream_iterator.iter_lines = traced_iter_lines

        return stream_iterator

    def run(
        self,
        question: str,
        context: CallingContext = None,
        limit: int = None,
        data: typing.List[dict] = None,
        language_model: str = None,
        audit: bool = True,
    ):
        """Ask a question to kick of the agent loop

        Args:
            question: a user question
            context: a context object with information about users, session and usage
            limit: given that we iterate in the executor, we need to set a max length
            data: we can initialise the data payload as though there are function/data load results
        """

        """sometimes you may want to initialize your agent with a bunch of data"""
        data = data or self._init_data
        """setup all the bits before running the loop"""
        self._context = context or CallingContext.with_model(language_model)
        """a generic wrapper around the REST interfaces of any LLM client"""
        lm_client = LanguageModel.from_context(self._context)

        # Get agent info for tracing
        agent_name = self.name
        agent_version = self.agent_model.metadata.get("version") if hasattr(self.agent_model, "metadata") else None

        # Wrap execution in AGENT span if tracing enabled
        def _run_agent_loop():
            """messages are system prompt etc. agent model's can override how message stack is constructed
               we add p8 preamble in percolate - in future this could be disabled per model
            """

            # restrict for known user role - tools that requires an access level
            available_functions = self._function_manager.get_functions_for_role_level(
                context.role_level if context is not None else None
            )

            system_prompt = GENERIC_P8_PROMPT

            self.messages = self.agent_model.build_message_stack(
                question=question,
                functions=list(available_functions.keys()),
                data=data,
                system_prompt_preamble=system_prompt,
                user_memory=self._context.get_user_memory(),
            )

            """run the agent loop to completion"""
            for _ in range(limit or self._context.max_iterations):
                response = None
                """the language model may stream into a callback in the calling context"""
                response = lm_client(
                    messages=self.messages,
                    context=self._context,
                    functions=self.function_descriptions,
                )
                if function_calls := response.tool_calls:
                    """models need us to add the tool call to the stack - this is not the case for openai function call but for consistency over models we must"""
                    self.messages.add(response.verbatim)
                    """call one or more functions and update messages - functions can be updated inside this context"""
                    for (
                        func_call
                    ) in (
                        function_calls
                    ):  # its assumed to be only one for now but we could par do in future
                        self.invoke(FunctionCall(**func_call))
                    continue
                if response is not None:
                    # marks the fact that we have unfinished business
                    """for full auditing we should dump the response here"""
                    # p8.repository(AIResponse).update_records(response)
                    break

            """fire telemetry TODO and below dump to postgres"""
            if audit:
                p8.dump(
                    question,
                    self.messages.data,
                    response,
                    self._context,
                    agent=self.agent_model.get_model_full_name(),
                )

            return response.content

        # Execute with or without OTEL tracing
        if not is_tracing_enabled():
            return _run_agent_loop()

        # Create AGENT span with proper attributes
        with tracer.start_as_current_span(
            f"agent.{agent_name}.run",
            kind=SpanKind.SERVER
        ) as span:
            # Set OpenInference span kind for Phoenix
            set_span_kind(span, OpenInferenceSpanKind.AGENT)

            # Set agent and context attributes
            set_llm_attributes(span, self._context.model, lm_client._scheme)
            set_trace_attributes(
                span,
                user_id=self._context.user_id,
                session_id=self._context.session_id,
                code_path=__file__,
                agent_version=agent_version,
            )
            span.set_attribute("gen_ai.is_streaming", False)
            span.set_attribute("agent.name", agent_name)
            span.set_attribute("agent.max_iterations", limit or self._context.max_iterations)

            # Capture span IDs to session metadata for Phoenix feedback linking
            if self._context and self._context.session_id:
                self._capture_span_ids_to_session_metadata(str(self._context.session_id))

            return _run_agent_loop()
