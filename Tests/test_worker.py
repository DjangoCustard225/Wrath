"""Unit tests for the pure helpers in the bundled Python worker.

Run after `python3 Scripts/Prepare.py`:  python3 -m unittest discover -s Tests
"""
import sys
import types
import unittest
from pathlib import Path

RESOURCES = Path(__file__).resolve().parent.parent / 'Wrath' / 'Resources'
sys.path[:0] = [str(RESOURCES), str(RESOURCES / 'packages')]
# The native bridge exists only inside the app. Long-running helpers poll it for cancellation.
native = types.ModuleType('wrath_native')
native.cancelled = lambda context=None: False
sys.modules.setdefault('wrath_native', native)

import wrath_worker as worker  # noqa: E402


class SubtitleTests(unittest.TestCase):
    def test_parses_webvtt_and_srt_timestamps(self):
        content = 'WEBVTT\n\n00:01.000 --> 00:02.500\nHello\n\n01:00:01,000 --> 01:00:02,000\nBye\n'
        cues = worker.parse_subtitle_cues(content, 'vtt')
        self.assertEqual(cues, [
            {'start': 1.0, 'end': 2.5, 'text': 'Hello'},
            {'start': 3601.0, 'end': 3602.0, 'text': 'Bye'},
        ])


class SponsorBlockTests(unittest.TestCase):
    def records(self, *segments, video_id='abc'):
        return [{'videoID': video_id, 'segments': list(segments)}]

    def test_keeps_selected_categories_and_removes_duplicates(self):
        records = self.records(
            {'segment': [1, 2], 'category': 'sponsor'},
            {'segment': [1, 2], 'category': 'sponsor'},
            {'segment': [3, 4], 'category': 'intro'},
        )
        segments = worker.parse_sponsor_segments(records, 'abc', ['sponsor'], 10)
        self.assertEqual(segments, [{'start': 1.0, 'end': 2.0, 'category': 'sponsor'}])

    def test_clamps_to_the_video_and_skips_mismatched_records(self):
        records = self.records({'segment': [3, 20], 'category': 'intro'})
        self.assertEqual(worker.parse_sponsor_segments(records, 'abc', ['intro'], 10)[0]['end'], 10)
        self.assertEqual(worker.parse_sponsor_segments(records, 'other', ['intro'], 10), [])
        stale = self.records({'segment': [1, 2], 'category': 'intro', 'videoDuration': 99})
        self.assertEqual(worker.parse_sponsor_segments(stale, 'abc', ['intro'], 10), [])


class SelectorTests(unittest.TestCase):
    def test_builds_the_standard_expressions(self):
        self.assertEqual(worker.selector('video', 1080), 'bv*[height<=?1080]+ba/b[height<=?1080]')
        self.assertEqual(worker.selector('video', 720, exact_height=True), 'bv*[height=720]+ba/b[height=720]')
        self.assertEqual(worker.selector('audio', 0, audio_codec='opus'), 'ba[acodec~="^opus"]/b[acodec~="^opus"]')

    def test_constrains_codecs(self):
        expression = worker.selector('video', 0, video_codec='h264', audio_codec='aac')
        self.assertIn('[vcodec~="^(avc1|h264)"]', expression)
        self.assertIn('[acodec~="^(mp4a|aac)"]', expression)


class SizeEstimateTests(unittest.TestCase):
    def test_prefers_declared_sizes_then_bitrate(self):
        self.assertEqual(worker.estimated_track_bytes({'filesize': 500}, 10), 500)
        self.assertEqual(worker.estimated_track_bytes({'tbr': 8}, 10), 10_000)
        self.assertIsNone(worker.estimated_track_bytes({}, 10))

    def test_audio_from_a_combined_stream_ignores_video_bytes(self):
        combined = {'vcodec': 'avc1', 'filesize': 9_999, 'abr': 16}
        self.assertEqual(worker.estimated_track_bytes(combined, 10, audio_only=True), 20_000)


class HostTests(unittest.TestCase):
    def test_matches_only_real_subdomains(self):
        self.assertTrue(worker.is_youtube_url('https://m.youtube.com/watch?v=x'))
        self.assertFalse(worker.is_youtube_url('https://youtube.com.evil.test/watch?v=x'))
        self.assertTrue(worker.domain_matches('old.reddit.com', ('reddit.com',)))
        self.assertFalse(worker.domain_matches('notreddit.com', ('reddit.com',)))


class UserErrorTests(unittest.TestCase):
    # DownloadStore.recordFailure offers "Connect account" when it finds these phrases.
    def test_account_errors_keep_the_phrases_the_app_recognizes(self):
        login = worker.user_error(Exception('Login required'), 'https://www.instagram.com/p/x')
        self.assertIn('may require an authenticated session', login)
        denied = worker.user_error(Exception('HTTP Error 403: Forbidden'), 'https://www.reddit.com/r/x')
        self.assertIn('denied access', denied)

    def test_other_sites_keep_the_original_message(self):
        self.assertEqual(worker.user_error(Exception('Login required'), 'https://example.com/v'), 'Login required')


if __name__ == '__main__':
    unittest.main()
