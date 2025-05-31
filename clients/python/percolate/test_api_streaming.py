#!/usr/bin/env python3
"""
Test script to verify API streaming endpoints and OpenWebUI compatibility.

Tests:
1. Chat completions endpoint (/chat/completions)
2. Agent completions endpoint (/agent/{agent_name}/completions)
3. Verifies proper handling of streaming, including [DONE] markers and headers
"""

import os
import json
import time
import logging
import requests
import argparse
from datetime import datetime

# Set the PostgreSQL port to 5432 as specified
os.environ['P8_PG_PORT'] = '5432'

# Enable verbose logging
logging.basicConfig(level=logging.DEBUG, 
                   format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

class APITest:
    """Base class for API testing"""
    
    def __init__(self, base_url="http://localhost:5000", token=None):
        """Initialize with base URL and token"""
        self.base_url = base_url
        self.token = token or os.environ.get('P8_TEST_BEARER_TOKEN')
        
        if not self.token:
            logger.warning("No token provided! Using 'postgres' as fallback token")
            self.token = "postgres"
    
    def _get_headers(self):
        """Get headers with auth token and user email"""
        return {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {self.token}",
            "X-OpenWebUI-User-Email": "sirsh@resonance.nyc"  # Add the user email header
        }
    
    def check_headers(self, response):
        """Check if response contains required streaming headers"""
        essential_headers = {
            'Content-Type': 'text/event-stream',
            'Cache-Control': 'no-cache',
            'Connection': 'keep-alive',
            'X-Accel-Buffering': 'no'
        }
        
        issues = []
        for header, expected_value in essential_headers.items():
            header_lower = header.lower()
            if header_lower in response.headers:
                value = response.headers[header_lower]
                if expected_value in value:
                    logger.info(f"✓ {header}: {value}")
                else:
                    logger.warning(f"✗ {header}: Expected '{expected_value}', got '{value}'")
                    issues.append(f"Wrong {header} value: {value}")
            else:
                logger.warning(f"✗ Missing header: {header}")
                issues.append(f"Missing header: {header}")
        
        return issues

    def process_stream(self, response):
        """Process a streaming response and check for completeness markers"""
        start_time = datetime.now()
        content = ""
        status_seen = False
        done_marker_seen = False
        finish_reason_seen = False
        tool_calls_seen = False
        usage_data_seen = False
        
        # Process the stream
        for line in response.iter_lines(decode_unicode=True):
            if not line or not line.startswith("data: "):
                continue
            
            raw_data = line[6:].strip()
            current_time = datetime.now()
            elapsed = (current_time - start_time).total_seconds()
            
            if raw_data == "[DONE]":
                logger.info(f"[DONE] marker received at +{elapsed:.2f}s")
                done_marker_seen = True
                break
            
            try:
                data = json.loads(raw_data)
                
                # Check for status message
                if "event" in data and data["event"] == "status":
                    logger.info(f"Status message: {data['message']}")
                    status_seen = True
                    continue
                
                # Extract content
                if "choices" in data and data["choices"]:
                    choice = data["choices"][0]
                    delta = choice.get("delta", {})
                    
                    if "content" in delta:
                        content_chunk = delta["content"]
                        content += content_chunk
                        # Print just a portion for debug
                        if len(content_chunk) > 50:
                            logger.debug(f"Content chunk: {content_chunk[:50]}...")
                        else:
                            logger.debug(f"Content chunk: {content_chunk}")
                    
                    # Check for tool calls
                    if "tool_calls" in delta:
                        tool_calls_seen = True
                        logger.info(f"Tool calls seen at +{elapsed:.2f}s")
                    
                    # Record when we see finish_reason
                    finish_reason = choice.get("finish_reason")
                    if finish_reason:
                        logger.info(f"Finish reason '{finish_reason}' received at +{elapsed:.2f}s")
                        finish_reason_seen = True
                
                # Log usage data
                if "usage" in data:
                    usage_data_seen = True
                    logger.info(f"Usage data received at +{elapsed:.2f}s: {data['usage']}")
                    
            except json.JSONDecodeError:
                logger.warning(f"Failed to parse: {raw_data}")
        
        # Record timing information
        end_time = datetime.now()
        total_time = (end_time - start_time).total_seconds()
        
        if not done_marker_seen:
            logger.warning(f"No [DONE] marker received after {total_time:.2f}s")
        
        results = {
            "content_length": len(content),
            "status_seen": status_seen,
            "finish_reason_seen": finish_reason_seen,
            "tool_calls_seen": tool_calls_seen,
            "usage_data_seen": usage_data_seen,
            "done_marker_seen": done_marker_seen,
            "total_time": total_time,
        }
        
        logger.info(f"Stream processing complete in {total_time:.2f}s")
        return results, content

    def check_stream_completion(self, results):
        """Check if stream completed properly"""
        issues = []
        
        if not results["done_marker_seen"]:
            issues.append("Missing [DONE] marker - will cause OpenWebUI to hang")
        
        if not results["finish_reason_seen"]:
            issues.append("Missing finish_reason signal - indicates incomplete response")
        
        return issues


class ChatCompletionsTest(APITest):
    """Test the /chat/completions endpoint"""
    
    def run_test(self, model="gpt-4.1-mini", with_tools=False, with_images=False):
        """Run a test of the chat completions endpoint"""
        logger.info(f"Testing /chat/completions with model {model}")
        
        # Base request
        request_data = {
            "model": model,
            "messages": [
                {"role": "user", "content": "Write a short paragraph about API streaming."}
            ],
            "stream": True
        }
        
        # Add tools if requested
        if with_tools:
            request_data["tools"] = [
                {
                    "type": "function",
                    "function": {
                        "name": "get_weather",
                        "description": "Get the current weather in a given location",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "location": {
                                    "type": "string",
                                    "description": "The city and state, e.g. San Francisco, CA"
                                }
                            },
                            "required": ["location"]
                        }
                    }
                }
            ]
            # Update the prompt to encourage tool use
            request_data["messages"] = [
                {"role": "user", "content": "What's the weather like in Paris today?"}
            ]
        
        # Add images if requested (for multimodal models)
        if with_images:
            # Use a text-only prompt since we don't have actual images
            request_data["messages"] = [
                {"role": "user", "content": "Describe how API streaming works in detail."}
            ]
        
        url = f"{self.base_url}/chat/completions"
        start_time = datetime.now()
        
        try:
            # Make the request
            response = requests.post(
                url,
                headers=self._get_headers(),
                json=request_data,
                stream=True,
                timeout=60
            )
            
            if response.status_code != 200:
                logger.error(f"Error: Received status code {response.status_code}")
                logger.error(f"Response: {response.text}")
                return False, {
                    "status_code": response.status_code,
                    "error": response.text,
                    "endpoint": url
                }
            
            # Check headers
            header_issues = self.check_headers(response)
            
            # Process the stream
            results, content = self.process_stream(response)
            
            # Check for issues
            stream_issues = self.check_stream_completion(results)
            
            # Collect all issues
            all_issues = header_issues + stream_issues
            
            return len(all_issues) == 0, {
                "success": len(all_issues) == 0,
                "content": content[:100] + "..." if len(content) > 100 else content,
                "issues": all_issues,
                "details": results
            }
            
        except requests.exceptions.Timeout:
            logger.error("Request timed out")
            return False, {"error": "Request timed out", "endpoint": url}
        except Exception as e:
            logger.error(f"Error during test: {str(e)}")
            return False, {"error": str(e), "endpoint": url}


