#!/usr/bin/env python3
"""
Comprehensive Docker environment management script for Percolate.
This script handles fresh setup, teardown, and testing of the complete environment.
"""

import os
import sys
import time
import subprocess
import argparse
from pathlib import Path
from datetime import datetime


class PercolateEnvironmentManager:
    def __init__(self, project_root=None):
        self.project_root = Path(project_root) if project_root else Path(__file__).parent.parent
        self.scripts_dir = self.project_root / "scripts"
        
    def run_command(self, cmd, cwd=None, timeout=300, show_output=True):
        """Run a shell command with proper error handling."""
        if cwd is None:
            cwd = self.project_root
            
        print(f"🔨 Executing: {cmd}")
        if cwd != self.project_root:
            print(f"📁 In directory: {cwd}")
            
        try:
            if show_output:
                result = subprocess.run(
                    cmd, shell=True, cwd=cwd, timeout=timeout, check=True
                )
                return result.returncode == 0
            else:
                result = subprocess.run(
                    cmd, shell=True, cwd=cwd, timeout=timeout, 
                    capture_output=True, text=True, check=True
                )
                return result.returncode == 0
        except subprocess.CalledProcessError as e:
            print(f"❌ Command failed with return code {e.returncode}")
            if hasattr(e, 'stdout') and e.stdout:
                print(f"STDOUT: {e.stdout}")
            if hasattr(e, 'stderr') and e.stderr:
                print(f"STDERR: {e.stderr}")
            return False
        except subprocess.TimeoutExpired:
            print(f"❌ Command timed out after {timeout}s")
            return False
        except Exception as e:
            print(f"❌ Command error: {e}")
            return False
    
    def check_prerequisites(self):
        """Check that required tools are available."""
        print("🔍 Checking prerequisites...")
        
        required_tools = {
            'docker': 'Docker is required for container management',
            'python3': 'Python 3 is required for scripts',
            'git': 'Git is required for version control'
        }
        
        # Check for docker compose (v2 command)
        if not self.run_command("docker compose version", show_output=False):
            required_tools['docker-compose'] = 'Docker Compose is required for orchestration'
        
        missing_tools = []
        
        for tool, description in required_tools.items():
            if not self.run_command(f"which {tool}", show_output=False):
                missing_tools.append(f"{tool}: {description}")
        
        if missing_tools:
            print("❌ Missing prerequisites:")
            for tool in missing_tools:
                print(f"  - {tool}")
            return False
        
        print("✅ All prerequisites available")
        return True
    
    def stop_and_cleanup_containers(self):
        """Stop all containers and clean up volumes."""
        print("🛑 Stopping and cleaning up containers...")
        
        # Stop all containers
        self.run_command("docker compose down -v --remove-orphans", show_output=False)
        
        # Clean up any remaining percolate containers
        cleanup_commands = [
            "docker stop $(docker ps -q --filter name=percolate) 2>/dev/null || true",
            "docker stop $(docker ps -q --filter name=ollama) 2>/dev/null || true", 
            "docker stop $(docker ps -q --filter name=minio) 2>/dev/null || true",
            "docker rm $(docker ps -aq --filter name=percolate) 2>/dev/null || true",
            "docker rm $(docker ps -aq --filter name=ollama) 2>/dev/null || true",
            "docker rm $(docker ps -aq --filter name=minio) 2>/dev/null || true"
        ]
        
        for cmd in cleanup_commands:
            self.run_command(cmd, show_output=False)
        
        print("✅ Containers stopped and cleaned up")
    
    def cleanup_images(self, force=False):
        """Clean up Docker images."""
        print("🧹 Cleaning up Docker images...")
        
        if force:
            # Remove percolate-specific images
            image_cleanup_commands = [
                "docker rmi percolationlabs/percolate-api:latest 2>/dev/null || true",
                "docker rmi percolationlabs/postgres-base:16 2>/dev/null || true",
                "docker rmi percolate-api:latest 2>/dev/null || true",
                "docker rmi postgres-base:16 2>/dev/null || true"
            ]
            
            for cmd in image_cleanup_commands:
                self.run_command(cmd, show_output=False)
        
        # Clean up dangling images
        self.run_command("docker image prune -f", show_output=False)
        
        print("✅ Images cleaned up")
    
    def cleanup_volumes(self):
        """Clean up Docker volumes."""
        print("💾 Cleaning up Docker volumes...")
        
        volume_cleanup_commands = [
            "docker volume rm percolate_percolate_data 2>/dev/null || true",
            "docker volume rm percolate_minio_data 2>/dev/null || true",
            "docker volume rm percolate_ollama_data 2>/dev/null || true",
            "docker volume prune -f"
        ]
        
        for cmd in volume_cleanup_commands:
            self.run_command(cmd, show_output=False)
        
        print("✅ Volumes cleaned up")
    
    def rebuild_sql_from_staging(self):
        """Rebuild SQL files from staging."""
        print("🔄 Rebuilding SQL from staging...")
        
        rebuild_script = self.scripts_dir / "rebuild_sql_from_staging.py"
        if not rebuild_script.exists():
            print(f"❌ Rebuild script not found: {rebuild_script}")
            return False
        
        if self.run_command(f"python {rebuild_script} --verify"):
            print("✅ SQL rebuilt from staging")
            return True
        else:
            print("❌ Failed to rebuild SQL from staging")
            return False
    
    def build_images(self, push=False):
        """Build Docker images."""
        print("🏗️ Building Docker images...")
        
        build_script = self.scripts_dir / "build_and_push_docker.py"
        if not build_script.exists():
            print(f"❌ Build script not found: {build_script}")
            return False
        
        cmd = f"python {build_script}"
        if push:
            cmd += " --push"
        
        if self.run_command(cmd, timeout=600):  # 10 minute timeout for builds
            print("✅ Images built successfully")
            return True
        else:
            print("❌ Failed to build images")
            return False
    
    def start_services(self):
        """Start all Docker services."""
        print("🚀 Starting Docker services...")
        
        if self.run_command("docker compose up -d", timeout=300):
            print("✅ Services started")
            return True
        else:
            print("❌ Failed to start services")
            return False
    
    def wait_for_services(self, timeout=120):
        """Wait for services to be ready."""
        print("⏳ Waiting for services to be ready...")
        
        start_time = time.time()
        
        while time.time() - start_time < timeout:
            # Check if all containers are running
            result = self.run_command("docker compose ps --format json", show_output=False)
            if result:
                print(".", end="", flush=True)
                time.sleep(5)
                
                # Simple check - if we can connect to the database port
                db_check = self.run_command("nc -z localhost 5438", show_output=False)
                api_check = self.run_command("nc -z localhost 5008", show_output=False)
                
                if db_check and api_check:
                    print()
                    print("✅ Services are ready")
                    return True
            else:
                time.sleep(2)
                
        print()
        print("❌ Services failed to start within timeout")
        return False
    
    def run_init_script(self):
        """Run the percolate init script."""
        print("🔧 Running percolate init script...")
        
        # Check if we're in the python client directory
        python_client = self.project_root / "clients" / "python" / "percolate"
        if not python_client.exists():
            print(f"❌ Python client directory not found: {python_client}")
            return False
        
        # Try different ways to run the init
        init_commands = [
            "poetry run p8 init",
            "python -m percolate.cli init",
            "python percolate/cli.py init"
        ]
        
        for cmd in init_commands:
            print(f"🔄 Trying: {cmd}")
            if self.run_command(cmd, cwd=python_client, timeout=120):
                print("✅ Init script completed successfully")
                return True
            print(f"❌ Command failed: {cmd}")
        
        print("❌ All init commands failed")
        return False
    
    def run_tests(self):
        """Run the test suite."""
        print("🧪 Running test suite...")
        
        test_script = self.scripts_dir / "test_docker_environment.py"
        if not test_script.exists():
            print(f"❌ Test script not found: {test_script}")
            return False
        
        # Install required Python packages
        install_cmd = "pip install psycopg2-binary requests"
        if not self.run_command(install_cmd, show_output=False):
            print("⚠️ Failed to install test dependencies, tests may fail")
        
        if self.run_command(f"python {test_script} --save-report"):
            print("✅ All tests passed")
            return True
        else:
            print("❌ Some tests failed")
            return False
    
    def create_fresh_environment(self, skip_build=False, skip_init=False, skip_tests=False):
        """Create a completely fresh environment."""
        print("🔥 Creating fresh Percolate environment...")
        print("=" * 60)
        
        start_time = time.time()
        steps_completed = 0
        total_steps = 8
        
        try:
            # Step 1: Check prerequisites
            print(f"[{steps_completed + 1}/{total_steps}] Checking prerequisites...")
            if not self.check_prerequisites():
                return False
            steps_completed += 1
            
            # Step 2: Stop and cleanup
            print(f"\n[{steps_completed + 1}/{total_steps}] Stopping and cleaning up...")
            self.stop_and_cleanup_containers()
            self.cleanup_images(force=True)
            self.cleanup_volumes()
            steps_completed += 1
            
            # Step 3: Rebuild SQL
            print(f"\n[{steps_completed + 1}/{total_steps}] Rebuilding SQL from staging...")
            if not self.rebuild_sql_from_staging():
                return False
            steps_completed += 1
            
            # Step 4: Build images (optional)
            if not skip_build:
                print(f"\n[{steps_completed + 1}/{total_steps}] Building Docker images...")
                if not self.build_images():
                    return False
            else:
                print(f"\n[{steps_completed + 1}/{total_steps}] Skipping image build...")
            steps_completed += 1
            
            # Step 5: Start services
            print(f"\n[{steps_completed + 1}/{total_steps}] Starting services...")
            if not self.start_services():
                return False
            steps_completed += 1
            
            # Step 6: Wait for services
            print(f"\n[{steps_completed + 1}/{total_steps}] Waiting for services...")
            if not self.wait_for_services():
                return False
            steps_completed += 1
            
            # Step 7: Run init (optional)
            if not skip_init:
                print(f"\n[{steps_completed + 1}/{total_steps}] Running init script...")
                if not self.run_init_script():
                    print("⚠️ Init script failed, but continuing...")
            else:
                print(f"\n[{steps_completed + 1}/{total_steps}] Skipping init script...")
            steps_completed += 1
            
            # Step 8: Run tests (optional)
            if not skip_tests:
                print(f"\n[{steps_completed + 1}/{total_steps}] Running tests...")
                self.run_tests()  # Don't fail on test failures
            else:
                print(f"\n[{steps_completed + 1}/{total_steps}] Skipping tests...")
            steps_completed += 1
            
            # Success!
            end_time = time.time()
            duration = end_time - start_time
            
            print("\n" + "=" * 60)
            print("🎉 Fresh environment created successfully!")
            print(f"⏱️  Total time: {duration:.1f} seconds")
            print("🌐 Services available at:")
            print("  - API: http://localhost:5008")
            print("  - Database: localhost:5438 (postgres/postgres)")
            print("  - MinIO: http://localhost:9090 (percolate/percolate)")
            print("  - Ollama: http://localhost:11434")
            
            return True
            
        except KeyboardInterrupt:
            print("\n⚠️ Setup interrupted by user")
            return False
        except Exception as e:
            print(f"\n❌ Setup failed with error: {e}")
            return False
    
    def show_status(self):
        """Show current environment status."""
        print("📊 Environment Status:")
        print("=" * 40)
        
        # Check containers
        print("🐳 Docker Containers:")
        self.run_command("docker compose ps", show_output=True)
        
        print("\n💾 Docker Volumes:")
        self.run_command("docker volume ls | grep percolate", show_output=True)
        
        print("\n🖼️ Docker Images:")
        self.run_command("docker images | grep -E '(percolate|postgres-base)'", show_output=True)


