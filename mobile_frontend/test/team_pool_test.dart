import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:mobile_frontend/localization/app_strings.dart';
import 'package:mobile_frontend/localization/locale_manager.dart';
import 'package:mobile_frontend/services/api_service.dart';

/// Covers the team-pool additions: the strings the pool UI renders, and the
/// error handling the claim race depends on.
void main() {
  // Every key the pool / release / transfer UI passes to tr(). tr() falls back
  // to returning the key itself when it is missing, so a typo here does not
  // crash — it silently prints "worker_accept_task" on the button. These
  // assertions are what turn that into a test failure instead.
  const poolKeys = <String>[
    'home_worker_team_pool',
    'home_worker_team_pool_hint',
    'home_stat_pool',
    'home_stat_mine',
    'worker_accept_task',
    'worker_claiming',
    'worker_claim_success',
    'worker_claim_taken',
    'worker_claim_failed',
    'worker_pool_released',
    'worker_pool_title',
    'worker_pool_body',
    'worker_release_task',
    'worker_release_title',
    'worker_release_body',
    'worker_release_reason',
    'worker_release_success',
    'worker_release_failed',
    'worker_transfer_task',
    'worker_transfer_title',
    'worker_transfer_body',
    'worker_transfer_success',
    'worker_transfer_failed',
    'common_submit',
    'common_cancel',
  ];

  group('team pool localization', () {
    tearDown(() => LocaleManager.localeNotifier.value = 'en');

    test('every pool string resolves in English', () {
      LocaleManager.localeNotifier.value = 'en';
      for (final key in poolKeys) {
        expect(tr(key), isNot(key),
            reason: '$key has no English translation — the UI would show the raw key');
      }
    });

    test('every pool string resolves in Malay', () {
      LocaleManager.localeNotifier.value = 'bm';
      for (final key in poolKeys) {
        final value = tr(key);
        expect(value, isNot(key), reason: '$key is missing entirely');
        // tr() falls back to English when a locale is absent; catch that too,
        // otherwise half the pool UI silently stays English in Malay mode.
        LocaleManager.localeNotifier.value = 'en';
        final english = tr(key);
        LocaleManager.localeNotifier.value = 'bm';
        expect(value, isNot(english),
            reason: '$key has no Malay translation — it fell back to English');
      }
    });

    test('release counter interpolates its placeholder', () {
      LocaleManager.localeNotifier.value = 'en';
      expect(trCount('worker_pool_released', 2), contains('2'));
      expect(trCount('worker_pool_released', 2), isNot(contains('{n}')));
    });
  });

  group('claim error handling', () {
    // The pool UI distinguishes "someone beat you to it" (409) from a real
    // failure, and that hinges on reading the server's detail field.
    test('errorDetail surfaces the server message', () {
      final res = http.Response(
        jsonEncode({'detail': 'This task was already claimed by another worker.'}),
        409,
      );
      expect(ApiService.errorDetail(res, 'fallback'),
          'This task was already claimed by another worker.');
    });

    test('errorDetail falls back on a non-JSON body', () {
      expect(ApiService.errorDetail(http.Response('<html>502</html>', 502), 'fallback'),
          'fallback');
    });

    test('errorDetail falls back when detail is not a string', () {
      // FastAPI validation errors return a list of objects under `detail`;
      // rendering that raw would put JSON on a snackbar.
      final res = http.Response(jsonEncode({'detail': [{'msg': 'bad'}]}), 422);
      expect(ApiService.errorDetail(res, 'fallback'), 'fallback');
    });
  });
}
