"""The clue walk: a query that reads in waves and lets a decider choose where to look between them (REM-1200).

`engine.walk` walks one question over a `Store`; `deciders` gives clues their P, from Jev or a verdict file; `store`
reads Percolate's chunks and walk links, or a fixture; `cli` is `percolate walk`.
"""

from .engine import TASK, Settings, walk

__all__ = ["TASK", "Settings", "walk"]
