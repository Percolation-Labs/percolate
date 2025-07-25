#!/usr/bin/env python3
"""
Test script for Percolate Docker environment.
This script performs comprehensive integration testing of the full stack.
"""

import os
import sys
import time
import json
import subprocess
import requests
import psycopg2
from pathlib import Path
from datetime import datetime
import argparse


class PercolateDockerTester:
    def __init__(self, project_root=None):
        self.project_root = Path(project_root) if project_root else Path(__file__).parent.parent
        self.api_url = "http://localhost:5008"
        self.db_config = {
            'host': 'localhost',
            'port': 5438,
            'database': 'app',
            'user': 'postgres',
            'password': 'postgres'
        }
        self.test_results = []
        
    def log_test(self, test_name, success, message="", details=None):
        """Log test results."""
        status = "✅ PASS" if success else "❌ FAIL"
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        
        result = {
            'timestamp': timestamp,
            'test': test_name,
            'success': success,
            'message': message,
            'details': details or {}
        }
        
        self.test_results.append(result)
        print(f"{status} {test_name}: {message}")
        
        if details and not success:
            for key, value in details.items():
                print(f"    {key}: {value}")
    
    def run_command(self, cmd, timeout=30):
        """Run a shell command and return result."""
        try:
            result = subprocess.run(
                cmd, shell=True, capture_output=True, text=True, timeout=timeout
            )
            return result.returncode == 0, result.stdout, result.stderr
        except subprocess.TimeoutExpired:
            return False, "", f"Command timed out after {timeout}s"
        except Exception as e:
            return False, "", str(e)
    
    def test_docker_services_running(self):
        """Test that all Docker services are running."""
        print("🐳 Testing Docker services...")
        
        success, stdout, stderr = self.run_command("docker compose ps --format json")
        if not success:
            self.log_test("docker_services", False, "Failed to get service status", 
                         {'error': stderr})
            return False
        
        try:
            services = [json.loads(line) for line in stdout.strip().split('\n') if line]
            expected_services = ['percolate-api', 'percolate', 'ollama-service', 'minio']
            
            running_services = []
            failed_services = []
            
            for service in services:
                name = service.get('Name', '')
                state = service.get('State', '')
                if state == 'running':
                    running_services.append(name)
                else:
                    failed_services.append(f"{name}: {state}")
            
            all_running = all(svc in running_services for svc in expected_services)
            
            if all_running:
                self.log_test("docker_services", True, 
                             f"All services running: {', '.join(running_services)}")
            else:
                missing = [svc for svc in expected_services if svc not in running_services]
                self.log_test("docker_services", False, 
                             f"Missing services: {', '.join(missing)}", 
                             {'failed_services': failed_services})
            
            return all_running
            
        except Exception as e:
            self.log_test("docker_services", False, "Failed to parse service status", 
                         {'error': str(e)})
            return False
    
    def test_database_connection(self):
        """Test PostgreSQL database connection."""
        print("📊 Testing database connection...")
        
        try:
            conn = psycopg2.connect(**self.db_config)
            cursor = conn.cursor()
            
            # Test basic connection
            cursor.execute("SELECT version()")
            version = cursor.fetchone()[0]
            
            self.log_test("database_connection", True, 
                         f"Connected to PostgreSQL", {'version': version})
            
            cursor.close()
            conn.close()
            return True
            
        except Exception as e:
            self.log_test("database_connection", False, "Database connection failed", 
                         {'error': str(e)})
            return False
    
    def test_database_extensions(self):
        """Test that required extensions are installed."""
        print("🔌 Testing database extensions...")
        
        try:
            conn = psycopg2.connect(**self.db_config)
            cursor = conn.cursor()
            
            # Check for required extensions
            required_extensions = ['age', 'http', 'vector']
            
            cursor.execute("""
                SELECT extname FROM pg_extension 
                WHERE extname IN %s
            """, (tuple(required_extensions),))
            
            installed = [row[0] for row in cursor.fetchall()]
            missing = [ext for ext in required_extensions if ext not in installed]
            
            if not missing:
                self.log_test("database_extensions", True, 
                             f"All extensions installed: {', '.join(installed)}")
                success = True
            else:
                self.log_test("database_extensions", False, 
                             f"Missing extensions: {', '.join(missing)}", 
                             {'installed': installed})
                success = False
            
            cursor.close()
            conn.close()
            return success
            
        except Exception as e:
            self.log_test("database_extensions", False, "Extension check failed", 
                         {'error': str(e)})
            return False
    
    def test_p8_functions_exist(self):
        """Test that p8 functions are installed."""
        print("⚙️ Testing p8 functions...")
        
        try:
            conn = psycopg2.connect(**self.db_config)
            cursor = conn.cursor()
            
            # Test key functions from different categories
            test_functions = [
                'p8.get_entities',
                'p8.vector_search_entity', 
                'p8.ask',
                'public.percolate',
                'p8.create_session',
                'p8.get_tools_by_name'
            ]
            
            installed_functions = []
            missing_functions = []
            
            for func_name in test_functions:
                try:
                    cursor.execute(f"""
                        SELECT proname FROM pg_proc p
                        JOIN pg_namespace n ON p.pronamespace = n.oid
                        WHERE n.nspname || '.' || p.proname = %s
                    """, (func_name,))
                    
                    if cursor.fetchone():
                        installed_functions.append(func_name)
                    else:
                        missing_functions.append(func_name)
                except Exception:
                    missing_functions.append(func_name)
            
            if not missing_functions:
                self.log_test("p8_functions", True, 
                             f"All test functions found: {len(installed_functions)}")
                success = True
            else:
                self.log_test("p8_functions", False, 
                             f"Missing functions: {', '.join(missing_functions)}")
                success = False
            
            cursor.close()
            conn.close()
            return success
            
        except Exception as e:
            self.log_test("p8_functions", False, "Function check failed", 
                         {'error': str(e)})
            return False
    
    def test_api_health(self):
        """Test API health endpoint."""
        print("🌐 Testing API health...")
        
        try:
            response = requests.get(f"{self.api_url}/health", timeout=10)
            
            if response.status_code == 200:
                data = response.json()
                self.log_test("api_health", True, "API health check passed", 
                             {'response': data})
                return True
            else:
                self.log_test("api_health", False, 
                             f"API health check failed: {response.status_code}", 
                             {'response': response.text})
                return False
                
        except requests.exceptions.ConnectionError:
            self.log_test("api_health", False, "Cannot connect to API", 
                         {'url': self.api_url})
            return False
        except Exception as e:
            self.log_test("api_health", False, "API health check error", 
                         {'error': str(e)})
            return False
    
    def test_percolate_function(self):
        """Test the main percolate function."""
        print("🧠 Testing percolate function...")
        
        try:
            conn = psycopg2.connect(**self.db_config)
            cursor = conn.cursor()
            
            # Simple test query
            test_query = "What is 2 + 2?"
            
            cursor.execute("SELECT * FROM percolate(%s)", (test_query,))
            result = cursor.fetchone()
            
            if result:
                self.log_test("percolate_function", True, 
                             "Percolate function executed successfully", 
                             {'query': test_query, 'response_length': len(str(result[0]))})
                success = True
            else:
                self.log_test("percolate_function", False, 
                             "Percolate function returned no result")
                success = False
            
            cursor.close()
            conn.close()
            return success
            
        except Exception as e:
            self.log_test("percolate_function", False, "Percolate function test failed", 
                         {'error': str(e)})
            return False
    
    def test_model_tables_exist(self):
        """Test that p8 model tables exist."""
        print("📋 Testing model tables...")
        
        try:
            conn = psycopg2.connect(**self.db_config)
            cursor = conn.cursor()
            
            # Check for key p8 tables
            expected_tables = [
                'p8."Agent"',
                'p8."Function"', 
                'p8."Session"',
                'p8."AIResponse"',
                'p8."LanguageModelApi"',
                'p8."ModelField"'
            ]
            
            existing_tables = []
            missing_tables = []
            
            for table in expected_tables:
                schema, table_name = table.split('."')
                schema = schema.replace('"', '')
                table_name = table_name.replace('"', '')
                
                cursor.execute("""
                    SELECT EXISTS (
                        SELECT 1 FROM information_schema.tables 
                        WHERE table_schema = %s AND table_name = %s
                    )
                """, (schema, table_name))
                
                if cursor.fetchone()[0]:
                    existing_tables.append(table)
                else:
                    missing_tables.append(table)
            
            if not missing_tables:
                self.log_test("model_tables", True, 
                             f"All model tables exist: {len(existing_tables)}")
                success = True
            else:
                self.log_test("model_tables", False, 
                             f"Missing tables: {', '.join(missing_tables)}")
                success = False
            
            cursor.close()
            conn.close()
            return success
            
        except Exception as e:
            self.log_test("model_tables", False, "Model table check failed", 
                         {'error': str(e)})
            return False
    
    def test_embedding_functionality(self):
        """Test embedding functionality."""
        print("🔍 Testing embedding functionality...")
        
        try:
            conn = psycopg2.connect(**self.db_config)
            cursor = conn.cursor()
            
            # Test embedding generation function exists
            cursor.execute("""
                SELECT EXISTS (
                    SELECT 1 FROM pg_proc p
                    JOIN pg_namespace n ON p.pronamespace = n.oid
                    WHERE n.nspname = 'p8' AND p.proname = 'get_embedding_for_text'
                )
            """)
            
            if cursor.fetchone()[0]:
                self.log_test("embedding_function", True, 
                             "Embedding function exists")
                
                # Test vector search function
                cursor.execute("""
                    SELECT EXISTS (
                        SELECT 1 FROM pg_proc p
                        JOIN pg_namespace n ON p.pronamespace = n.oid
                        WHERE n.nspname = 'p8' AND p.proname = 'vector_search_entity'
                    )
                """)
                
                if cursor.fetchone()[0]:
                    self.log_test("vector_search", True, "Vector search function exists")
                    success = True
                else:
                    self.log_test("vector_search", False, "Vector search function missing")
                    success = False
            else:
                self.log_test("embedding_function", False, "Embedding function missing")
                success = False
            
            cursor.close()
            conn.close()
            return success
            
        except Exception as e:
            self.log_test("embedding_functionality", False, "Embedding test failed", 
                         {'error': str(e)})
            return False
    
    def test_graph_functionality(self):
        """Test graph database functionality."""
        print("🕸️ Testing graph functionality...")
        
        try:
            conn = psycopg2.connect(**self.db_config)
            cursor = conn.cursor()
            
            # Test if AGE is properly set up
            cursor.execute("SELECT * FROM ag_graph")
            graphs = cursor.fetchall()
            
            # Test cypher query function
            cursor.execute("""
                SELECT EXISTS (
                    SELECT 1 FROM pg_proc p
                    WHERE p.proname = 'cypher_query'
                )
            """)
            
            cypher_exists = cursor.fetchone()[0]
            
            if cypher_exists:
                self.log_test("graph_functionality", True, 
                             f"Graph functionality available, {len(graphs)} graphs")
                success = True
            else:
                self.log_test("graph_functionality", False, "Cypher query function missing")
                success = False
            
            cursor.close()
            conn.close()
            return success
            
        except Exception as e:
            self.log_test("graph_functionality", False, "Graph test failed", 
                         {'error': str(e)})
            return False
    
    def run_comprehensive_test_suite(self):
        """Run the complete test suite."""
        print("🧪 Starting comprehensive Percolate Docker environment test...")
        print("=" * 60)
        
        start_time = time.time()
        
        # Core infrastructure tests
        tests = [
            self.test_docker_services_running,
            self.test_database_connection,
            self.test_database_extensions,
            self.test_model_tables_exist,
            self.test_p8_functions_exist,
            self.test_api_health,
            self.test_embedding_functionality,
            self.test_graph_functionality,
            self.test_percolate_function,
        ]
        
        passed = 0
        failed = 0
        
        for test in tests:
            try:
                if test():
                    passed += 1
                else:
                    failed += 1
            except Exception as e:
                print(f"❌ Test {test.__name__} crashed: {e}")
                failed += 1
            
            print()  # Spacing between tests
        
        # Summary
        end_time = time.time()
        duration = end_time - start_time
        
        print("=" * 60)
        print(f"🏁 Test Suite Complete")
        print(f"⏱️  Duration: {duration:.2f} seconds")
        print(f"✅ Passed: {passed}")
        print(f"❌ Failed: {failed}")
        print(f"📊 Success Rate: {(passed / (passed + failed)) * 100:.1f}%")
        
        if failed == 0:
            print("🎉 All tests passed! Environment is ready.")
        else:
            print("⚠️  Some tests failed. Check the results above.")
        
        return failed == 0
    
    def save_test_report(self, filename=None):
        """Save test results to a JSON report."""
        if filename is None:
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            filename = f"percolate_test_report_{timestamp}.json"
        
        report = {
            'timestamp': datetime.now().isoformat(),
            'environment': {
                'api_url': self.api_url,
                'database': self.db_config
            },
            'results': self.test_results,
            'summary': {
                'total_tests': len(self.test_results),
                'passed': sum(1 for r in self.test_results if r['success']),
                'failed': sum(1 for r in self.test_results if not r['success'])
            }
        }
        
        try:
            with open(filename, 'w') as f:
                json.dump(report, f, indent=2)
            print(f"📄 Test report saved to: {filename}")
        except Exception as e:
            print(f"❌ Failed to save test report: {e}")


def main():
    parser = argparse.ArgumentParser(description="Test Percolate Docker environment")
    parser.add_argument('--save-report', action='store_true',
                       help='Save test results to JSON file')
    parser.add_argument('--api-url', default='http://localhost:5008',
                       help='API URL to test (default: http://localhost:5008)')
    parser.add_argument('--db-port', type=int, default=5438,
                       help='Database port (default: 5438)')
    
    args = parser.parse_args()
    
    tester = PercolateDockerTester()
    tester.api_url = args.api_url
    tester.db_config['port'] = args.db_port
    
    success = tester.run_comprehensive_test_suite()
    
    if args.save_report:
        tester.save_test_report()
    
    sys.exit(0 if success else 1)


if __name__ == '__main__':
    main()