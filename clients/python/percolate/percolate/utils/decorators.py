"""
Decorators for Percolate framework
"""


def tool(access_required: int = 100):
    """
    Decorator to mark functions as tools with access control

    Args:
        access_required: Minimum role level required (lower = more restrictive)
                        Default 100 allows all users
                        Examples:
                        - 1: Admin only
                        - 10: Partner level
                        - 100: All users (default)
    """

    def decorator(func):
        # Store access requirement as function attribute
        func._p8_access_required = access_required
        func._p8_is_tool = True
        return func

    return decorator
