import requests
import html2text


def fetch_web_markdown(url:str):
    """_summary_

    Args:
        url (str): _description_
    """
    
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/110.0.0.0 Safari/537.36"
    }
       
    data = requests.get(url, headers=headers).content.decode()
    return html2text.html2text(data)
    