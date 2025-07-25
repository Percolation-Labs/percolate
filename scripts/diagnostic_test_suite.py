#!/usr/bin/env python3
"""
Comprehensive Percolate Diagnostic Test Suite.
This script tests all major functions, models, and capabilities systematically.
It serves as both an integration test and diagnostic tool.
"""

import os
import sys
import json
import time
import subprocess
import psycopg2
from pathlib import Path
from datetime import datetime
import argparse
from typing import Dict, List, Any, Optional
import traceback


class PercolateDiagnostics:
    def __init__(self, db_config=None):
        self.db_config = db_config or {
            'host': 'localhost',
            'port': 5438,
            'database': 'app',
            'user': 'postgres',
            'password': 'postgres'
        }
        self.test_results = []
        self.connection = None
        
        # Function categories from our comprehensive inventory
        self.function_categories = {
            'core': [
                'public.percolate',
                'public.percolate_with_agent', 
                'public.plan',
                'public.run'
            ],
            'entities': [
                'p8.get_entities',
                'p8.register_entities',
                'p8.query_entity',
                'p8.vector_search_entity',
                'p8.get_entity_ids_by_description',
                'p8.generate_markdown_prompt'
            ],
            'cypher': [
                'p8.add_relationship_to_node',
                'p8.get_connected_entities',
                'p8.get_paths',
                'p8.get_relationships',
                'public.cypher_query'
            ],
            'search': [
                'p8.deep_search',
                'p8.fuzzy_match_node_key',
                'p8.parallel_search',
                'p8.merge_search_results'
            ],
            'indexing': [
                'p8.build_graph_index',
                'p8.get_embedding_for_text',
                'p8.insert_entity_embeddings',
                'p8.generate_and_fetch_embeddings'
            ],
            'requests': [
                'p8.ask',
                'p8.get_canonical_messages',
                'p8.nl2sql',
                'p8.request_openai',
                'p8.request_anthropic',
                'p8.request_google'
            ],
            'tools': [
                'p8.get_tools_by_name',
                'p8.eval_function_call',
                'p8.activate_functions_by_name',
                'p8.get_session_functions'
            ],
            'utils': [
                'p8.create_session',
                'p8.ping_api'
            ]
        }
        
        # Expected model tables based on actual installation
        self.model_tables = [
            'p8."Agent"',
            'p8."Function"',
            'p8."Session"',
            'p8."AIResponse"', 
            'p8."LanguageModelApi"',
            'p8."ModelField"',
            'p8."User"',
            'p8."ApiProxy"',
            'p8."Resources"',
            'p8."Task"',
            'p8."Project"',
            'p8."Settings"',
            'p8."Audit"'
        ]
        
    def log_test(self, category: str, test_name: str, success: bool, 
                 message: str = "", details: Dict[str, Any] = None, 
                 execution_time: float = None):
        """Log test results with detailed information."""
        status = "✅ PASS" if success else "❌ FAIL"
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        
        result = {
            'timestamp': timestamp,
            'category': category,
            'test': test_name,
            'success': success,
            'message': message,
            'details': details or {},
            'execution_time': execution_time
        }
        
        self.test_results.append(result)
        time_str = f" ({execution_time:.3f}s)" if execution_time else ""
        print(f"{status} [{category}] {test_name}: {message}{time_str}")
        
        if details and not success:
            for key, value in details.items():
                print(f"    {key}: {value}")
    
    def get_connection(self):
        """Get database connection."""
        if self.connection is None or self.connection.closed:
            try:
                self.connection = psycopg2.connect(**self.db_config)
                self.connection.autocommit = True
            except Exception as e:
                print(f"❌ Failed to connect to database: {e}")
                raise
        return self.connection
    
    def execute_query(self, query: str, params: tuple = None, fetch_one: bool = False, 
                     fetch_all: bool = True) -> Any:
        """Execute a query and return results."""
        conn = self.get_connection()
        cursor = conn.cursor()
        
        try:
            cursor.execute(query, params)
            
            if fetch_one:
                return cursor.fetchone()
            elif fetch_all:
                return cursor.fetchall()
            else:
                return cursor.rowcount
        finally:
            cursor.close()
    
    def test_database_connectivity(self):
        """Test basic database connectivity and info."""
        start_time = time.time()
        
        try:
            conn = self.get_connection()
            
            # Test basic connection
            result = self.execute_query("SELECT version(), current_database(), current_user")
            version, database, user = result[0]
            
            execution_time = time.time() - start_time
            self.log_test("database", "connectivity", True, 
                         f"Connected as {user} to {database}", 
                         {'version': version}, execution_time)
            return True
            
        except Exception as e:
            execution_time = time.time() - start_time
            self.log_test("database", "connectivity", False, 
                         "Database connection failed", 
                         {'error': str(e)}, execution_time)
            return False
    
    def test_extensions(self):
        """Test that required PostgreSQL extensions are installed."""
        start_time = time.time()
        
        required_extensions = ['age', 'http', 'vector', 'pg_trgm']
        
        try:
            result = self.execute_query("""
                SELECT extname, extversion FROM pg_extension 
                WHERE extname = ANY(%s)
            """, (required_extensions,))
            
            installed = {row[0]: row[1] for row in result}
            missing = [ext for ext in required_extensions if ext not in installed]
            
            execution_time = time.time() - start_time
            
            if not missing:
                self.log_test("database", "extensions", True, 
                             f"All {len(installed)} extensions installed", 
                             {'extensions': installed}, execution_time)
                return True
            else:
                self.log_test("database", "extensions", False, 
                             f"Missing extensions: {', '.join(missing)}", 
                             {'installed': installed, 'missing': missing}, execution_time)
                return False
                
        except Exception as e:
            execution_time = time.time() - start_time
            self.log_test("database", "extensions", False, 
                         "Extension check failed", 
                         {'error': str(e)}, execution_time)
            return False
    
    def test_finalize_script_execution(self):
        """CRITICAL TEST: Verify that 10_finalize.sql ran during initialization."""
        start_time = time.time()
        
        try:
            # Check for P8_API_KEY in Settings table (created by finalize script)
            result = self.execute_query("""
                SELECT value, created_at 
                FROM p8."Settings" 
                WHERE key = 'P8_API_KEY'
            """)
            
            if result:
                api_key, created_at = result[0]
                
                # Check for ApiProxy entry (also created by finalize)
                proxy_result = self.execute_query("""
                    SELECT name, proxy_uri, token 
                    FROM p8."ApiProxy" 
                    WHERE name = 'percolate'
                """)
                
                # Check if AGE is preloaded (configured by finalize)
                age_result = self.execute_query("SHOW session_preload_libraries")
                session_libs = age_result[0][0] if age_result else ''
                
                execution_time = time.time() - start_time
                
                if proxy_result and 'age' in session_libs:
                    self.log_test("initialization", "finalize_script", True,
                                 "10_finalize.sql executed successfully", 
                                 {
                                     'api_key_created': created_at.isoformat() if created_at else 'unknown',
                                     'api_proxy_configured': bool(proxy_result),
                                     'age_preloaded': 'age' in session_libs,
                                     'session_preload_libraries': session_libs
                                 }, execution_time)
                    return True
                else:
                    issues = []
                    if not proxy_result:
                        issues.append("ApiProxy not configured")
                    if 'age' not in session_libs:
                        issues.append("AGE not preloaded")
                        
                    self.log_test("initialization", "finalize_script", False,
                                 f"10_finalize.sql partially executed: {', '.join(issues)}", 
                                 {
                                     'api_key_exists': True,
                                     'api_proxy_configured': bool(proxy_result),
                                     'age_preloaded': 'age' in session_libs,
                                     'session_preload_libraries': session_libs
                                 }, execution_time)
                    return False
            else:
                # No API key means finalize didn't run at all
                self.log_test("initialization", "finalize_script", False,
                             "10_finalize.sql DID NOT RUN - P8_API_KEY not found", 
                             {'critical_failure': 'Database initialization incomplete'}, 
                             execution_time)
                return False
                
        except Exception as e:
            execution_time = time.time() - start_time
            self.log_test("initialization", "finalize_script", False,
                         f"Failed to check finalize execution: {str(e)}", 
                         {'error': str(e)}, execution_time)
            return False
    
    def test_model_tables(self):
        """Test that all expected model tables exist."""
        start_time = time.time()
        
        existing_tables = []
        missing_tables = []
        table_info = {}
        
        try:
            for table in self.model_tables:
                if '"' in table:
                    schema, table_name = table.split('."')
                    schema = schema.replace('"', '')
                    table_name = table_name.replace('"', '')
                else:
                    schema, table_name = table.split('.')
                
                # Check if table exists
                result = self.execute_query("""
                    SELECT EXISTS (
                        SELECT 1 FROM information_schema.tables 
                        WHERE table_schema = %s AND table_name = %s
                    )
                """, (schema, table_name), fetch_one=True)
                
                if result[0]:
                    existing_tables.append(table)
                    
                    # Get table info
                    count_result = self.execute_query(f'SELECT COUNT(*) FROM {table}', fetch_one=True)
                    table_info[table] = {'row_count': count_result[0]}
                else:
                    missing_tables.append(table)
            
            execution_time = time.time() - start_time
            
            if not missing_tables:
                self.log_test("schema", "model_tables", True, 
                             f"All {len(existing_tables)} model tables exist", 
                             {'tables': table_info}, execution_time)
                return True
            else:
                self.log_test("schema", "model_tables", False, 
                             f"Missing {len(missing_tables)} tables", 
                             {'existing': existing_tables, 'missing': missing_tables}, 
                             execution_time)
                return False
                
        except Exception as e:
            execution_time = time.time() - start_time
            self.log_test("schema", "model_tables", False, 
                         "Model table check failed", 
                         {'error': str(e)}, execution_time)
            return False
    
    def test_function_category(self, category: str, functions: List[str]):
        """Test a category of functions."""
        print(f"\n🔧 Testing {category} functions...")
        
        category_results = {'total': len(functions), 'passed': 0, 'failed': 0}
        
        for func_name in functions:
            start_time = time.time()
            
            try:
                # Check if function exists
                if '.' in func_name:
                    schema, function = func_name.split('.', 1)
                    if schema == 'public':
                        query = """
                            SELECT proname, pronargs FROM pg_proc p
                            WHERE p.proname = %s
                        """
                        params = (function,)
                    else:
                        query = """
                            SELECT proname, pronargs FROM pg_proc p
                            JOIN pg_namespace n ON p.pronamespace = n.oid
                            WHERE n.nspname = %s AND p.proname = %s
                        """
                        params = (schema, function)
                else:
                    query = """
                        SELECT proname, pronargs FROM pg_proc p
                        WHERE p.proname = %s
                    """
                    params = (func_name,)
                
                result = self.execute_query(query, params)
                
                execution_time = time.time() - start_time
                
                if result:
                    self.log_test(category, func_name, True, 
                                 f"Function exists ({result[0][1]} args)", 
                                 {}, execution_time)
                    category_results['passed'] += 1
                    
                    # Try to get function signature for important functions
                    if func_name in ['public.percolate', 'p8.ask', 'p8.get_entities']:
                        self._test_function_signature(func_name, category)
                        
                else:
                    self.log_test(category, func_name, False, 
                                 "Function does not exist", 
                                 {}, execution_time)
                    category_results['failed'] += 1
                    
            except Exception as e:
                execution_time = time.time() - start_time
                self.log_test(category, func_name, False, 
                             "Function check failed", 
                             {'error': str(e)}, execution_time)
                category_results['failed'] += 1
        
        return category_results
    
    def _test_function_signature(self, func_name: str, category: str):
        """Test function signature for key functions."""
        try:
            if '.' in func_name:
                schema, function = func_name.split('.', 1)
                if schema == 'public':
                    query = """
                        SELECT pg_get_function_arguments(p.oid) as args,
                               pg_get_function_result(p.oid) as result
                        FROM pg_proc p
                        WHERE p.proname = %s
                        LIMIT 1
                    """
                    params = (function,)
                else:
                    query = """
                        SELECT pg_get_function_arguments(p.oid) as args,
                               pg_get_function_result(p.oid) as result
                        FROM pg_proc p
                        JOIN pg_namespace n ON p.pronamespace = n.oid
                        WHERE n.nspname = %s AND p.proname = %s
                        LIMIT 1
                    """
                    params = (schema, function)
            
            result = self.execute_query(query, params, fetch_one=True)
            if result:
                args, return_type = result
                self.log_test(category, f"{func_name}_signature", True,
                             f"Signature verified",
                             {'args': args, 'returns': return_type})
            
        except Exception as e:
            self.log_test(category, f"{func_name}_signature", False,
                         "Signature check failed",
                         {'error': str(e)})
    
    def test_simple_function_execution(self):
        """Test execution of simple functions with safe parameters."""
        print(f"\n🏃 Testing function execution...")
        
        simple_tests = [
            {
                'name': 'version_check',
                'query': 'SELECT version()',
                'expected_type': str
            },
            {
                'name': 'current_time',
                'query': 'SELECT NOW()',
                'expected_type': 'datetime'
            }
        ]
        
        # If percolate functions exist, test them with minimal parameters
        try:
            # Test session creation if the function exists
            result = self.execute_query("""
                SELECT EXISTS (
                    SELECT 1 FROM pg_proc p
                    JOIN pg_namespace n ON p.pronamespace = n.oid
                    WHERE n.nspname = 'p8' AND p.proname = 'create_session'
                )
            """, fetch_one=True)
            
            if result[0]:
                simple_tests.append({
                    'name': 'p8_create_session',
                    'query': "SELECT p8.create_session(NULL, 'test', 'test')",
                    'expected_type': 'uuid'
                })
                
        except Exception:
            pass
        
        results = {'passed': 0, 'failed': 0}
        
        for test in simple_tests:
            start_time = time.time()
            try:
                result = self.execute_query(test['query'], fetch_one=True)
                execution_time = time.time() - start_time
                
                if result:
                    self.log_test("execution", test['name'], True,
                                 f"Executed successfully",
                                 {'result_type': type(result[0]).__name__}, 
                                 execution_time)
                    results['passed'] += 1
                else:
                    self.log_test("execution", test['name'], False,
                                 "No result returned", {}, execution_time)
                    results['failed'] += 1
                    
            except Exception as e:
                execution_time = time.time() - start_time
                self.log_test("execution", test['name'], False,
                             "Execution failed",
                             {'error': str(e)}, execution_time)
                results['failed'] += 1
        
        return results
    
    def test_graph_functionality(self):
        """Test Apache AGE graph functionality."""
        print(f"\n🕸️ Testing graph functionality...")
        
        start_time = time.time()
        
        try:
            # AGE extension is preloaded at session level, just set search path
            try:
                self.execute_query("SET search_path = ag_catalog, '$user', public", fetch_one=False, fetch_all=False)
                # Test if AGE is working by counting nodes
                node_count = self.execute_query("SELECT * FROM cypher('percolate', $$ MATCH (n) RETURN count(n) $$) as (count agtype)", fetch_all=True)
                execution_time = time.time() - start_time
                if node_count and len(node_count) > 0:
                    node_count_value = node_count[0][0] if isinstance(node_count[0], tuple) else node_count[0]
                    self.log_test("graph", "age_loading", True,
                                 f"AGE extension working correctly ({node_count_value} nodes)",
                                 {'node_count': node_count_value}, execution_time)
                else:
                    self.log_test("graph", "age_loading", False,
                                 "AGE query returned no results",
                                 {'result': node_count}, execution_time)
                    return False
            except Exception as e:
                execution_time = time.time() - start_time
                self.log_test("graph", "age_loading", False,
                             "Failed to load AGE extension",
                             {'error': str(e)}, execution_time)
                return False
            
            # Test cypher function
            cypher_test = self.execute_query("""
                SELECT EXISTS (
                    SELECT 1 FROM pg_proc p
                    WHERE p.proname = 'cypher'
                )
            """, fetch_one=True)
            
            execution_time = time.time() - start_time
            
            if cypher_test[0]:
                self.log_test("graph", "cypher_function", True,
                             "Cypher function available", {}, execution_time)
                
                # Test get_entities function with empty array
                start_time = time.time()
                try:
                    result = self.execute_query("SELECT p8.get_entities(ARRAY[]::text[]) as entities", fetch_one=True)
                    execution_time = time.time() - start_time
                    self.log_test("graph", "get_entities_empty", True,
                                 "get_entities function works with empty array", {}, execution_time)
                except Exception as e:
                    execution_time = time.time() - start_time
                    self.log_test("graph", "get_entities_empty", False,
                                 "get_entities function failed",
                                 {'error': str(e)}, execution_time)
                
                # Test get_entities with Agent search
                start_time = time.time()
                try:
                    result = self.execute_query("SELECT p8.get_entities(ARRAY['p8.Agent']) as entities", fetch_one=True)
                    execution_time = time.time() - start_time
                    self.log_test("graph", "get_entities_agent", True,
                                 "get_entities works with p8.Agent search", {}, execution_time)
                except Exception as e:
                    execution_time = time.time() - start_time
                    self.log_test("graph", "get_entities_agent", False,
                                 "get_entities failed with p8.Agent search",
                                 {'error': str(e)}, execution_time)
                
                # Test get_fuzzy_entities function
                start_time = time.time()
                try:
                    result = self.execute_query("SELECT p8.get_fuzzy_entities(ARRAY['agent']) as entities", fetch_one=True)
                    execution_time = time.time() - start_time
                    self.log_test("graph", "get_fuzzy_entities", True,
                                 "get_fuzzy_entities works with agent search", {}, execution_time)
                except Exception as e:
                    execution_time = time.time() - start_time
                    self.log_test("graph", "get_fuzzy_entities", False,
                                 "get_fuzzy_entities failed",
                                 {'error': str(e)}, execution_time)
                
                return True
            else:
                self.log_test("graph", "cypher_function", False,
                             "Cypher function missing", {}, execution_time)
                return False
                
        except Exception as e:
            execution_time = time.time() - start_time
            self.log_test("graph", "cypher_function", False,
                         "Graph functionality test failed",
                         {'error': str(e)}, execution_time)
            return False
    
    def test_api_connectivity(self):
        """Test internal API service connectivity and authentication."""
        print(f"\n🔗 Testing API connectivity and authentication...")
        
        # First test basic health check
        start_time = time.time()
        health_ok = False
        
        try:
            # Test health endpoint (no auth)
            result = self.execute_query("SELECT p8.ping_service('percolate-api', FALSE) as ping_result", fetch_one=True)
            execution_time = time.time() - start_time
            
            ping_result = result[0]
            if ping_result.get('status') == 'up':
                self.log_test("api", "health_check", True,
                             "API health endpoint is accessible", 
                             {'response': ping_result}, execution_time)
                health_ok = True
            else:
                self.log_test("api", "health_check", False,
                             "API health endpoint is down", 
                             {'response': ping_result}, execution_time)
                
        except Exception as e:
            execution_time = time.time() - start_time
            self.log_test("api", "health_check", False,
                         "Health check failed",
                         {'error': str(e)}, execution_time)
        
        # Now test authentication with database token
        start_time = time.time()
        auth_ok = False
        
        try:
            # Test auth endpoint with database token
            result = self.execute_query("SELECT p8.ping_service('percolate-api', TRUE) as auth_result", fetch_one=True)
            execution_time = time.time() - start_time
            
            auth_result = result[0]
            
            if auth_result.get('auth_status') == 'authorized':
                self.log_test("api", "auth_test", True,
                             "API authentication with database token successful", 
                             {'auth_result': auth_result}, execution_time)
                auth_ok = True
            elif auth_result.get('status') == 'error' and 'No API token' in auth_result.get('error', ''):
                self.log_test("api", "auth_test", False,
                             "CRITICAL: No API token in database - finalize script may not have run", 
                             {'auth_result': auth_result}, execution_time)
            elif auth_result.get('auth_status') == 'unauthorized':
                self.log_test("api", "auth_test", False,
                             "API rejected database token - token mismatch", 
                             {'auth_result': auth_result}, execution_time)
            else:
                self.log_test("api", "auth_test", False,
                             "API authentication test failed", 
                             {'auth_result': auth_result}, execution_time)
                
        except Exception as e:
            execution_time = time.time() - start_time
            self.log_test("api", "auth_test", False,
                         "Authentication test error",
                         {'error': str(e)}, execution_time)
        
        return health_ok and auth_ok
    
    def test_ai_functionality(self):
        """Test AI query functionality."""
        print(f"\n🤖 Testing AI functionality...")
        
        start_time = time.time()
        
        try:
            # Test basic percolate query
            result = self.execute_query("SELECT message_response FROM percolate('What is 2 + 2?') LIMIT 1", fetch_one=True)
            execution_time = time.time() - start_time
            
            if result and result[0]:
                response = result[0]
                self.log_test("ai", "percolate_query", True,
                             "AI query executed successfully", 
                             {'response_length': len(response)}, execution_time)
                
                # Test if response contains expected content
                if any(num in response.lower() for num in ['4', 'four']):
                    self.log_test("ai", "percolate_math", True,
                                 "AI correctly answered math question", 
                                 {'response': response[:100]}, execution_time)
                else:
                    self.log_test("ai", "percolate_math", False,
                                 "AI response seems incorrect", 
                                 {'response': response[:100]}, execution_time)
                
                return True
            else:
                self.log_test("ai", "percolate_query", False,
                             "AI query returned no response", {}, execution_time)
                return False
                
        except Exception as e:
            execution_time = time.time() - start_time
            self.log_test("ai", "percolate_query", False,
                         "AI query test failed",
                         {'error': str(e)}, execution_time)
            return False
    
    def test_language_model_apis(self):
        """Test language model API configuration."""
        print(f"\n🤖 Testing language model APIs...")
        
        start_time = time.time()
        
        try:
            # Check if LanguageModelApi table exists and has data
            result = self.execute_query('SELECT name, scheme, model FROM p8."LanguageModelApi"')
            execution_time = time.time() - start_time
            
            if result:
                apis = {row[0]: {'scheme': row[1], 'model': row[2]} for row in result}
                self.log_test("apis", "language_model_config", True,
                             f"Found {len(apis)} configured APIs",
                             {'apis': list(apis.keys())}, execution_time)
                
                # Test each scheme
                schemes = set(api['scheme'] for api in apis.values())
                for scheme in schemes:
                    self._test_scheme_functions(scheme)
                
                return True
            else:
                self.log_test("apis", "language_model_config", False,
                             "No language model APIs configured", {}, execution_time)
                return False
                
        except Exception as e:
            execution_time = time.time() - start_time
            self.log_test("apis", "language_model_config", False,
                         "API configuration test failed",
                         {'error': str(e)}, execution_time)
            return False
    
    def _test_scheme_functions(self, scheme: str):
        """Test functions for a specific API scheme."""
        try:
            # Test if scheme-specific request function exists
            func_name = f"p8.request_{scheme}"
            result = self.execute_query("""
                SELECT EXISTS (
                    SELECT 1 FROM pg_proc p
                    JOIN pg_namespace n ON p.pronamespace = n.oid
                    WHERE n.nspname = 'p8' AND p.proname = %s
                )
            """, (f"request_{scheme}",), fetch_one=True)
            
            if result[0]:
                self.log_test("apis", f"{scheme}_request_function", True,
                             f"Request function exists for {scheme}")
            else:
                self.log_test("apis", f"{scheme}_request_function", False,
                             f"Request function missing for {scheme}")
                
        except Exception as e:
            self.log_test("apis", f"{scheme}_request_function", False,
                         f"Scheme function test failed for {scheme}",
                         {'error': str(e)})
    
    def run_comprehensive_diagnostics(self):
        """Run the complete diagnostic suite."""
        print("🔬 Percolate Comprehensive Diagnostic Suite")
        print("=" * 70)
        
        total_start_time = time.time()
        
        # Core infrastructure tests
        print("\n📊 Testing Core Infrastructure...")
        self.test_database_connectivity()
        self.test_extensions()
        self.test_finalize_script_execution()  # CRITICAL: Test if initialization completed
        self.test_model_tables()
        
        # Test each function category
        all_category_results = {}
        for category, functions in self.function_categories.items():
            category_results = self.test_function_category(category, functions)
            all_category_results[category] = category_results
        
        # Test execution capabilities
        execution_results = self.test_simple_function_execution()
        all_category_results['execution'] = execution_results
        
        # Test specialized functionality
        self.test_graph_functionality()
        self.test_language_model_apis()
        self.test_api_connectivity()
        self.test_ai_functionality()
        
        # Generate comprehensive summary
        total_time = time.time() - total_start_time
        self._generate_summary(all_category_results, total_time)
        
        return all_category_results
    
    def _generate_summary(self, category_results: Dict, total_time: float):
        """Generate comprehensive summary report."""
        print("\n" + "=" * 70)
        print("📋 Diagnostic Summary Report")
        print("=" * 70)
        
        total_tests = sum(self.test_results.__len__() for _ in [1])
        passed_tests = sum(1 for result in self.test_results if result['success'])
        failed_tests = total_tests - passed_tests
        
        print(f"⏱️  Total Execution Time: {total_time:.2f} seconds")
        print(f"🧪 Total Tests: {total_tests}")
        print(f"✅ Passed: {passed_tests}")
        print(f"❌ Failed: {failed_tests}")
        print(f"📊 Success Rate: {(passed_tests / total_tests * 100):.1f}%")
        
        print(f"\n📈 Category Breakdown:")
        for category, results in category_results.items():
            if isinstance(results, dict) and 'total' in results:
                rate = (results['passed'] / results['total'] * 100) if results['total'] > 0 else 0
                print(f"  {category.capitalize()}: {results['passed']}/{results['total']} ({rate:.1f}%)")
        
        # Show critical failures
        critical_failures = [r for r in self.test_results 
                           if not r['success'] and r['category'] in ['database', 'schema']]
        
        if critical_failures:
            print(f"\n⚠️  Critical Issues:")
            for failure in critical_failures:
                print(f"  - {failure['category']}.{failure['test']}: {failure['message']}")
        
        # Show function coverage
        total_functions = sum(len(funcs) for funcs in self.function_categories.values())
        available_functions = sum(results.get('passed', 0) for results in category_results.values() 
                                if isinstance(results, dict) and 'passed' in results)
        
        print(f"\n🔧 Function Coverage: {available_functions}/{total_functions} "
              f"({(available_functions / total_functions * 100):.1f}%)")
        
        # Recommendations
        print(f"\n💡 Recommendations:")
        if failed_tests == 0:
            print("  🎉 All diagnostics passed! System is fully operational.")
        else:
            if any(r['category'] == 'database' and not r['success'] for r in self.test_results):
                print("  🔧 Fix database connectivity and extension issues first")
            if any(r['category'] == 'schema' and not r['success'] for r in self.test_results):
                print("  📋 Run initialization script to create missing tables")
            if any(r['category'] in ['core', 'entities'] and not r['success'] for r in self.test_results):
                print("  ⚙️  Install P8 functions by running SQL scripts")
    
    def save_diagnostic_report(self, filename: str = None):
        """Save detailed diagnostic report to JSON."""
        if filename is None:
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            filename = f"percolate_diagnostics_{timestamp}.json"
        
        report = {
            'timestamp': datetime.now().isoformat(),
            'database_config': {k: v for k, v in self.db_config.items() if k != 'password'},
            'test_results': self.test_results,
            'summary': {
                'total_tests': len(self.test_results),
                'passed': sum(1 for r in self.test_results if r['success']),
                'failed': sum(1 for r in self.test_results if not r['success']),
                'categories': list(set(r['category'] for r in self.test_results)),
                'function_categories': self.function_categories
            }
        }
        
        try:
            with open(filename, 'w') as f:
                json.dump(report, f, indent=2, default=str)
            print(f"📄 Diagnostic report saved to: {filename}")
        except Exception as e:
            print(f"❌ Failed to save diagnostic report: {e}")
        
        return filename