def main():
    parser = argparse.ArgumentParser(description="Manage Percolate Docker environment")
    parser.add_argument('action', choices=['fresh', 'cleanup', 'status', 'test', 'build'],
                       help='Action to perform')
    parser.add_argument('--skip-build', action='store_true',
                       help='Skip building images (use existing)')
    parser.add_argument('--skip-init', action='store_true',
                       help='Skip running init script')
    parser.add_argument('--skip-tests', action='store_true',
                       help='Skip running test suite')
    parser.add_argument('--push', action='store_true',
                       help='Push images to registry after building')
    
    args = parser.parse_args()
    
    manager = PercolateEnvironmentManager()
    
    if args.action == 'fresh':
        success = manager.create_fresh_environment(
            skip_build=args.skip_build,
            skip_init=args.skip_init,
            skip_tests=args.skip_tests
        )
        sys.exit(0 if success else 1)
        
    elif args.action == 'cleanup':
        manager.stop_and_cleanup_containers()
        manager.cleanup_images(force=True)
        manager.cleanup_volumes()
        print("🧹 Cleanup completed")
        
    elif args.action == 'status':
        manager.show_status()
        
    elif args.action == 'test':
        test_script = manager.scripts_dir / "test_docker_environment.py"
        success = manager.run_command(f"python {test_script} --save-report")
        sys.exit(0 if success else 1)
        
    elif args.action == 'build':
        success = manager.build_images(push=args.push)
        sys.exit(0 if success else 1)


if __name__ == '__main__':
    main()