#!/usr/bin/env python
"""Run MCP integration tests with proper setup"""

import os
import sys
import subprocess
import argparse
import time
from pathlib import Path

# Add parent directory to path
sys.path.insert(0, str(Path(__file__).parent.parent.parent.parent.parent))


def check_docker():
    """Check if Docker is available"""
    try:
        result = subprocess.run(["docker", "ps"], capture_output=True, text=True)
        return result.returncode == 0
    except FileNotFoundError:
        return False


def check_database():
    """Check if test database is running"""
    result = subprocess.run(
        ["docker", "ps", "--filter", "name=percolate-test-db", "--format", "{{.Names}}"],
        capture_output=True,
        text=True
    )
    return "percolate-test-db" in result.stdout


def start_test_database():
    """Start test database if not running"""
    if not check_database():
        print("Starting test database...")
        subprocess.run([
            "docker", "run", "-d",
            "--name", "percolate-test-db",
            "-e", "POSTGRES_PASSWORD=postgres",
            "-e", "POSTGRES_DB=test_percolate",
            "-p", "5433:5432",
            "pgvector/pgvector:pg16"
        ])
        
        # Wait for database to be ready
        print("Waiting for database to be ready...")
        time.sleep(5)


def run_tests(args):
    """Run the integration tests"""
    # Set up environment
    env = os.environ.copy()
    env.update({
        "P8_PG_HOST": args.db_host,
        "P8_PG_PORT": str(args.db_port),
        "P8_PG_USER": args.db_user,
        "P8_PG_PASSWORD": args.db_password,
        "P8_API_KEY": args.api_key,
        "P8_USER_EMAIL": args.user_email,
        "P8_LOG_LEVEL": args.log_level
    })
    
    # Build pytest command
    cmd = [
        sys.executable, "-m", "pytest",
        "test_integration_stdio.py",
        "-v"
    ]
    
    if args.specific_test:
        cmd.append(f"::{args.specific_test}")
    
    if args.coverage:
        cmd.extend(["--cov=percolate.api.mcp_server", "--cov-report=html"])
    
    if args.pdb:
        cmd.append("--pdb")
    
    if args.capture_no:
        cmd.append("-s")
    
    if not args.slow:
        cmd.extend(["-m", "not slow"])
    
    # Run tests
    print(f"Running: {' '.join(cmd)}")
    result = subprocess.run(cmd, env=env, cwd=Path(__file__).parent)
    
    return result.returncode


def main():
    parser = argparse.ArgumentParser(description="Run MCP integration tests")
    
    # Database options
    parser.add_argument("--db-host", default="localhost", help="Database host")
    parser.add_argument("--db-port", default=5433, type=int, help="Database port")
    parser.add_argument("--db-user", default="postgres", help="Database user")
    parser.add_argument("--db-password", default="postgres", help="Database password")
    
    # Auth options
    parser.add_argument("--api-key", default="test-api-key", help="API key for testing")
    parser.add_argument("--user-email", default="test@percolate.local", help="User email")
    
    # Test options
    parser.add_argument("--specific-test", help="Run specific test (e.g., TestEntityToolsStdio::test_entity_search_stdio)")
    parser.add_argument("--coverage", action="store_true", help="Generate coverage report")
    parser.add_argument("--pdb", action="store_true", help="Drop into debugger on failure")
    parser.add_argument("--capture-no", "-s", action="store_true", help="Disable output capture")
    parser.add_argument("--slow", action="store_true", help="Include slow tests")
    parser.add_argument("--log-level", default="INFO", help="Log level")
    
    # Docker options
    parser.add_argument("--no-docker", action="store_true", help="Don't start Docker database")
    parser.add_argument("--keep-db", action="store_true", help="Keep database after tests")
    
    args = parser.parse_args()
    
    # Check prerequisites
    if not args.no_docker:
        if not check_docker():
            print("ERROR: Docker is not available. Install Docker or use --no-docker")
            return 1
        
        # Start database if needed
        start_test_database()
    
    # Run tests
    exit_code = run_tests(args)
    
    # Cleanup
    if not args.keep_db and not args.no_docker and check_database():
        print("\nStopping test database...")
        subprocess.run(["docker", "stop", "percolate-test-db"])
        subprocess.run(["docker", "rm", "percolate-test-db"])
    
    return exit_code


if __name__ == "__main__":
    sys.exit(main())