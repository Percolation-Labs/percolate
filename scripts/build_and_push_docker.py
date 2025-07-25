#!/usr/bin/env python3
"""
Script to build and push Docker images for Percolate.
This script handles building both the postgres-base and percolate-api images.
"""

import os
import sys
import argparse
import subprocess
import json
from datetime import datetime
from pathlib import Path


class DockerBuilder:
    def __init__(self, registry="percolationlabs", dry_run=False):
        self.registry = registry
        self.dry_run = dry_run
        self.project_root = Path(__file__).parent.parent
        
    def run_command(self, cmd, cwd=None, check=True):
        """Run a shell command with proper error handling."""
        if self.dry_run:
            print(f"[DRY RUN] Would execute: {cmd}")
            if cwd:
                print(f"[DRY RUN] In directory: {cwd}")
            return True
            
        print(f"🔨 Executing: {cmd}")
        if cwd:
            print(f"📁 In directory: {cwd}")
            
        try:
            result = subprocess.run(
                cmd, 
                shell=True, 
                cwd=cwd, 
                check=check,
                capture_output=False,
                text=True
            )
            return result.returncode == 0
        except subprocess.CalledProcessError as e:
            print(f"❌ Command failed with return code {e.returncode}")
            return False
    
    def check_docker(self):
        """Check if Docker is available and running."""
        if not self.run_command("docker --version", check=False):
            print("❌ Docker is not available. Please install Docker.")
            return False
            
        if not self.run_command("docker info", check=False):
            print("❌ Docker daemon is not running. Please start Docker.")
            return False
            
        print("✅ Docker is available and running")
        return True
    
    def build_postgres_base(self, platform="linux/amd64", push=False):
        """Build the postgres-base image."""
        print("🐘 Building postgres-base image...")
        
        dockerfile_path = self.project_root / "Dockerfile"
        if not dockerfile_path.exists():
            print(f"❌ Dockerfile not found at {dockerfile_path}")
            return False
            
        # First rebuild SQL from staging
        print("🔄 Rebuilding SQL from staging...")
        rebuild_script = self.project_root / "scripts" / "rebuild_sql_from_staging.py"
        if not self.run_command(f"python {rebuild_script} --verify"):
            print("❌ Failed to rebuild SQL from staging")
            return False
            
        # Build the image
        tag = f"{self.registry}/postgres-base:16"
        build_cmd = f"DOCKER_BUILDKIT=1 docker build --progress=plain --platform {platform} -t {tag} ."
        
        if not self.run_command(build_cmd, cwd=self.project_root):
            print("❌ Failed to build postgres-base image")
            return False
            
        print(f"✅ Successfully built {tag}")
        
        if push:
            return self.push_image(tag)
            
        return True
    
    def build_api_image(self, platform="linux/amd64", push=False):
        """Build the percolate-api image."""
        print("🚀 Building percolate-api image...")
        
        api_dir = self.project_root / "clients" / "python" / "percolate"
        dockerfile_path = api_dir / "Dockerfile"
        
        if not dockerfile_path.exists():
            print(f"❌ API Dockerfile not found at {dockerfile_path}")
            return False
            
        # Check if poetry.lock exists
        poetry_lock = api_dir / "poetry.lock"
        if not poetry_lock.exists():
            print("🔄 poetry.lock not found, running poetry lock...")
            if not self.run_command("poetry lock", cwd=api_dir):
                print("❌ Failed to create poetry.lock")
                return False
                
        tag = f"{self.registry}/percolate-api:latest"
        
        # Use buildx for multi-platform support
        build_cmd = f"docker buildx build --platform {platform} -t {tag} ."
        
        if push:
            build_cmd += " --push"
        
        if not self.run_command(build_cmd, cwd=api_dir):
            print("❌ Failed to build percolate-api image")
            return False
            
        print(f"✅ Successfully built {tag}")
        
        if not push:
            # Tag the image as well for local use
            local_tag_cmd = f"docker tag {tag} percolate-api:latest"
            self.run_command(local_tag_cmd)
            
        return True
    
    def push_image(self, tag):
        """Push an image to the registry."""
        print(f"📤 Pushing {tag}...")
        
        push_cmd = f"docker push {tag}"
        if not self.run_command(push_cmd):
            print(f"❌ Failed to push {tag}")
            return False
            
        print(f"✅ Successfully pushed {tag}")
        return True
    
    def setup_buildx(self):
        """Set up Docker buildx for multi-platform builds."""
        print("🔧 Setting up Docker buildx...")
        
        # Create buildx instance if it doesn't exist
        create_cmd = "docker buildx create --use --name percolate-builder --platform linux/amd64,linux/arm64 || true"
        self.run_command(create_cmd)
        
        # Bootstrap the builder
        bootstrap_cmd = "docker buildx inspect --bootstrap"
        return self.run_command(bootstrap_cmd)
    
    def clean_images(self):
        """Clean up old Docker images."""
        print("🧹 Cleaning up old Docker images...")
        
        # Remove dangling images
        cleanup_cmd = "docker image prune -f"
        self.run_command(cleanup_cmd, check=False)
        
        print("✅ Cleanup completed")
    
    def build_all(self, platform="linux/amd64", push=False):
        """Build all Docker images."""
        print("🏗️  Building all Percolate Docker images...")
        
        if not self.check_docker():
            return False
            
        if push and platform != "linux/amd64":
            # Set up buildx for multi-platform builds
            if not self.setup_buildx():
                print("❌ Failed to set up buildx")
                return False
        
        # Build postgres-base first (needed by docker-compose)
        if not self.build_postgres_base(platform, push):
            return False
            
        # Build API image
        if not self.build_api_image(platform, push):
            return False
            
        print("🎉 All images built successfully!")
        return True
    
    def create_fresh_environment(self):
        """Drop and recreate Docker environment from scratch."""
        print("🔥 Creating fresh Docker environment...")
        
        # Stop and remove all containers
        print("🛑 Stopping all containers...")
        self.run_command("docker compose down -v --remove-orphans", 
                        cwd=self.project_root, check=False)
        
        # Remove all percolate-related images
        print("🗑️  Removing old images...")
        remove_cmds = [
            f"docker rmi {self.registry}/percolate-api:latest || true",
            f"docker rmi {self.registry}/postgres-base:16 || true",
            "docker rmi percolate-api:latest || true",
            "docker rmi postgres-base:16 || true"
        ]
        
        for cmd in remove_cmds:
            self.run_command(cmd, check=False)
            
        # Clean up dangling images and volumes
        self.clean_images()
        self.run_command("docker volume prune -f", check=False)
        
        print("✅ Environment cleaned up")
        return True


