"""
Pytest configuration file for all tests.

This file contains fixtures and configuration that will be available
to all test files in the project.
"""

import pytest
import sys
import os

# Add the project root to the Python path to ensure imports work correctly
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

# Define project-wide fixtures here if needed