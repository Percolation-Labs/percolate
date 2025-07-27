#!/usr/bin/env python3
"""
Register UserMemory model in the database
"""
import percolate as p8
from percolate.models.p8.types import UserMemory

print("Registering UserMemory model...")
try:
    result = p8.repository(UserMemory).register()
    print(f"Registration result: {result}")
    print("✅ UserMemory model registered successfully!")
except Exception as e:
    print(f"Registration error (may already exist): {e}")
    print("This is normal if the model was already registered.")