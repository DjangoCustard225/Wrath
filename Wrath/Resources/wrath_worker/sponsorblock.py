"""SponsorBlock segment lookup for YouTube videos."""
import hashlib
import json
import math
import ssl
import urllib.error
import urllib.parse
import urllib.request

import certifi

from .runtime import check_cancelled

SPONSOR_CATEGORIES = ('sponsor', 'selfpromo', 'interaction', 'intro', 'outro', 'preview', 'music_offtopic', 'filler')
RESPONSE_LIMIT = 2 * 1024 * 1024
UNAVAILABLE = 'SponsorBlock is unavailable. Retry or turn SponsorBlock off.'


def _segment(segment, categories, duration):
    """A clamped (start, end, category), or None when the segment is unusable."""
    if not isinstance(segment, dict):
        return None
    category = segment.get('category')
    if category not in categories or segment.get('actionType', 'skip') != 'skip':
        return None
    try:
        start, end = (float(x) for x in segment['segment'])
        reported_duration = float(segment.get('videoDuration') or 0)
    except (TypeError, ValueError, KeyError):
        return None
    if not all(map(math.isfinite, (start, end, reported_duration))) or not 0 <= start < end:
        return None
    if duration:
        # Segments submitted for a different cut of the video would land in the wrong place.
        if reported_duration and abs(reported_duration - duration) > max(2, duration * .01):
            return None
        end = min(end, duration)
    return (start, end, category) if start < end else None


def parse_sponsor_segments(records, video_id, categories, duration):
    seen = {}  # Ordered, so segments that tie on time keep the server's order.
    for record in records:
        if not isinstance(record, dict) or record.get('videoID') != video_id:
            continue
        if not isinstance(record.get('segments'), list):
            continue
        for segment in record['segments']:
            key = _segment(segment, categories, duration)
            if key:
                seen.setdefault(key)
    result = [dict(start=start, end=end, category=category) for start, end, category in seen]
    return sorted(result, key=lambda x: (x['start'], x['end']))[:500]


def sponsor_segments(info, options):
    if options.get('sponsorMode', 'off') == 'off' or info.get('extractor_key') != 'Youtube':
        return []
    categories = sorted(set(options.get('sponsorCategories', ['sponsor'])).intersection(SPONSOR_CATEGORIES))
    if not categories:
        raise ValueError('Choose at least one SponsorBlock category, or turn SponsorBlock off.')
    video_id = info['id']
    # The hash-prefix endpoint keeps the exact video private from the SponsorBlock server.
    prefix = hashlib.sha256(video_id.encode()).hexdigest()[:4]
    query = urllib.parse.urlencode({'categories': json.dumps(categories), 'actionTypes': '["skip"]'})
    request = urllib.request.Request(f'https://sponsor.ajay.app/api/skipSegments/{prefix}?{query}',
                                     headers={'User-Agent': 'Wrath/1.2.0'})
    check_cancelled()
    try:
        context = ssl.create_default_context(cafile=certifi.where())
        with urllib.request.urlopen(request, timeout=12, context=context) as response:
            data = response.read(RESPONSE_LIMIT + 1)
        if len(data) > RESPONSE_LIMIT:
            raise ValueError('SponsorBlock response was too large.')
        records = json.loads(data)
        if not isinstance(records, list):
            raise ValueError('Invalid SponsorBlock response.')
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return []
        raise ValueError(UNAVAILABLE) from error
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise ValueError(UNAVAILABLE) from error
    check_cancelled()
    return parse_sponsor_segments(records, video_id, categories, info.get('duration'))
