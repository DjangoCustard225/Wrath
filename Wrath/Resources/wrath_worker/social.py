"""Reddit and Instagram sessions saved by the app, and account-aware error messages.

Social-site session cookies stay isolated from YouTube and other hosts. No browser-wide
cookie file or arbitrary Cookie HTTP header is accepted here.
"""
import io
import re
import urllib.parse

from .runtime import safe_message
from .urls import domain_matches, hostname

SOCIAL_DOMAINS = {'reddit': ('reddit.com', 'redd.it'), 'instagram': ('instagram.com', 'instagr.am')}
INVALID_COOKIES = 'Could not read saved social-media cookies. Sign in again in Settings > Cookies.'


def _platform_domains(url, access):
    """The saved platform's domains when the URL is an https link on that platform, else None."""
    platform = access.get('platform')
    domains = SOCIAL_DOMAINS.get(platform) if isinstance(platform, str) else None
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != 'https' or not domains or not domain_matches((parsed.hostname or '').lower(), domains):
        return None
    return domains


def _printable_ascii(text):
    return not any(ord(c) < 32 or ord(c) >= 127 for c in text)


def social_user_agent(url, access):
    if not isinstance(access, dict) or not _platform_domains(url, access):
        return None
    agent = access.get('userAgent')
    if agent is not None and (not isinstance(agent, str) or not agent or len(agent) > 1024
                              or not _printable_ascii(agent)):
        raise ValueError('The saved social-media User-Agent is invalid. Reset it in Settings.')
    return agent


def _cookie_row(original, domains):
    """A validated Netscape cookie row, None for another site's cookie, or ValueError."""
    line = original.removeprefix('#HttpOnly_')
    if not line or line.startswith('#'):
        return None
    fields = line.split('\t')
    if len(fields) != 7:
        raise ValueError(INVALID_COOKIES)
    domain = fields[0].lower()
    if not domain_matches(domain.removeprefix('.'), domains):
        # Even a manually constructed request cannot transfer credentials.
        return None
    if (fields[1] not in ('TRUE', 'FALSE') or fields[3] not in ('TRUE', 'FALSE')
            or (fields[1] == 'TRUE') != domain.startswith('.')
            or not fields[2].startswith('/') or not fields[5]
            or not re.fullmatch(r'[0-9]{0,19}', fields[4])
            or int(fields[4] or '0') > 2**63 - 1
            or not all(_printable_ascii(field) for field in fields)
            or any(c in fields[5] for c in ' ;=') or ';' in fields[6]):
        raise ValueError(INVALID_COOKIES)
    fields[0] = domain
    fields[4] = fields[4] or '0'
    return ('#HttpOnly_' if original.startswith('#HttpOnly_') else '') + '\t'.join(fields)


def social_cookie_jar(url, access):
    if not isinstance(access, dict):
        raise ValueError(INVALID_COOKIES)
    if not access:
        return []
    domains = _platform_domains(url, access)
    if not domains:
        # A caller cannot attach a stored social session to another website.
        return []
    text = access.get('cookies')
    if text is None:
        return []
    if not isinstance(text, str) or len(text.encode('utf-8')) > 512 * 1024:
        raise ValueError(INVALID_COOKIES)
    lines = text.removeprefix('﻿').replace('\r\n', '\n').replace('\r', '\n').split('\n')
    if not lines or lines[0] not in ('# Netscape HTTP Cookie File', '# HTTP Cookie File'):
        raise ValueError(INVALID_COOKIES)
    rows = [row for row in (_cookie_row(line, domains) for line in lines[1:]) if row]
    from yt_dlp.cookies import YoutubeDLCookieJar
    jar = YoutubeDLCookieJar()
    try:
        jar.load(io.StringIO('# Netscape HTTP Cookie File\n' + '\n'.join(rows) + '\n'), ignore_expires=True)
    except Exception:
        raise ValueError(INVALID_COOKIES) from None
    return [cookie for cookie in jar if not cookie.is_expired()]


def user_error(error, url):
    """The message shown to the user. DownloadStore.recordFailure matches the account phrases below."""
    message = safe_message(error) or 'Unable to access this media.'
    host = hostname(url)
    site = next((name for name, domains in SOCIAL_DOMAINS.items() if host and domain_matches(host, domains)), None)
    if not site:
        return message
    site = site.title()
    if re.search(r'(?:log\s?in|sign\s?in|cookies|authentication|account required|private)', message, re.I):
        reply = (f'{site} may require an authenticated session or access permission. '
                 f'Connect or reconnect {site} in Settings > Cookies, then retry.')
    elif re.search(r'(?:\b429\b|rate.?limit|too many requests)', message, re.I):
        reply = f'{site} is rate-limiting requests. Try again later.'
    elif re.search(r'(?:\b403\b|forbidden|access denied|challenge|captcha)', message, re.I):
        reply = (f'{site} denied access. Check that the link opens in your browser '
                 'and reconnect your account if needed.')
    else:
        return message
    return f'{reply} ({message})'[:1200]
