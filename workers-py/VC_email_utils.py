import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
import os
import threading
import logging
import traceback

logger = logging.getLogger(__name__)

def send_error_notification(error_message: str, context: dict = None):
    """
    Sends an email notification about an error asynchronously.
    
    Args:
        error_message: The error message or exception string
        context: Dictionary containing contextual info (session_id, input, etc.)
    """
    def _send():
        try:
            # Get credentials from environment variables
            sender_email = os.getenv("EMAIL_USER")
            receiver_email = os.getenv("EMAIL_RECEIVER") # Admin email to receive alerts
            password = os.getenv("EMAIL_PASSWORD")
            smtp_server = os.getenv("EMAIL_HOST", "smtp.gmail.com")
            smtp_port_str = os.getenv("EMAIL_PORT", "587")
            
            # Basic validation
            if not all([sender_email, receiver_email, password]):
                missing = []
                if not sender_email: missing.append("EMAIL_USER")
                if not receiver_email: missing.append("EMAIL_RECEIVER")
                if not password: missing.append("EMAIL_PASSWORD")
                logger.warning(f"Email configuration missing ({', '.join(missing)}). Skipping error notification.")
                return

            try:
                smtp_port = int(smtp_port_str)
            except ValueError:
                logger.error(f"Invalid EMAIL_PORT: {smtp_port_str}")
                return

            # Support multiple receivers (comma separated)
            receivers = [r.strip() for r in receiver_email.split(',') if r.strip()]

            # Construct email body
            subject = f"⚠️ Error Report from Capmap!"
            
            body_parts = [
                f"An error occurred in the application.",
                f"",
                f"🔴 Error:",
                f"{error_message}",
                f""
            ]
            
            if context:
                body_parts.append("📋 Context:")
                for key, value in context.items():
                    body_parts.append(f"- {key}: {value}")
                body_parts.append("")
                
            # Add environment info if available
            env = os.getenv("FLASK_ENV", "production") 
            body_parts.append(f"Environment: {env}")
            
            email_body = "\n".join(body_parts)

            msg = MIMEMultipart()
            msg['From'] = sender_email
            msg['To'] = ", ".join(receivers)
            msg['Subject'] = subject
            msg.attach(MIMEText(email_body, 'plain'))

            # Connect and send
            server = smtplib.SMTP(smtp_server, smtp_port)
            server.starttls()
            server.login(sender_email, password)
            text = msg.as_string()
            server.sendmail(sender_email, receivers, text)
            server.quit()
            
            logger.info(f"Error notification email sent to {', '.join(receivers)}")
            
        except Exception as e:
            # Fail silently regarding the logic flow, but log the error
            logger.error(f"Failed to send error notification email: {e}")
            logger.debug(traceback.format_exc())

    # Run in separate thread
    thread = threading.Thread(target=_send)
    thread.daemon = True
    thread.start()
