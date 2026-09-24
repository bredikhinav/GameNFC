import logging

log = logging.getLogger("fantikpay.mail")


async def send_mail(to: str, subject: str, body: str) -> None:
    """Mail transport placeholder: logs the message. Plug in an SMTP provider before launch."""
    log.info("MAIL to=%s subject=%s\n%s", to, subject, body)
