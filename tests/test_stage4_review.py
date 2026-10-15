"""Behavior regressions for the review after native Stage 4; no live calls."""
import copy
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from stage0.core import CheckError
from stage0.providers import ArtworkClient, artwork_image_url, format_with_groq

RECORDING = '11111111-1111-4111-8111-111111111111'
RELEASE = '22222222-2222-4222-8222-222222222222'


class LegacyArtworkReview(unittest.TestCase):
    def responses(self):
        recording = {'id': RECORDING, 'title': 'Moonlit Train',
                     'artist-credit': [{'artist': {'name': 'Mira Vale'}}]}
        return [
            {'count': 1, 'recordings': [recording]},
            {**recording, 'releases': [{'id': RELEASE, 'title': 'Fictional album'}]},
            {'release': 'https://musicbrainz.org/release/' + RELEASE, 'images': [
                {'front': True, 'approved': True, 'image': 'http://archive.org/fictional.jpg'}]},
        ]

    def lookup(self, responses):
        client = ArtworkClient.__new__(ArtworkClient)
        with patch.object(client, 'json', side_effect=responses), \
                patch.object(client, 'fetch', return_value=b'fictional image') as fetch, \
                patch('stage0.providers.normalize_image', return_value=b'normalized'):
            value = client.lookup('Moonlit Train', ['Mira Vale'], 'Fictional album')
            return value, fetch

    def test_known_front_legacy_link_uses_only_https(self):
        (image, provenance), fetch = self.lookup(self.responses())
        self.assertEqual(image, b'normalized')
        self.assertEqual(provenance['recording_id'], RECORDING)
        fetch.assert_called_once_with('https://archive.org/fictional.jpg', 5 * 1024 * 1024)
        for value in ['http://evil.example/image', 'http://archive.org:8080/image',
                      'http://user:password@archive.org/image', 'https://archive.org/image#fragment']:
            with self.assertRaises(CheckError):
                artwork_image_url(value)

    def test_incomplete_search_and_release_lists_cannot_guess_a_cover(self):
        for part in ['search', 'release']:
            responses = self.responses()
            if part == 'search':
                responses[0]['count'] = 6
            else:
                responses[1]['releases'].extend(
                    {'id': RELEASE, 'title': 'Other album'} for _ in range(24))
            with self.assertRaises(CheckError) as raised:
                self.lookup(responses)
            self.assertEqual(raised.exception.code, 'ARTWORK_MATCH_UNCERTAIN')

    def test_changed_recording_identity_and_credits_are_rejected(self):
        for field, value in [('id', RELEASE), ('title', 'Another song'),
                             ('artist-credit', [{'artist': {'name': 'Wrong artist'}}])]:
            responses = self.responses()
            responses[1][field] = value
            with self.assertRaises(CheckError):
                self.lookup(responses)

    def test_multiple_fronts_and_another_release_index_are_rejected(self):
        for mode in ['fronts', 'release']:
            responses = self.responses()
            if mode == 'fronts':
                responses[2]['images'].append(copy.deepcopy(responses[2]['images'][0]))
            else:
                responses[2]['release'] = 'https://musicbrainz.org/release/' + RECORDING
            with self.assertRaises(CheckError):
                self.lookup(responses)

    def test_invalid_recording_id_stops_before_followup_requests(self):
        responses = self.responses()
        responses[0]['recordings'][0]['id'] = '../release?query=untrusted'
        client = ArtworkClient.__new__(ArtworkClient)
        with patch.object(client, 'json', side_effect=responses) as request:
            with self.assertRaises(CheckError):
                client.lookup('Moonlit Train', ['Mira Vale'])
            self.assertEqual(request.call_count, 1)


class LegacyNamingReview(unittest.TestCase):
    def response(self, reason='stop', refusal=None):
        metadata = {'track_id': 'fixture', 'title': 'Moonlit Train', 'artists': ['Mira Vale'],
                    'featured_artists': [], 'album': None, 'version': None,
                    'needs_review': False, 'reason': None}
        return SimpleNamespace(choices=[SimpleNamespace(finish_reason=reason,
            message=SimpleNamespace(content=json.dumps({'tracks': [metadata]}), refusal=refusal))], usage=None)

    def test_prompt_redaction_keeps_the_original_fallback_and_stable_id(self):
        title = 'Source (Live) gsk_syntheticfixturesecret https://private.example/link'
        with patch.dict('os.environ', {'GROQ_API_KEY': 'synthetic-key'}), patch('groq.Groq') as factory:
            client = factory.return_value.__enter__.return_value
            client.chat.completions.create.return_value = self.response()
            result, evidence = format_with_groq([{'track_id': 'fixture', 'title': title,
                'uploader': 'gsk_syntheticfixturesecret https://private.example/channel'}])
            content = client.chat.completions.create.call_args.kwargs['messages'][1]['content']
            self.assertNotIn('gsk_syntheticfixturesecret', content)
            self.assertNotIn('https://private.example', content)
            self.assertEqual(json.loads(content)['source_records'][0]['track_id'], 'fixture')
            self.assertEqual(result['fixture']['title'], title)
            self.assertTrue(result['fixture']['needs_review'])
            self.assertEqual(evidence['prompt_version'], 'stage0-v3')

    def test_refused_or_truncated_even_valid_json_never_applies_metadata(self):
        for reason, refusal in [('length', None), ('stop', 'refused')]:
            with patch.dict('os.environ', {'GROQ_API_KEY': 'synthetic-key'}), patch('groq.Groq') as factory:
                client = factory.return_value.__enter__.return_value
                client.chat.completions.create.return_value = self.response(reason, refusal)
                with self.assertRaises(CheckError) as error:
                    format_with_groq([{'track_id': 'fixture', 'title': 'Moonlit Train'}])
                self.assertEqual(error.exception.code, 'AI_COMPLETION_INVALID')


if __name__ == '__main__':
    unittest.main()
