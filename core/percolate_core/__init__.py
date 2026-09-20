"""percolate-core — Postgres-native subsystems.

The database is the system; these are the processes that sit in front of it.
Everything here connects through the same RLS-scoped roles and holds no table
grants: every interaction is a SECURITY DEFINER function call.

    percolate_core.core      connecting as the caller, configuration   (always)
    percolate_core.worker    the step loop and @handler registry       (always)
    percolate_core.content   the Content Server                        [content]
    percolate_core.agentic   the Agent Runtime                         [agent]
"""

__version__ = "0.2.4"