def main():
    parser = argparse.ArgumentParser(description="Build and push Percolate Docker images")
    parser.add_argument('--registry', default='percolationlabs', 
                       help='Docker registry (default: percolationlabs)')
    parser.add_argument('--platform', default='linux/amd64',
                       help='Target platform (default: linux/amd64)')
    parser.add_argument('--push', action='store_true',
                       help='Push images to registry after building')
    parser.add_argument('--postgres-only', action='store_true',
                       help='Build only the postgres-base image')
    parser.add_argument('--api-only', action='store_true',
                       help='Build only the percolate-api image')
    parser.add_argument('--clean', action='store_true',
                       help='Clean up old images before building')
    parser.add_argument('--fresh', action='store_true',
                       help='Create completely fresh environment (removes containers and images)')
    parser.add_argument('--dry-run', action='store_true',
                       help='Show what would be done without executing')
    
    args = parser.parse_args()
    
    builder = DockerBuilder(registry=args.registry, dry_run=args.dry_run)
    
    if args.fresh:
        if not builder.create_fresh_environment():
            sys.exit(1)
    elif args.clean:
        builder.clean_images()
    
    success = True
    
    if args.postgres_only:
        success = builder.build_postgres_base(args.platform, args.push)
    elif args.api_only:
        success = builder.build_api_image(args.platform, args.push)
    else:
        success = builder.build_all(args.platform, args.push)
    
    if not success:
        print("❌ Build process failed")
        sys.exit(1)
        
    print("🚀 Build process completed successfully!")
    
    if not args.push and not args.dry_run:
        print("\n💡 Next steps:")
        print("  1. Test the images: docker compose up -d")
        print("  2. Push to registry: python scripts/build_and_push_docker.py --push")
        print("  3. Run tests: python scripts/test_docker_environment.py")


if __name__ == '__main__':
    main()