def main():
    parser = argparse.ArgumentParser(description="Run Percolate comprehensive diagnostics")
    parser.add_argument('--db-host', default='localhost', help='Database host')
    parser.add_argument('--db-port', type=int, default=5438, help='Database port')
    parser.add_argument('--db-name', default='app', help='Database name')
    parser.add_argument('--db-user', default='postgres', help='Database user')
    parser.add_argument('--db-password', default='postgres', help='Database password')
    parser.add_argument('--save-report', action='store_true', help='Save detailed JSON report')
    parser.add_argument('--category', help='Test only specific category')
    
    args = parser.parse_args()
    
    db_config = {
        'host': args.db_host,
        'port': args.db_port,
        'database': args.db_name,
        'user': args.db_user,
        'password': args.db_password
    }
    
    diagnostics = PercolateDiagnostics(db_config)
    
    try:
        if args.category:
            # Test specific category
            if args.category in diagnostics.function_categories:
                diagnostics.test_database_connectivity()
                results = diagnostics.test_function_category(
                    args.category, 
                    diagnostics.function_categories[args.category]
                )
                print(f"\n{args.category} results: {results}")
            else:
                print(f"Unknown category: {args.category}")
                print(f"Available categories: {list(diagnostics.function_categories.keys())}")
                sys.exit(1)
        else:
            # Run full diagnostics
            results = diagnostics.run_comprehensive_diagnostics()
        
        if args.save_report:
            diagnostics.save_diagnostic_report()
        
        # Exit with error code if any tests failed
        failed_tests = sum(1 for r in diagnostics.test_results if not r['success'])
        sys.exit(1 if failed_tests > 0 else 0)
        
    except KeyboardInterrupt:
        print("\n⚠️ Diagnostics interrupted by user")
        sys.exit(1)
    except Exception as e:
        print(f"\n❌ Diagnostics failed with error: {e}")
        traceback.print_exc()
        sys.exit(1)


if __name__ == '__main__':
    main()