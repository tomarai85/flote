// Sprint 5: OrganizeService のルーティング・URL validation・エラー分類テスト。

import 'dart:convert';

import 'package:flote_desktop/data/prompts.dart';
import 'package:flote_desktop/models/app_settings.dart';
import 'package:flote_desktop/services/organize_service.dart';
import 'package:flote_desktop/services/keychain_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _FakeKeychain extends KeychainService {
  _FakeKeychain({this.claudeKey});
  String? claudeKey;

  @override
  Future<String?> loadClaudeApiKey() async => claudeKey;

  @override
  Future<void> saveClaudeApiKey(String key) async {
    claudeKey = key.isEmpty ? null : key;
  }

  @override
  Future<void> deleteClaudeApiKey() async {
    claudeKey = null;
  }

  @override
  Future<bool> hasClaudeApiKey() async =>
      claudeKey != null && claudeKey!.isNotEmpty;
}

void main() {
  group('isValidOllamaUrl', () {
    // M0 audit fix 2026-05-10: https も allow-list に絞る (旧仕様は https 素通し)
    test('http/https + localhost は OK', () {
      expect(isValidOllamaUrl('http://localhost:11434/api/generate'), isTrue);
      expect(isValidOllamaUrl('http://127.0.0.1:11434/api/generate'), isTrue);
      expect(isValidOllamaUrl('https://localhost:11434'), isTrue);
      expect(isValidOllamaUrl('https://127.0.0.1:11434'), isTrue);
    });

    test('http/https + Tailscale CGNAT (100.64.0.0/10) は OK', () {
      expect(isValidOllamaUrl('http://100.64.0.1:11434'), isTrue);
      expect(isValidOllamaUrl('http://100.100.0.1:11434'), isTrue);
      expect(isValidOllamaUrl('http://100.127.255.255'), isTrue);
      expect(isValidOllamaUrl('https://100.64.0.1:11434'), isTrue);
    });

    test('http/https + 任意 external host は NG (M0 audit fix)', () {
      expect(isValidOllamaUrl('http://8.8.8.8:11434'), isFalse);
      expect(isValidOllamaUrl('http://example.com:11434'), isFalse);
      expect(isValidOllamaUrl('http://100.63.0.1'), isFalse);
      expect(isValidOllamaUrl('http://100.128.0.1'), isFalse);
      // 旧 https 素通しは廃止
      expect(isValidOllamaUrl('https://example.com/api/generate'), isFalse);
      expect(isValidOllamaUrl('https://ollama.internal'), isFalse);
      expect(isValidOllamaUrl('https://attacker.example.com'), isFalse);
    });

    test('不正 URL は NG', () {
      expect(isValidOllamaUrl(''), isFalse);
      expect(isValidOllamaUrl('not a url'), isFalse);
      expect(isValidOllamaUrl('ftp://example.com'), isFalse);
    });
  });

  group('decideRoute', () {
    test('短文 + Claude key なし -> Ollama', () {
      final r = decideRoute(plainText: 'short', hasClaudeKey: false);
      expect(r, OrganizeRoute.ollama);
    });

    test('200 文字超 + Claude key あり -> Claude', () {
      final longText = 'a' * 250;
      final r = decideRoute(plainText: longText, hasClaudeKey: true);
      expect(r, OrganizeRoute.claude);
    });

    test('200 文字超 でも Claude key なし -> Ollama fallback', () {
      final longText = 'a' * 250;
      final r = decideRoute(plainText: longText, hasClaudeKey: false);
      expect(r, OrganizeRoute.ollama);
    });

    test('6 行 + Claude key あり -> Claude', () {
      final r = decideRoute(
        plainText: 'a\nb\nc\nd\ne\nf',
        hasClaudeKey: true,
      );
      expect(r, OrganizeRoute.claude);
    });

    test('5 行以下 -> Ollama', () {
      final r = decideRoute(
        plainText: 'a\nb\nc\nd\ne',
        hasClaudeKey: true,
      );
      expect(r, OrganizeRoute.ollama);
    });
  });

  group('redactApiKey', () {
    test('空文字は <missing>', () {
      expect(redactApiKey(null), '<missing>');
      expect(redactApiKey(''), '<missing>');
    });
    test('本体は伏せて長さだけ出す', () {
      expect(redactApiKey('sk-ant-api03-abc123xyz'),
          'sk-a...(len=22)');
    });
  });

  group('buildPlainDelta', () {
    test('改行なしの plainText を改行付き insert として Delta 化', () {
      final raw = 'こんにちは';
      final encoded = buildPlainDelta(raw);
      final parsed = jsonDecode(encoded) as List;
      expect(parsed.length, 1);
      expect((parsed.first as Map)['insert'], 'こんにちは\n');
    });
    test('末尾改行付き plainText はそのまま', () {
      final raw = 'a\n';
      final parsed = jsonDecode(buildPlainDelta(raw)) as List;
      expect((parsed.first as Map)['insert'], 'a\n');
    });
  });

  group('OrganizeService organize()', () {
    test('無効な Ollama URL -> network エラー', () async {
      final keychain = _FakeKeychain();
      final client = MockClient((req) async => http.Response('', 200));
      final service = OrganizeService(
        keychain: keychain,
        httpClient: client,
      );
      final settings = AppSettings.defaults().copyWith(
        ollamaUrl: 'http://8.8.8.8:11434/api/generate',
      );
      final result = await service.organize(
        plainText: 'hello',
        settings: settings,
      );
      expect(result, isA<OrganizeFailure>());
      final f = result as OrganizeFailure;
      expect(f.kind, OrganizeErrorKind.network);
    });

    test('Ollama 正常応答 -> Success', () async {
      final keychain = _FakeKeychain();
      final client = MockClient((req) async {
        expect(req.url.toString(),
            'http://localhost:11434/api/generate');
        return http.Response(
          jsonEncode({'response': '整理された'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final service = OrganizeService(
        keychain: keychain,
        httpClient: client,
      );
      final result = await service.organize(
        plainText: 'hello',
        settings: AppSettings.defaults(),
      );
      expect(result, isA<OrganizeSuccess>());
      final s = result as OrganizeSuccess;
      expect(s.plainText, '整理された');
    });

    test('Ollama 429 -> rateLimit エラー', () async {
      final keychain = _FakeKeychain();
      final client = MockClient((req) async => http.Response('too many', 429));
      final service = OrganizeService(
        keychain: keychain,
        httpClient: client,
      );
      final result = await service.organize(
        plainText: 'hello',
        settings: AppSettings.defaults(),
      );
      expect(result, isA<OrganizeFailure>());
      expect((result as OrganizeFailure).kind, OrganizeErrorKind.rateLimit);
    });

    test('Ollama 500 -> server エラー', () async {
      final keychain = _FakeKeychain();
      final client = MockClient((req) async => http.Response('boom', 500));
      final service = OrganizeService(
        keychain: keychain,
        httpClient: client,
      );
      final result = await service.organize(
        plainText: 'hello',
        settings: AppSettings.defaults(),
      );
      expect(result, isA<OrganizeFailure>());
      expect((result as OrganizeFailure).kind, OrganizeErrorKind.server);
    });

    test('Ollama レスポンスが parse 不能 -> parse エラー', () async {
      final keychain = _FakeKeychain();
      final client = MockClient((req) async => http.Response('not json', 200));
      final service = OrganizeService(
        keychain: keychain,
        httpClient: client,
      );
      final result = await service.organize(
        plainText: 'hello',
        settings: AppSettings.defaults(),
      );
      expect(result, isA<OrganizeFailure>());
      expect((result as OrganizeFailure).kind, OrganizeErrorKind.parse);
    });

    test('Claude 401 -> key エラー', () async {
      final keychain = _FakeKeychain(claudeKey: 'sk-ant-xxxx');
      final client = MockClient((req) async {
        if (req.url.host.contains('anthropic')) {
          return http.Response('unauthorized', 401);
        }
        return http.Response('{}', 200);
      });
      final service = OrganizeService(
        keychain: keychain,
        httpClient: client,
      );
      final longText = 'a' * 250;
      final result = await service.organize(
        plainText: longText,
        settings: AppSettings.defaults(),
      );
      expect(result, isA<OrganizeFailure>());
      expect((result as OrganizeFailure).kind, OrganizeErrorKind.key);
    });

    test('10000 文字超は truncate して送信 (POST body を検証)', () async {
      final keychain = _FakeKeychain();
      var capturedLength = 0;
      final client = MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final prompt = body['prompt'] as String;
        capturedLength = prompt.length;
        return http.Response(
          jsonEncode({'response': 'ok'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final service = OrganizeService(
        keychain: keychain,
        httpClient: client,
      );
      final longText = 'a' * 15000;
      await service.organize(
        plainText: longText,
        settings: AppSettings.defaults().copyWith(
          promptPreset: PromptPreset.standard,
        ),
      );
      // prompt 本文 + 付属テンプレート + 10000 文字の入力 => 15000 は超えない。
      expect(capturedLength, lessThan(15000));
    });
  });

  group('parseBatchClassifyResponse', () {
    const requests = [
      ClassifyRequest(noteId: 'a', text: '会議の議事録'),
      ClassifyRequest(noteId: 'b', text: '英単語メモ'),
    ];
    const existing = [
      ClassifyGroup(id: 'g1', name: '仕事'),
      ClassifyGroup(id: 'g2', name: '学習'),
    ];

    test('既存グループ名と一致 -> groupID に解決', () {
      final r = parseBatchClassifyResponse(
        responseText:
            '{"assignments": {"a": "仕事", "b": "学習"}}',
        requests: requests,
        existingGroups: existing,
      );
      expect(r.assignments['a'], 'g1');
      expect(r.assignments['b'], 'g2');
      expect(r.newGroupNames, isEmpty);
      expect(r.failures, isEmpty);
    });

    test('新規グループ名 -> __new__: placeholder', () {
      final r = parseBatchClassifyResponse(
        responseText: '{"assignments": {"a": "買い物", "b": "買い物"}}',
        requests: requests,
        existingGroups: existing,
      );
      expect(r.assignments['a'], '__new__:買い物');
      expect(r.assignments['b'], '__new__:買い物');
      expect(r.newGroupNames, ['買い物']);
      expect(r.failures, isEmpty);
    });

    test('JSON 破損 -> 全件 parse 失敗', () {
      final r = parseBatchClassifyResponse(
        responseText: 'not a valid response',
        requests: requests,
        existingGroups: existing,
      );
      expect(r.assignments, isEmpty);
      expect(r.failures.length, 2);
      expect(r.failures['a'], OrganizeErrorKind.parse);
      expect(r.failures['b'], OrganizeErrorKind.parse);
    });

    test('コードフェンスを含む JSON でも parse できる', () {
      final r = parseBatchClassifyResponse(
        responseText:
            '```json\n{"assignments": {"a": "仕事", "b": "仕事"}}\n```',
        requests: requests,
        existingGroups: existing,
      );
      expect(r.assignments['a'], 'g1');
      expect(r.assignments['b'], 'g1');
    });

    test('部分欠落 -> 欠けた noteId は failures', () {
      final r = parseBatchClassifyResponse(
        responseText: '{"assignments": {"a": "仕事"}}',
        requests: requests,
        existingGroups: existing,
      );
      expect(r.assignments['a'], 'g1');
      expect(r.failures['b'], OrganizeErrorKind.parse);
    });

    test('大文字小文字・前後空白を無視して既存グループを照合', () {
      final r = parseBatchClassifyResponse(
        responseText: '{"assignments": {"a": "  仕事  ", "b": "仕事"}}',
        requests: requests,
        existingGroups: existing,
      );
      expect(r.assignments['a'], 'g1');
      expect(r.assignments['b'], 'g1');
    });
  });

  group('OrganizeService batchClassify', () {
    const requests = [
      ClassifyRequest(noteId: 'a', text: 'AI Vision 2025'),
      ClassifyRequest(noteId: 'b', text: '洗剤を買う'),
    ];
    const existing = [
      ClassifyGroup(id: 'g-work', name: '仕事'),
    ];

    test('Claude key あり -> Claude に送信 -> 成功応答で assignments', () async {
      final keychain = _FakeKeychain(claudeKey: 'sk-ant-test');
      final client = MockClient((req) async {
        expect(req.url.host, contains('anthropic'));
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(body['system'], contains('既存グループ一覧'));
        expect(body['system'], contains('仕事'));
        return http.Response(
          jsonEncode({
            'content': [
              {
                'type': 'text',
                'text': '{"assignments": {"a": "仕事", "b": "買い物"}}',
              }
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final service =
          OrganizeService(keychain: keychain, httpClient: client);
      final r = await service.batchClassify(
        requests: requests,
        existingGroups: existing,
        settings: AppSettings.defaults(),
      );
      expect(r.assignments['a'], 'g-work');
      expect(r.assignments['b'], '__new__:買い物');
      expect(r.newGroupNames, ['買い物']);
      expect(r.failures, isEmpty);
    });

    test('Claude 401 -> 全件 failures(key)', () async {
      final keychain = _FakeKeychain(claudeKey: 'sk-ant-bad');
      final client = MockClient((req) async {
        return http.Response('unauthorized', 401);
      });
      final service =
          OrganizeService(keychain: keychain, httpClient: client);
      final r = await service.batchClassify(
        requests: requests,
        existingGroups: existing,
        settings: AppSettings.defaults(),
      );
      expect(r.assignments, isEmpty);
      expect(r.failures.length, 2);
      expect(r.failures['a'], OrganizeErrorKind.key);
    });

    test('Claude key なし -> Ollama fallback で成功', () async {
      final keychain = _FakeKeychain();
      final client = MockClient((req) async {
        expect(req.url.toString(),
            'http://localhost:11434/api/generate');
        return http.Response(
          jsonEncode({
            'response':
                '{"assignments": {"a": "仕事", "b": "その他"}}',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final service =
          OrganizeService(keychain: keychain, httpClient: client);
      final r = await service.batchClassify(
        requests: requests,
        existingGroups: existing,
        settings: AppSettings.defaults(),
      );
      expect(r.assignments['a'], 'g-work');
      expect(r.assignments['b'], '__new__:その他');
      expect(r.failures, isEmpty);
    });

    test('Ollama JSON 応答 parse 失敗 -> 全件 failures(parse)', () async {
      final keychain = _FakeKeychain();
      final client = MockClient((req) async {
        return http.Response(
          jsonEncode({'response': 'sorry I cannot classify'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final service =
          OrganizeService(keychain: keychain, httpClient: client);
      final r = await service.batchClassify(
        requests: requests,
        existingGroups: existing,
        settings: AppSettings.defaults(),
      );
      expect(r.assignments, isEmpty);
      expect(r.failures.length, 2);
      expect(r.failures['a'], OrganizeErrorKind.parse);
      expect(r.failures['b'], OrganizeErrorKind.parse);
    });

    test('Empty requests -> 空結果', () async {
      final keychain = _FakeKeychain();
      final client = MockClient((req) async => http.Response('', 200));
      final service =
          OrganizeService(keychain: keychain, httpClient: client);
      final r = await service.batchClassify(
        requests: const [],
        existingGroups: existing,
        settings: AppSettings.defaults(),
      );
      expect(r.assignments, isEmpty);
      expect(r.newGroupNames, isEmpty);
      expect(r.failures, isEmpty);
    });
  });

  // 並列複数付箋から同時 Generate 時の transient 失敗 (NSURLSession の
  // "The resource could not be ..." 系 / 5xx / 429 / SocketException) を
  // retry で吸収できるかの動作テスト。
  group('OrganizeService retry behavior', () {
    test('Ollama: 5xx を 2 回返した後 200 → success (retry 成功)', () async {
      var count = 0;
      final client = MockClient((_) async {
        count++;
        if (count <= 2) {
          return http.Response('', 503);
        }
        return http.Response(
          jsonEncode({'response': 'recovered'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final service = OrganizeService(
        keychain: _FakeKeychain(),
        httpClient: client,
        retryBaseDelay: Duration.zero,
      );
      final result = await service.testOllama(
        url: 'http://localhost:11434/api/generate',
        model: 'gemma3:12b',
      );
      expect(result, isA<OrganizeSuccess>());
      expect((result as OrganizeSuccess).plainText, 'recovered');
      expect(count, 3);
    });

    test('Ollama: 5xx を 3 回返す → server エラー (max attempts で停止)', () async {
      var count = 0;
      final client = MockClient((_) async {
        count++;
        return http.Response('boom', 503);
      });
      final service = OrganizeService(
        keychain: _FakeKeychain(),
        httpClient: client,
        retryBaseDelay: Duration.zero,
      );
      final result = await service.testOllama(
        url: 'http://localhost:11434/api/generate',
        model: 'gemma3:12b',
      );
      expect(result, isA<OrganizeFailure>());
      expect((result as OrganizeFailure).kind, OrganizeErrorKind.server);
      expect(count, 3);
    });

    test('Ollama: 429 を 1 回返した後 200 → success (rate limit retry)', () async {
      var count = 0;
      final client = MockClient((_) async {
        count++;
        if (count == 1) {
          return http.Response('', 429);
        }
        return http.Response(
          jsonEncode({'response': 'ok'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final service = OrganizeService(
        keychain: _FakeKeychain(),
        httpClient: client,
        retryBaseDelay: Duration.zero,
      );
      final result = await service.testOllama(
        url: 'http://localhost:11434/api/generate',
        model: 'gemma3:12b',
      );
      expect(result, isA<OrganizeSuccess>());
      expect(count, 2);
    });

    test('Claude: 401 (auth) は retry しない (即 key エラー)', () async {
      var count = 0;
      final client = MockClient((_) async {
        count++;
        return http.Response('unauthorized', 401);
      });
      final service = OrganizeService(
        keychain: _FakeKeychain(claudeKey: 'sk-ant-test'),
        httpClient: client,
        retryBaseDelay: Duration.zero,
      );
      final result = await service.testClaude(apiKey: 'sk-ant-test');
      expect(result, isA<OrganizeFailure>());
      expect((result as OrganizeFailure).kind, OrganizeErrorKind.key);
      expect(count, 1);
    });

    test('Claude: ClientException を 2 回 throw した後 200 → success', () async {
      var count = 0;
      final client = MockClient((_) async {
        count++;
        if (count <= 2) {
          throw http.ClientException(
            'The resource could not be loaded',
          );
        }
        return http.Response(
          jsonEncode({
            'content': [
              {'type': 'text', 'text': '整理後'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final service = OrganizeService(
        keychain: _FakeKeychain(claudeKey: 'sk-ant-test'),
        httpClient: client,
        retryBaseDelay: Duration.zero,
      );
      final result = await service.testClaude(apiKey: 'sk-ant-test');
      expect(result, isA<OrganizeSuccess>());
      expect((result as OrganizeSuccess).plainText, '整理後');
      expect(count, 3);
    });

    test('Claude: ClientException を 3 回連続 → network エラー (retry 力尽きる)',
        () async {
      var count = 0;
      final client = MockClient((_) async {
        count++;
        throw http.ClientException(
          'The resource could not be loaded',
        );
      });
      final service = OrganizeService(
        keychain: _FakeKeychain(claudeKey: 'sk-ant-test'),
        httpClient: client,
        retryBaseDelay: Duration.zero,
      );
      final result = await service.testClaude(apiKey: 'sk-ant-test');
      expect(result, isA<OrganizeFailure>());
      expect((result as OrganizeFailure).kind, OrganizeErrorKind.network);
      expect(count, 3);
    });
  });

  // M0 audit Wave 4 (138s UX): cancelCurrent() で retry を断ち切り、
  // OrganizeFailure(cancelled) が返ることを verify。
  group('OrganizeService cancel behavior', () {
    test('5xx 後 backoff 中に cancelCurrent → cancelled エラー (retry 断ち切り)',
        () async {
      var count = 0;
      late OrganizeService service;
      final client = MockClient((_) async {
        count++;
        if (count == 1) {
          // 1 回目失敗 → backoff 中に cancel をシミュレート (次 attempt 前に
          // _retryHttpRequest が cancel check して exit)
          service.cancelCurrent();
          return http.Response('', 503);
        }
        return http.Response(
          jsonEncode({'response': 'should not reach here'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      service = OrganizeService(
        keychain: _FakeKeychain(),
        httpClient: client,
        retryBaseDelay: Duration.zero,
      );
      final result = await service.testOllama(
        url: 'http://localhost:11434/api/generate',
        model: 'gemma3:12b',
      );
      expect(result, isA<OrganizeFailure>());
      expect((result as OrganizeFailure).kind, OrganizeErrorKind.cancelled);
      expect(count, 1, reason: 'cancel 後に 2 回目を呼ぶべきでない');
    });

    test('organize() 呼出時に cancel flag は自動リセット', () async {
      // 前回 cancel 後、次回 organize() で flag が reset されて通常動作するか
      var count = 0;
      late OrganizeService service;
      final client = MockClient((_) async {
        count++;
        return http.Response(
          jsonEncode({'response': 'ok'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      service = OrganizeService(
        keychain: _FakeKeychain(),
        httpClient: client,
        retryBaseDelay: Duration.zero,
      );
      // 事前に cancel 立てる
      service.cancelCurrent();
      // organize() 内で _resetCancel() されて通常完走するはず
      final result = await service.organize(
        plainText: 'hello',
        settings: AppSettings.defaults(),
      );
      expect(result, isA<OrganizeSuccess>());
      expect(count, 1);
    });
  });
}
