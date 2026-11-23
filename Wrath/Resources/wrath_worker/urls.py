"""URL and host checks."""
import urllib.parse


def domain_matches(host, domains):
    return any(host == domain or host.endswith('.' + domain) for domain in domains)


def hostname(url):
    """The lowercased host of a URL, or None when it cannot be parsed."""
    try:
        return (urllib.parse.urlparse(url).hostname or '').lower()
    except (TypeError, ValueError):
        return None


def is_youtube_url(url):
    host = hostname(url)
    return host is not None and domain_matches(host, ('youtube.com', 'youtu.be', 'youtube-nocookie.com'))


def is_web_url(url):
    """An absolute http(s) URL without whitespace."""
    if not isinstance(url, str) or any(character.isspace() for character in url):
        return False
    try:
        parsed = urllib.parse.urlparse(url)
    except ValueError:
        return False
    return parsed.scheme in ('https', 'http') and bool(parsed.hostname)


def thumbnail_url(info):
    candidates = [info.get('thumbnail')]
    candidates.extend(item.get('url') for item in reversed(info.get('thumbnails') or []) if isinstance(item, dict))
    return next((url for url in candidates if is_web_url(url)), None)
