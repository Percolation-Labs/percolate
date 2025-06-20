"""
Executive Resources Model
This model contains resources that require elevated access permissions
"""

from percolate.models.p8.types import Resources
from percolate.models.p8.db_types import AccessLevel

class ExecutiveResources(Resources):
    """
    Executive resources model for sensitive company documents with elevated access control
    """
    class Config:
        namespace = 'executive'
        access_level = AccessLevel.ADMIN  # Admin access level (1)
        description = """Executive docs are used as the Resonance data room and may contain confidential information.
        Certain users that have the system admin or executive roles can access these documents.
        We provide information e.g. for due diligence (investors) or to understand Resonance's 
        - Value proposition
        - Mission
        - Values
        - Strategy
        - IP
        etc.
        
        If you don't know how to answer the question from search you can use other resources
        - Entities can be looked up by keys
        - You can recruit the help of other resources by calling the help function and executing the plan
        """