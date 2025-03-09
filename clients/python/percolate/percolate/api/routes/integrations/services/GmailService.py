SCOPES = ['https://www.googleapis.com/auth/gmail.readonly']
from . import EmailMessage
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from datetime import datetime,timedelta

class GmailService:
    def __init__(self, token=None):
        
        """for convenience if the token is null we use convention to try and read it from percolate home"""
        self.token = token
        
    def fetch_gmail_since(self, limit=50, domain_filters=None, start_date=None, sender_domain=None):
        """Shows basic usage of the Gmail API.
        Lists the user's Gmail labels.
        """
    
        try:
            service = build('gmail', 'v1', credentials=self.token)
            today = datetime.now().date()
            start_date = datetime.strptime(start_date, '%Y-%m-%d').date() if start_date else today
            all_messages = [] 
            current_date = start_date

            while current_date < today:
                next_date = current_date + timedelta(days=30)
                if next_date > today:
                    next_date = today  # Ensure we don't go beyond today

                from_date = current_date.strftime('%Y/%m/%d')
                to_date = next_date.strftime('%Y/%m/%d')
                query = f'after:{from_date} before:{to_date}'
                if sender_domain:
                    query += f' from:@{sender_domain}'

                print(f"Fetching messages for: {from_date} to {to_date}")

                next_page_token = None
            
                while True:  # Pagination loop
                    results = service.users().messages().list(userId='me', q=query, maxResults=limit,pageToken = next_page_token).execute()
                    messages = results.get('messages', [])
                    
                    for message in messages:
                        
                        message = service.users().messages().get(userId='me', id=message['id'], format='raw').execute()
                        m = EmailMessage.parse_raw_to_html(message['raw'])
                
                        if domain_filters:
                            for d in domain_filters:
                                if d in m.sender:
                                    all_messages.append(m)
                        else:
                            all_messages.append(m)
                            
                    next_page_token = results.get('nextPageToken')
                    
                    all_messages = []
                    if not next_page_token:
                        break  # No more pages for this query
                        
                # Move to the next 30-day window
                current_date = next_date
            return all_messages
        except HttpError as error:
            print(f'An error occurred: {error}')