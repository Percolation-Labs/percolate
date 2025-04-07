# The Chat interface

The Chat interface is a proxy for language models like OpenAI, Anthropic and Google. We need to write it wit

1. We will implement each dialect one at a time in streaming and non streaming mode. OpneAI is our default model. Streaming mode can use SSE or regular requests streaming based on a request parameter
2. The user can call ANY model in any dialect. For example it should be possible to use the OpenAI specification for completions to call the Anthropic model or to use Anthropics AI schema to call the Open AI or google model.
3. We should be careful about writing too much code at a time as these should be tested slowly one by one. We should also write unit tests with test payload for all the cases
4. There is some useful code in percolate.services.llm including a utils class where we import some streaming logic. The LanguageModel class shows some examples of code that converts different dialects to the Canonical OpenAI one.
5. in this chat API router, we have also started creating the models that we will use for each of these dialects - Pydantic allows us to validate and makes the code easier
6. The objective is to create a competions endpoint that can map between any dialect and call the underlying apis for the user
7. We will also run a finalizer in streaming and non streaming model to audit in the Percolate database but we will implement that later (to be filled in below)
8. We will expand the spec to add metadata as request params in the completions endpoint

- user_id
- session_id
- channel_id
- channel_type e.g slack
- api_provider defaults to null 
- use_sse 

## Auditing in Percolate
TODO: we will audit all requests to LLMs and user questions in sessions 