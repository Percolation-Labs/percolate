try:
    import os
    module_dir = os.path.dirname(__file__)
    version_file = os.path.join(module_dir, '__version__')
    with open(version_file, 'r') as f:
        __version__ = f.read().strip()
except FileNotFoundError:
    __version__ = "unknown"
    
from .interface import *