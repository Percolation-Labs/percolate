#!/usr/bin/env python3
"""
Script to rebuild SQL installation files from sql-staging directory.
This script consolidates all SQL functions from sql-staging into the sql directory
for installation and deployment.
"""

import os
import sys
import argparse
from datetime import datetime
from pathlib import Path


class SQLRebuilder:
    def __init__(self, staging_dir, output_dir):
        self.staging_dir = Path(staging_dir)
        self.output_dir = Path(output_dir)
        self.function_categories = [
            'cypher', 'entities', 'index', 'requests', 
            'search', 'security', 'tools', 'users', 'utils'
        ]
        
    def read_sql_file(self, file_path):
        """Read SQL file content with error handling."""
        try:
            with open(file_path, 'r', encoding='utf-8') as f:
                content = f.read().strip()
                if content:
                    return content + '\n\n'
                return ''
        except Exception as e:
            print(f"Warning: Could not read {file_path}: {e}")
            return ''
    
    def get_function_files(self):
        """Get all SQL function files organized by category."""
        function_files = {}
        
        # Look for p8_pg_functions directory
        functions_dir = self.staging_dir / 'p8_pg_functions'
        if not functions_dir.exists():
            print(f"Error: Functions directory not found at {functions_dir}")
            return {}
            
        # Collect files from each category
        for category in self.function_categories:
            category_dir = functions_dir / category
            if category_dir.exists():
                function_files[category] = []
                for sql_file in sorted(category_dir.glob('*.sql')):
                    function_files[category].append(sql_file)
                    
        # Add root level function files
        root_files = []
        for sql_file in functions_dir.glob('*.sql'):
            root_files.append(sql_file)
        if root_files:
            function_files['root'] = sorted(root_files)
            
        return function_files
    
    def build_functions_sql(self):
        """Build the main functions SQL file from all categories."""
        function_files = self.get_function_files()
        if not function_files:
            print("No function files found to process")
            return False
            
        content = []
        content.append("-- Percolate PostgreSQL Functions")
        content.append(f"-- Generated from sql-staging on {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        content.append("-- DO NOT EDIT - This file is auto-generated")
        content.append("")
        
        # Add root level functions first (like percolate.sql, plan.sql)
        if 'root' in function_files:
            content.append("-- ====================================================================")
            content.append("-- ROOT LEVEL FUNCTIONS")
            content.append("-- ====================================================================")
            content.append("")
            
            for sql_file in function_files['root']:
                content.append(f"-- Function from: {sql_file.name}")
                content.append("-" * 60)
                file_content = self.read_sql_file(sql_file)
                if file_content:
                    content.append(file_content)
        
        # Add categorized functions
        for category in self.function_categories:
            if category in function_files and function_files[category]:
                content.append("-- ====================================================================")
                content.append(f"-- {category.upper()} FUNCTIONS")
                content.append("-- ====================================================================")
                content.append("")
                
                for sql_file in function_files[category]:
                    content.append(f"-- Function from: {category}/{sql_file.name}")
                    content.append("-" * 60)
                    file_content = self.read_sql_file(sql_file)
                    if file_content:
                        content.append(file_content)
        
        # Write the consolidated file
        output_file = self.output_dir / '01_add_functions.sql'
        try:
            with open(output_file, 'w', encoding='utf-8') as f:
                f.write('\n'.join(content))
            print(f"✅ Successfully created {output_file}")
            return True
        except Exception as e:
            print(f"❌ Error writing {output_file}: {e}")
            return False
    
    def copy_other_sql_files(self):
        """Copy other SQL files that aren't functions."""
        other_files = ['examples.sql']
        staging_files = list(self.staging_dir.glob('*.sql'))
        
        for sql_file in staging_files:
            if sql_file.name in other_files:
                try:
                    content = self.read_sql_file(sql_file)
                    if content:
                        output_file = self.output_dir / sql_file.name
                        with open(output_file, 'w', encoding='utf-8') as f:
                            f.write(content)
                        print(f"✅ Copied {sql_file.name}")
                except Exception as e:
                    print(f"❌ Error copying {sql_file.name}: {e}")
    
    def rebuild_all(self):
        """Rebuild all SQL files from staging."""
        print(f"🔨 Rebuilding SQL files from {self.staging_dir} to {self.output_dir}")
        
        # Ensure output directory exists
        self.output_dir.mkdir(parents=True, exist_ok=True)
        
        # Build main functions file
        if not self.build_functions_sql():
            return False
            
        # Copy other files
        self.copy_other_sql_files()
        
        print("🎉 SQL rebuild completed successfully!")
        return True
    
    def verify_rebuild(self):
        """Verify that the rebuild was successful."""
        functions_file = self.output_dir / '01_add_functions.sql'
        if not functions_file.exists():
            print("❌ Functions file was not created")
            return False
            
        # Check file size
        file_size = functions_file.stat().st_size
        if file_size < 1000:  # Expect at least 1KB for a valid functions file
            print(f"❌ Functions file seems too small: {file_size} bytes")
            return False
            
        print(f"✅ Functions file created successfully: {file_size} bytes")
        return True


def main():
    parser = argparse.ArgumentParser(description="Rebuild SQL files from sql-staging")
    parser.add_argument(
        '--staging-dir', 
        default='../extension/sql-staging',
        help='Path to sql-staging directory (default: ../extension/sql-staging)'
    )
    parser.add_argument(
        '--output-dir',
        default='../extension/sql', 
        help='Path to output sql directory (default: ../extension/sql)'
    )
    parser.add_argument(
        '--verify',
        action='store_true',
        help='Verify the rebuild after completion'
    )
    
    args = parser.parse_args()
    
    # Resolve paths relative to script location
    script_dir = Path(__file__).parent
    staging_dir = (script_dir / args.staging_dir).resolve()
    output_dir = (script_dir / args.output_dir).resolve()
    
    if not staging_dir.exists():
        print(f"❌ Staging directory not found: {staging_dir}")
        sys.exit(1)
    
    print(f"📁 Staging directory: {staging_dir}")
    print(f"📁 Output directory: {output_dir}")
    
    # Create rebuilder and run
    rebuilder = SQLRebuilder(staging_dir, output_dir)
    
    if not rebuilder.rebuild_all():
        print("❌ Rebuild failed")
        sys.exit(1)
    
    if args.verify:
        if not rebuilder.verify_rebuild():
            print("❌ Verification failed")
            sys.exit(1)
    
    print("🚀 Ready to generate ConfigMaps and deploy!")


if __name__ == '__main__':
    main()