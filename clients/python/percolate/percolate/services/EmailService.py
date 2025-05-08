"""
EmailService: a simple SMTP-based email sending service.
"""
import smtplib
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from typing import Union, List, Optional
from email.utils import formataddr
from percolate.utils.env import (
    EMAIL_PROVIDER,
    EMAIL_SMTP_SERVER,
    EMAIL_SMTP_PORT,
    EMAIL_USE_TLS,
    EMAIL_USERNAME,
    EMAIL_PASSWORD,
)


class EmailService:
    """
    Email service for sending HTML emails via SMTP.
    Defaults to Gmail SMTP using the configured service account email.
    """
    def __init__(
        self,
        provider: str = EMAIL_PROVIDER,
        smtp_server: str = EMAIL_SMTP_SERVER,
        smtp_port: int = EMAIL_SMTP_PORT,
        use_tls: bool = EMAIL_USE_TLS,
        username: str = EMAIL_USERNAME,
        password: str = EMAIL_PASSWORD,
        sender_name:str = None
    ):
        self.provider = provider
        self.smtp_server = smtp_server
        self.smtp_port = smtp_port
        self.use_tls = use_tls
        self.username = username
        self.password = password
        self.sender = sender_name 
        
    
    def send_digest_email_from_markdown(self, subject: str,
        markdown_content: str,
        to_addrs: Union[str, List[str]],
        from_addr: Optional[str] = None):
        """
        given markdown send a html email
        """
        import markdown

        html = markdown.markdown(markdown_content, extensions=["tables"])

        return self.send_email(subject=subject, html_content=html, to_addrs=to_addrs,from_addr=from_addr)
    
    def send_email(
        self,
        subject: str,
        html_content: str,
        to_addrs: Union[str, List[str]],
        text_content: Optional[str] = None,
        from_addr: Optional[str] = None,
    ) -> None:
        """
        Send an email with both plain text and HTML content.

        :param subject: Subject of the email.
        :param html_content: HTML body of the email.
        :param to_addrs: Recipient email address or list of addresses.
        :param text_content: Optional plain text body. If not provided, only HTML will be sent.
        :param from_addr: Email address of the sender. Defaults to configured username.
        
        
        For the Gmail provider for example enable 2FA on your account and add
        App Passwords for the account and use email:app_password to authenticate 
        
        """
        if from_addr is None:
            from_addr = self.username
        if isinstance(to_addrs, str):
            to_addrs = [to_addrs]

        # Create multipart message
        message = MIMEMultipart('alternative')
        message['Subject'] = subject
        message['From'] = formataddr((self.sender, from_addr)) if self.sender else from_addr
        message['To'] = ', '.join(to_addrs)

        # Attach plain text part if provided
        if text_content:
            part1 = MIMEText(text_content, 'plain')
            message.attach(part1)

        # Attach HTML part
        part2 = MIMEText(html_content, 'html')
        message.attach(part2)

        # Send via SMTP
        if self.use_tls:
            server = smtplib.SMTP(self.smtp_server, self.smtp_port)
            try:
                server.ehlo()
                server.starttls()
                server.ehlo()
                server.login(self.username, self.password)
                server.sendmail(from_addr, to_addrs, message.as_string())
            finally:
                server.quit()
        else:
            server = smtplib.SMTP_SSL(self.smtp_server, self.smtp_port)
            try:
                server.login(self.username, self.password)
                server.sendmail(from_addr, to_addrs, message.as_string())
            finally:
                server.quit()