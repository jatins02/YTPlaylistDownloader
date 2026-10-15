import 'package:flutter_test/flutter_test.dart';

import '../tool/enrichment_live.dart'
    show artworkAcceptancePassed, namingQualityPassed;

void main() {
  test(
    'live naming acceptance rejects empty results and a wrong known title',
    () {
      expect(namingQualityPassed([]), isFalse);
      final known = <String, Object?>{
        'valid_id_mapping': true,
        'version_details_preserved': true,
        'known_artist_identified': true,
        'known_title_identified': false,
      };
      expect(namingQualityPassed([known]), isFalse);
      known['known_title_identified'] = true;
      expect(namingQualityPassed([known]), isTrue);
      known['version_details_preserved'] = false;
      expect(namingQualityPassed([known]), isFalse);
    },
  );

  test('artwork uncertainty cannot satisfy the live known-cover gate', () {
    expect(artworkAcceptancePassed({'artwork': 'artworkUncertain'}), isFalse);
    final cover = <String, Object?>{
      'identity_verified': true,
      'image_verified': true,
      'embedded_cover_verified': true,
      'full_audio_decode_verified': false,
    };
    expect(artworkAcceptancePassed(cover), isFalse);
    cover['full_audio_decode_verified'] = true;
    expect(artworkAcceptancePassed(cover), isTrue);
    cover['identity_verified'] = false;
    expect(artworkAcceptancePassed(cover), isFalse);
  });
}
