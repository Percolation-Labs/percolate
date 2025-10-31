"""
Example demonstrating web search with OpenTelemetry tracing enabled.

This example shows how to:
1. Enable OTEL tracing for the agent
2. Use allow_search in model_config to enable web search
3. Run an agent that performs web searches
4. Verify traces appear in Phoenix observability platform
"""

import os
import sys

# Add parent directory to path for local development
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Enable OTEL tracing before importing percolate
os.environ["OTEL_ENABLED"] = "true"
os.environ["OTEL_SERVICE_NAME"] = "web-search-demo"
os.environ["OTEL_EXPORTER_OTLP_ENDPOINT"] = "http://localhost:4317"

import percolate as p8
from percolate.models import AbstractModel


class WebSearchAgent(AbstractModel):
    """An AI agent that can search the web for current information"""

    model_config = {"allow_search": True}

    @classmethod
    def get_model_description(cls):
        return """You are a helpful research assistant with access to web search.
        When asked about current events, recent news, or information that changes frequently,
        use the search_the_web function to find accurate, up-to-date information.
        Always cite your sources by including the URLs from your search results."""


def main():
    """Run web search example with tracing"""

    print("=" * 60)
    print("Web Search with OpenTelemetry Tracing Example")
    print("=" * 60)
    print(f"\n📊 OTEL Tracing Enabled")
    print(f"   Service Name: {os.environ['OTEL_SERVICE_NAME']}")
    print(f"   OTLP Endpoint: {os.environ['OTEL_EXPORTER_OTLP_ENDPOINT']}")
    print(f"\n🔍 Creating WebSearchAgent with allow_search=True\n")

    # Create the agent
    agent = p8.Agent(WebSearchAgent)

    # Ask a question that requires web search
    query = "What are the latest developments in OpenAI's GPT models? Search the web and summarize the top 3 results."

    print(f"❓ Query: {query}\n")
    print("🤖 Agent Response:")
    print("-" * 60)

    # Run the agent (this will create traces)
    response = agent.run(query)

    print(response)
    print("-" * 60)

    print(f"\n✅ Query completed!")
    print(f"\n📈 Traces sent to OTLP collector at {os.environ['OTEL_EXPORTER_OTLP_ENDPOINT']}")
    print(f"\n🔎 To view traces in Phoenix:")
    print(f"   1. Port forward Phoenix UI: kubectl port-forward -n observability svc/phoenix 6006:6006")
    print(f"   2. Open browser: http://localhost:6006")
    print(f"   3. Look for service: {os.environ['OTEL_SERVICE_NAME']}")
    print(f"\n💾 Or query PostgreSQL directly:")
    print(f"   kubectl exec -n p8 percolate-1 -- psql -U postgres -d app -c \\")
    print(f'     "SELECT name, attributes::text FROM phoenix.spans WHERE attributes @> \'{{"service":{{"name":"{os.environ["OTEL_SERVICE_NAME"]}"}}}}\' ORDER BY start_time DESC LIMIT 1;"')


if __name__ == "__main__":
    main()
