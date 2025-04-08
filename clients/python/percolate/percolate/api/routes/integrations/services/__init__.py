from pydantic import BaseModel,model_validator
import typing
import html2text
from percolate.utils import make_uuid

class EmailMessage(BaseModel):
    """You are an email and newsletter agent. If asked about emails or newsletters you can run a search to answer the users question.
    
    """
    
    model_config = {
        'namespace': 'public',
        'functions':  {"test":"desc"}
    }
 
    content: typing.Optional[str] = None
    sender: str 
    receiver: str
    subject:str
    date: str
    
    @model_validator(mode="before")
    def _val(cls, values):
        """validation for default vals.
           ids is easy to generate from required fields.
           description should be markdown of the html
        """
        if not values.get('description') and values.get('content'):
            try:
                values['description'] = html2text.html2text(values['content'])
            except:
                values['description'] = values.get('content')
        """set the id if its not set"""
        if not values.get('id') and values.get('sender') and values.get('date'):
            values['id'] = make_uuid({
                'sender': values['sender'],
                'date':values['date']
            })
            
        return values
    
    
    def _repr_html_(self):
        return self.content
    
    def to_markdown(self):
        """convert the html content to markdown"""
        markdown = html2text.html2text(self.content)
        return markdown
    
 

from .GoogleService import GmailService