class AgentCompletionsTest(APITest):
    """Test the /v1/agents/{agent_name}/chat/completions endpoint"""
    
    def run_test(self, agent_name="default", model="gpt-4.1-mini"):
        """Run a test of the agent completions endpoint"""
        logger.info(f"Testing /v1/agents/{agent_name}/chat/completions with model {model}")
        
        # Request data
        request_data = {
            "model": model,
            "messages": [
                {"role": "user", "content": "Explain how API streaming works."}
            ],
            "stream": True
        }
        
        url = f"{self.base_url}/v1/agents/{agent_name}/chat/completions"
        
        try:
            # Make the request
            response = requests.post(
                url,
                headers=self._get_headers(),
                json=request_data,
                stream=True,
                timeout=60
            )
            
            if response.status_code != 200:
                logger.error(f"Error: Received status code {response.status_code}")
                logger.error(f"Response: {response.text}")
                return False, {
                    "status_code": response.status_code,
                    "error": response.text,
                    "endpoint": url
                }
            
            # Check headers
            header_issues = self.check_headers(response)
            
            # Process the stream
            results, content = self.process_stream(response)
            
            # Check for issues
            stream_issues = self.check_stream_completion(results)
            
            # Collect all issues
            all_issues = header_issues + stream_issues
            
            return len(all_issues) == 0, {
                "success": len(all_issues) == 0,
                "content": content[:100] + "..." if len(content) > 100 else content,
                "issues": all_issues,
                "details": results
            }
            
        except requests.exceptions.Timeout:
            logger.error("Request timed out")
            return False, {"error": "Request timed out", "endpoint": url}
        except Exception as e:
            logger.error(f"Error during test: {str(e)}")
            return False, {"error": str(e), "endpoint": url}


def run_all_tests(base_url, token, models=None):
    """Run all tests and summarize results"""
    # Default models to test
    if not models:
        models = ["gpt-4.1-mini"]
    
    results = {
        "chat_completions": {},
        "agent_completions": {}
    }
    
    # Test chat completions with each model
    chat_test = ChatCompletionsTest(base_url, token)
    for model in models:
        logger.info(f"\n=== TESTING CHAT COMPLETIONS WITH {model} ===")
        success, details = chat_test.run_test(model)
        results["chat_completions"][model] = {
            "success": success,
            "details": details
        }
    
    # Test agent completions
    agent_test = AgentCompletionsTest(base_url, token)
    logger.info(f"\n=== TESTING AGENT COMPLETIONS WITH default agent ===")
    success, details = agent_test.run_test("default", models[0])
    results["agent_completions"]["default"] = {
        "success": success,
        "details": details
    }
    
    # Print summary
    logger.info("\n=== TEST SUMMARY ===")
    
    all_success = True
    for category, tests in results.items():
        logger.info(f"\n{category.upper()}:")
        for test_name, test_result in tests.items():
            success = test_result["success"]
            all_success = all_success and success
            status = "✓ PASS" if success else "✗ FAIL"
            logger.info(f"{status} - {test_name}")
            
            if not success:
                issues = test_result["details"].get("issues", [])
                for issue in issues:
                    logger.info(f"  - {issue}")
    
    return all_success, results


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Test API streaming endpoints")
    parser.add_argument("--url", default="http://localhost:5000", help="Base URL for the API")
    parser.add_argument("--token", default=None, help="Bearer token for authentication")
    parser.add_argument("--models", nargs="+", default=["gpt-4.1-mini"], help="Models to test")
    
    args = parser.parse_args()
    success, results = run_all_tests(args.url, args.token, args.models)
    
    if not success:
        exit(1)