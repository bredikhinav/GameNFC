"""Page opened when a card is tapped on a phone without the app: /c/{token}."""

from fastapi import APIRouter
from fastapi.responses import HTMLResponse

router = APIRouter(include_in_schema=False)

PAGE = """<!doctype html>
<html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ФантикПэй</title>
<style>
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
font-family:system-ui,-apple-system,sans-serif;background:#faf6ee;color:#1f2230}
main{max-width:360px;padding:32px 24px;text-align:center}
.logo{width:72px;height:72px;border-radius:50%;background:#f2b33d;display:inline-flex;
align-items:center;justify-content:center;font-size:36px;font-weight:800}
h1{font-size:28px;margin:16px 0 8px}p{color:#5c5d66;line-height:1.5}
a.btn{display:inline-block;margin-top:16px;padding:14px 24px;border-radius:14px;
background:#0f6b5a;color:#fff;text-decoration:none;font-weight:600}
small{display:block;margin-top:24px;color:#8a8b93}
</style></head><body><main>
<div class="logo">Ф</div>
<h1>ФантикПэй</h1>
<p>Эта карта — игровой кошелёк ребёнка в ФантикПэй. Монеты в игре виртуальные:
их нельзя купить или обменять на деньги.</p>
<p>Нашли карту? Верните её владельцу или ведущему игры.</p>
<a class="btn" href="fantikpay://card">Открыть приложение</a>
<small>fantikpay.ru</small>
</main></body></html>"""


@router.get("/c/{token}", response_class=HTMLResponse)
async def card_page(token: str) -> str:
    # Deliberately shows nothing about the owner: anyone can tap a found card.
    return PAGE
