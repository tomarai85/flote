// AI Organize サービス (Sprint 5 Feature 5.1)。
//
// - 文字数 200+ または 5 行超 -> Claude Sonnet 4.5
// - それ以外 -> Ollama (gemma3:12b、ローカル)
// - プロンプトは AppSettings.promptPreset (concise/standard/custom) に従う
// - 10000 文字超は truncate
// - エラー分類: key / network / parse / server / rateLimit
// - Ollama URL 検証: https / localhost / Tailscale CGNAT (100.64.0.0/10) のみ
// - Claude は Messages API (https://api.anthropic.com/v1/messages, model claude-sonnet-4-5-20250929)
//
// セキュリティ:
// - API キーはログ出力時に常に redact (先頭 4 文字 + "..." 形式)。本体は一切出さない
// - HTTP body は 200 文字超なら切詰めたエラーメッセージに格納

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../data/prompts.dart';
import '../models/app_settings.dart';
import 'keychain_service.dart';

/// Organize 実行結果 (成功 / 失敗)。
sealed class OrganizeResult {
  const OrganizeResult();
}

class OrganizeSuccess extends OrganizeResult {
  const OrganizeSuccess({required this.plainText, required this.richText});

  /// 整理後のプレーンテキスト。
  final String plainText;

  /// 整理後の rich text (Delta JSON 文字列)。
  /// Ollama/Claude は通常プレーンテキストを返すので、OrganizeService 内で
  /// `[{"insert":"...\n"}]` 形式の最小 Delta に包んで返す。
  final String richText;
}

class OrganizeFailure extends OrganizeResult {
  const OrganizeFailure(this.kind, this.message);
  final OrganizeErrorKind kind;
  final String message;
}

/// エラー分類 (現行 SwiftUI 版踏襲の 5 分類 + cancelled)。
/// cancelled は M0 audit Wave 4 で追加: ユーザーが UI cancel button を
/// 押した場合の expected failure (network / parse 等の真エラーと区別)。
enum OrganizeErrorKind { key, network, parse, server, rateLimit, cancelled }

/// User-cancellation を retry / call layer 越しに伝播する内部例外。
/// `_retryHttpRequest` が attempt 前 / 完了後に check し、`cancelled` 状態
/// なら throw → caller (`_callOllama` / `_callClaude`) が catch して
/// `OrganizeFailure(cancelled, ...)` を返す。
class _OrganizeCancelledException implements Exception {
  const _OrganizeCancelledException();
}

/// OrganizeService が実行時に使用する HTTP クライアント。テストで差し替え可能。
typedef HttpPost = Future<http.Response> Function(
  Uri url,
  Map<String, String> headers,
  Object? body, {
  Duration? timeout,
});

/// Ollama URL が許可パターンに合致するか判定。
///
/// 許可 (M0 audit fix 2026-05-10: https も http と同じ allow-list に絞る):
/// - localhost / 127.0.0.1
/// - Tailscale CGNAT (100.64.0.0/10)
///
/// scheme は http または https。
/// 任意 https external host は **拒否** (旧仕様では https は素通しだったが、
/// settings.json 改竄 / social engineering で外部 host へ note plaintext を
/// 送信される risk があったため allow-list に統一)。
bool isValidOllamaUrl(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return false;
  }
  Uri? parsed;
  try {
    parsed = Uri.parse(trimmed);
  } catch (_) {
    return false;
  }
  if (!parsed.hasScheme) {
    return false;
  }
  if (parsed.scheme != 'http' && parsed.scheme != 'https') {
    return false;
  }
  final host = parsed.host.toLowerCase();
  if (host.isEmpty) {
    return false;
  }
  if (host == 'localhost' || host == '127.0.0.1') {
    return true;
  }
  return _isTailscaleCgnatHost(host);
}

/// 100.64.0.0/10 (100.64.0.0 - 100.127.255.255) の範囲に収まるか。
bool _isTailscaleCgnatHost(String host) {
  final parts = host.split('.');
  if (parts.length != 4) {
    return false;
  }
  final numbers = <int>[];
  for (final p in parts) {
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 255) {
      return false;
    }
    numbers.add(n);
  }
  if (numbers[0] != 100) {
    return false;
  }
  return numbers[1] >= 64 && numbers[1] <= 127;
}

/// API キーのログ表示用マスク。キー全体は常に伏せ、先頭 4 文字 + 長さのみ。
String redactApiKey(String? key) {
  if (key == null || key.isEmpty) {
    return '<missing>';
  }
  final prefix = key.length >= 4 ? key.substring(0, 4) : key;
  return '$prefix...(len=${key.length})';
}

/// プレーンテキストを「最小 Delta」(1 insert 要素) として文字列化する。
String buildPlainDelta(String plainText) {
  final safe = plainText.endsWith('\n') ? plainText : '$plainText\n';
  return jsonEncode([
    {'insert': safe},
  ]);
}

/// Ollama / Claude ルーティングを判定する。
/// - text (整理対象の plainText) の文字数 200+ または 5 行超で Claude 推奨
/// - それ以外は Ollama
/// hasClaudeKey が false なら常に Ollama を使う (ルーティング強制フォールバック)。
OrganizeRoute decideRoute({
  required String plainText,
  required bool hasClaudeKey,
}) {
  final length = plainText.length;
  final lineCount = '\n'.allMatches(plainText).length + 1;
  final wantsClaude = length >= kClaudeRouteCharThreshold ||
      lineCount > kClaudeRouteLineThreshold;
  if (wantsClaude && hasClaudeKey) {
    return OrganizeRoute.claude;
  }
  return OrganizeRoute.ollama;
}

enum OrganizeRoute { ollama, claude }

/// AI Organize 本体。HTTP クライアントは差し替え可能。
class OrganizeService {
  OrganizeService({
    required this.keychain,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 45),
    int? retryMaxAttempts,
    Duration? retryBaseDelay,
    math.Random? random,
  })  : _httpClient = httpClient ?? http.Client(),
        _retryMaxAttempts = retryMaxAttempts ?? kDefaultRetryMaxAttempts,
        _retryBaseDelay = retryBaseDelay ?? kDefaultRetryBaseDelay,
        _random = random ?? math.Random();

  final KeychainService keychain;
  final http.Client _httpClient;
  final Duration timeout;
  final int _retryMaxAttempts;
  final Duration _retryBaseDelay;
  final math.Random _random;

  /// M0 audit Wave 4 (138s UX): user が UI cancel button を押した時に
  /// 立てる flag。`_retryHttpRequest` が次 attempt 前に check して即終了。
  /// 現在進行中の HTTP request 自体は abort できない (= 既に発射済の HTTP は
  /// 完了 or timeout を待つ) が、retry の連鎖を断ち切ることで最悪 ~138s 待ち
  /// を user 操作で 1 attempt 分 (~45s) で終わらせる。
  bool _cancelRequested = false;

  /// UI から呼ぶ cancel API。次 attempt 前に `_OrganizeCancelledException`
  /// throw されて `OrganizeFailure(cancelled, ...)` が返る。
  void cancelCurrent() {
    _cancelRequested = true;
  }

  /// `organize` / `testOllama` / `testClaude` / `batchClassify` の最初で
  /// flag をリセット。前回の cancel が次回 call に持ち越されないように。
  void _resetCancel() {
    _cancelRequested = false;
  }

  /// 並列複数付箋から同時 Generate された時の transient 失敗 (NSURLSession の
  /// "The resource could not be ..." 系 / 5xx / 429 / SocketException) に
  /// 指数バックオフリトライで耐えるためのデフォルト値。
  static const int kDefaultRetryMaxAttempts = 3;
  static const Duration kDefaultRetryBaseDelay = Duration(milliseconds: 200);

  /// HTTP リクエストを指数バックオフで最大 [_retryMaxAttempts] 回まで再試行する。
  ///
  /// retry 対象:
  /// - TimeoutException / SocketException / http.ClientException
  /// - HTTP 5xx / 429 (rate limit)
  ///
  /// retry 非対象 (即返却):
  /// - 2xx (成功)
  /// - 4xx (429 を除く: 認証エラー / リクエスト不正 → retry しても改善しない)
  ///
  /// バックオフ: base * 3^(attempt-1) + 0-50% jitter (default 200ms / 600ms / 1800ms)。
  /// per-request の timeout は呼び出し元の `request()` 内で .timeout(...) を付ける。
  Future<http.Response> _retryHttpRequest(
    Future<http.Response> Function() request,
  ) async {
    Object? lastException;
    for (var attempt = 1; attempt <= _retryMaxAttempts; attempt++) {
      // M0 audit Wave 4 (138s UX): attempt 直前に cancel check。次回以降の
      // attempt + backoff を即スキップして cancelled exception throw。
      if (_cancelRequested) {
        throw const _OrganizeCancelledException();
      }
      http.Response? response;
      try {
        response = await request();
      } on TimeoutException catch (e) {
        lastException = e;
      } on SocketException catch (e) {
        lastException = e;
      } on http.ClientException catch (e) {
        lastException = e;
      }

      // request 完了後にも cancel check (HTTP は完了したが、後続 retry を
      // やめる目的)。
      if (_cancelRequested) {
        throw const _OrganizeCancelledException();
      }

      if (response != null) {
        final retryable =
            response.statusCode >= 500 || response.statusCode == 429;
        if (!retryable || attempt == _retryMaxAttempts) {
          return response;
        }
        // 5xx / 429 を retry 対象として fall through (lastException は更新しない)。
      }

      if (attempt < _retryMaxAttempts) {
        await _backoffDelay(attempt);
      }
    }

    // 全 attempt が exception 系で失敗 → 最後の例外を呼び出し元に伝播。
    if (lastException is TimeoutException) throw lastException;
    if (lastException is SocketException) throw lastException;
    if (lastException is http.ClientException) throw lastException;
    throw StateError('retry exhausted without classified failure');
  }

  Future<void> _backoffDelay(int attempt) async {
    final factor = math.pow(3, attempt - 1).toInt();
    final scaled = _retryBaseDelay * factor;
    final jitterMs = _random.nextInt((scaled.inMilliseconds * 0.5).round() + 1);
    await Future<void>.delayed(scaled + Duration(milliseconds: jitterMs));
  }

  /// Ollama 推論エンドポイントを叩く。
  /// 戻り値: 整理後のテキスト、または失敗。
  Future<OrganizeResult> organize({
    required String plainText,
    required AppSettings settings,
  }) async {
    // M0 audit Wave 4: 前回 call の cancel flag を引き継がないようリセット。
    _resetCancel();
    final truncated = plainText.length > kOrganizeInputMaxLength
        ? plainText.substring(0, kOrganizeInputMaxLength)
        : plainText;

    final claudeKey = await _safeReadClaudeKey();
    final route = decideRoute(
      plainText: truncated,
      hasClaudeKey: claudeKey != null && claudeKey.isNotEmpty,
    );

    final prompt =
        buildPromptForPreset(settings.promptPreset, settings.promptCustomText);

    switch (route) {
      case OrganizeRoute.ollama:
        return await _callOllama(
          url: settings.ollamaUrl,
          model: settings.ollamaModel,
          prompt: prompt,
          input: truncated,
        );
      case OrganizeRoute.claude:
        return await _callClaude(
          apiKey: claudeKey!,
          prompt: prompt,
          input: truncated,
        );
    }
  }

  /// Ollama 接続テスト (/api/generate に 1 文字だけ送る)。
  Future<OrganizeResult> testOllama({
    required String url,
    required String model,
  }) async {
    return _callOllama(
      url: url,
      model: model,
      prompt: '短いテキストを整理する練習です。',
      input: 'こんにちは',
    );
  }

  /// Claude 接続テスト (Messages API に 1 メッセージ送る)。
  Future<OrganizeResult> testClaude({required String apiKey}) async {
    return _callClaude(
      apiKey: apiKey,
      prompt: 'あなたは挨拶を整える助手です。',
      input: 'こんにちは',
    );
  }

  Future<String?> _safeReadClaudeKey() async {
    try {
      return await keychain.loadClaudeApiKey();
    } catch (error) {
      stderr.writeln(
        'OrganizeService._safeReadClaudeKey failed: $error',
      );
      return null;
    }
  }

  // ===== Ollama =====
  Future<OrganizeResult> _callOllama({
    required String url,
    required String model,
    required String prompt,
    required String input,
  }) async {
    if (!isValidOllamaUrl(url)) {
      return const OrganizeFailure(
        OrganizeErrorKind.network,
        'Ollama URL は https / localhost / Tailscale CGNAT (100.64.0.0/10) のみ許可されます。',
      );
    }
    Uri parsed;
    try {
      parsed = Uri.parse(url);
    } catch (_) {
      return const OrganizeFailure(
        OrganizeErrorKind.network,
        'Ollama URL が正しくパースできません。',
      );
    }

    final body = jsonEncode({
      'model': model,
      'prompt': '$prompt\n\n<user>\n$input\n</user>',
      'stream': false,
    });

    try {
      final response = await _retryHttpRequest(
        () => _httpClient
            .post(
              parsed,
              headers: const {'Content-Type': 'application/json'},
              body: body,
            )
            .timeout(timeout),
      );

      if (response.statusCode == 429) {
        return OrganizeFailure(
          OrganizeErrorKind.rateLimit,
          'Ollama がレート制限を返しました (429)。少し時間を置いて再試行してください。',
        );
      }
      if (response.statusCode >= 500) {
        return OrganizeFailure(
          OrganizeErrorKind.server,
          'Ollama サーバエラー (${response.statusCode})。',
        );
      }
      if (response.statusCode >= 400) {
        return OrganizeFailure(
          OrganizeErrorKind.server,
          'Ollama がエラーを返しました (${response.statusCode})。',
        );
      }
      final decoded = _safeDecodeJson(response.body);
      if (decoded is! Map<String, dynamic>) {
        return const OrganizeFailure(
          OrganizeErrorKind.parse,
          'Ollama のレスポンスが解釈できませんでした。',
        );
      }
      final text = decoded['response'];
      if (text is! String || text.trim().isEmpty) {
        return const OrganizeFailure(
          OrganizeErrorKind.parse,
          'Ollama のレスポンスに response フィールドがありません。',
        );
      }
      return OrganizeSuccess(
        plainText: text.trim(),
        richText: buildPlainDelta(text.trim()),
      );
    } on _OrganizeCancelledException {
      return const OrganizeFailure(
        OrganizeErrorKind.cancelled,
        'キャンセルされました。',
      );
    } on TimeoutException {
      return OrganizeFailure(
        OrganizeErrorKind.network,
        'Ollama への接続がタイムアウトしました (${timeout.inSeconds}s)。',
      );
    } on SocketException catch (error) {
      return OrganizeFailure(
        OrganizeErrorKind.network,
        'Ollama への接続に失敗しました: ${error.message}',
      );
    } on http.ClientException catch (error) {
      return OrganizeFailure(
        OrganizeErrorKind.network,
        'Ollama への HTTP 送信に失敗しました: ${error.message}',
      );
    } catch (error) {
      stderr.writeln('OrganizeService Ollama unknown error: $error');
      return OrganizeFailure(
        OrganizeErrorKind.network,
        '不明なエラーが発生しました: $error',
      );
    }
  }

  // ===== Claude =====
  Future<OrganizeResult> _callClaude({
    required String apiKey,
    required String prompt,
    required String input,
  }) async {
    if (apiKey.isEmpty) {
      return const OrganizeFailure(
        OrganizeErrorKind.key,
        'Claude API キーが設定されていません。Settings > AI Organize で設定してください。',
      );
    }

    final body = jsonEncode({
      'model': 'claude-sonnet-4-5-20250929',
      'max_tokens': 2048,
      'system': prompt,
      'messages': [
        {
          'role': 'user',
          'content': input,
        },
      ],
    });

    // 診断ログ (キー本体は出さない)
    stdout.writeln(
      '[organize] Claude call apiKey=${redactApiKey(apiKey)} inputLen=${input.length}',
    );

    final uri = Uri.parse('https://api.anthropic.com/v1/messages');
    try {
      final response = await _retryHttpRequest(
        () => _httpClient
            .post(
              uri,
              headers: {
                'Content-Type': 'application/json',
                'anthropic-version': '2023-06-01',
                'x-api-key': apiKey,
              },
              body: body,
            )
            .timeout(timeout),
      );

      if (response.statusCode == 401 || response.statusCode == 403) {
        return const OrganizeFailure(
          OrganizeErrorKind.key,
          'Claude API キーが拒否されました。キーを確認してください。',
        );
      }
      if (response.statusCode == 429) {
        return const OrganizeFailure(
          OrganizeErrorKind.rateLimit,
          'Claude がレート制限を返しました。少し時間を置いて再試行してください。',
        );
      }
      if (response.statusCode >= 500) {
        return OrganizeFailure(
          OrganizeErrorKind.server,
          'Claude サーバエラー (${response.statusCode})。',
        );
      }
      if (response.statusCode >= 400) {
        return OrganizeFailure(
          OrganizeErrorKind.server,
          'Claude がエラーを返しました (${response.statusCode})。',
        );
      }

      final decoded = _safeDecodeJson(response.body);
      if (decoded is! Map<String, dynamic>) {
        return const OrganizeFailure(
          OrganizeErrorKind.parse,
          'Claude のレスポンスが解釈できませんでした。',
        );
      }
      final content = decoded['content'];
      if (content is! List || content.isEmpty) {
        return const OrganizeFailure(
          OrganizeErrorKind.parse,
          'Claude のレスポンスに content がありません。',
        );
      }
      // content[0] が { "type": "text", "text": "..." } と想定。
      final first = content.first;
      if (first is! Map) {
        return const OrganizeFailure(
          OrganizeErrorKind.parse,
          'Claude のレスポンス content 要素が不正です。',
        );
      }
      final text = first['text'];
      if (text is! String || text.trim().isEmpty) {
        return const OrganizeFailure(
          OrganizeErrorKind.parse,
          'Claude のレスポンスにテキストがありません。',
        );
      }
      return OrganizeSuccess(
        plainText: text.trim(),
        richText: buildPlainDelta(text.trim()),
      );
    } on _OrganizeCancelledException {
      return const OrganizeFailure(
        OrganizeErrorKind.cancelled,
        'キャンセルされました。',
      );
    } on TimeoutException {
      return OrganizeFailure(
        OrganizeErrorKind.network,
        'Claude への接続がタイムアウトしました (${timeout.inSeconds}s)。',
      );
    } on SocketException catch (error) {
      return OrganizeFailure(
        OrganizeErrorKind.network,
        'Claude への接続に失敗しました: ${error.message}',
      );
    } on http.ClientException catch (error) {
      return OrganizeFailure(
        OrganizeErrorKind.network,
        'Claude への HTTP 送信に失敗しました: ${error.message}',
      );
    } catch (error) {
      stderr.writeln('OrganizeService Claude unknown error: $error');
      return OrganizeFailure(
        OrganizeErrorKind.network,
        '不明なエラーが発生しました: $error',
      );
    }
  }

  Object? _safeDecodeJson(String body) {
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }

  // ===== Batch Classify (Sprint 5 Feature 5.2 / Round 2) =====
  //
  // Inbox の複数ノートを AI に分類させ、既存グループ名に合致すれば ID 解決、
  // 合致しなければ新規グループ名として `__new__:<name>` を返す。
  //
  // ルーティング:
  // - Claude API キーがあれば Claude を優先 (分類精度と JSON 出力安定性のため)
  // - それ以外は Ollama (JSON mode リクエストを送信、未対応モデルでも plain
  //   text で JSON を返せば parse 可能)
  //
  // 失敗モード:
  // - LLM 呼び出し全失敗 -> 全 noteId を failures に記録、assignments は空
  // - 部分的に noteId が欠けた JSON -> 欠けた分を failures にする

  /// Inbox の複数ノートを AI に分類させる。Sprint 5 Feature 5.2 の本実装。
  ///
  /// [requests] は対象ノート。 [existingGroups] は既に存在するユーザーグループ
  /// (Inbox を除外して渡すのが通常)。 [settings] は Ollama URL / model を含む。
  ///
  /// 戻り値 [ClassifyResult] の assignments は:
  /// - 既存グループと一致: value = groupID
  /// - 新規グループ提案: value = `__new__:<グループ名>` (呼び出し側で createGroup
  ///   してから placeholder を id に置換する)
  ///
  /// [preferOllama] を true にするとキー有無に関わらず Ollama を使う (テスト用)。
  Future<ClassifyResult> batchClassify({
    required List<ClassifyRequest> requests,
    required List<ClassifyGroup> existingGroups,
    required AppSettings settings,
    bool preferOllama = false,
  }) async {
    if (requests.isEmpty) {
      return const ClassifyResult(
        assignments: {},
        newGroupNames: [],
        failures: {},
      );
    }
    final limited = requests.length > kBatchClassifyMaxNotes
        ? requests.sublist(0, kBatchClassifyMaxNotes)
        : requests;

    String? claudeKey;
    if (!preferOllama) {
      claudeKey = await _safeReadClaudeKey();
    }
    final hasKey = claudeKey != null && claudeKey.isNotEmpty;

    final systemPrompt = buildBatchClassifyPrompt(existingGroups);
    final userMessage = buildBatchClassifyUserMessage(limited);

    OrganizeResult llmResult;
    if (hasKey && !preferOllama) {
      llmResult = await _callClaudeForClassify(
        apiKey: claudeKey,
        systemPrompt: systemPrompt,
        userMessage: userMessage,
      );
    } else {
      llmResult = await _callOllamaForClassify(
        url: settings.ollamaUrl,
        model: settings.ollamaModel,
        systemPrompt: systemPrompt,
        userMessage: userMessage,
      );
    }

    switch (llmResult) {
      case OrganizeFailure(:final kind):
        return ClassifyResult(
          assignments: const {},
          newGroupNames: const [],
          failures: {for (final r in limited) r.noteId: kind},
        );
      case OrganizeSuccess():
        return parseBatchClassifyResponse(
          responseText: llmResult.plainText,
          requests: limited,
          existingGroups: existingGroups,
        );
    }
  }

  Future<OrganizeResult> _callOllamaForClassify({
    required String url,
    required String model,
    required String systemPrompt,
    required String userMessage,
  }) async {
    if (!isValidOllamaUrl(url)) {
      return const OrganizeFailure(
        OrganizeErrorKind.network,
        'Ollama URL は https / localhost / Tailscale CGNAT (100.64.0.0/10) のみ許可されます。',
      );
    }
    Uri parsed;
    try {
      parsed = Uri.parse(url);
    } catch (_) {
      return const OrganizeFailure(
        OrganizeErrorKind.network,
        'Ollama URL が正しくパースできません。',
      );
    }
    final body = jsonEncode({
      'model': model,
      'prompt': '$systemPrompt\n\n<user>\n$userMessage\n</user>',
      'stream': false,
      'format': 'json',
    });
    try {
      // M0 audit fix 2026-05-10 (Subagent A OOS): batch-classify でも
      // 単発 organize と同じ retry を適用 (transient 5xx/429/Timeout/Socket/
      // ClientException を吸収)。
      final response = await _retryHttpRequest(
        () => _httpClient
            .post(
              parsed,
              headers: const {'Content-Type': 'application/json'},
              body: body,
            )
            .timeout(timeout),
      );
      if (response.statusCode == 429) {
        return const OrganizeFailure(
          OrganizeErrorKind.rateLimit,
          'Ollama がレート制限を返しました (429)。',
        );
      }
      if (response.statusCode >= 500) {
        return OrganizeFailure(
          OrganizeErrorKind.server,
          'Ollama サーバエラー (${response.statusCode})。',
        );
      }
      if (response.statusCode >= 400) {
        return OrganizeFailure(
          OrganizeErrorKind.server,
          'Ollama がエラーを返しました (${response.statusCode})。',
        );
      }
      final decoded = _safeDecodeJson(response.body);
      if (decoded is! Map<String, dynamic>) {
        return const OrganizeFailure(
          OrganizeErrorKind.parse,
          'Ollama のレスポンスが解釈できませんでした。',
        );
      }
      final text = decoded['response'];
      if (text is! String || text.trim().isEmpty) {
        return const OrganizeFailure(
          OrganizeErrorKind.parse,
          'Ollama のレスポンスに response フィールドがありません。',
        );
      }
      return OrganizeSuccess(
        plainText: text.trim(),
        richText: buildPlainDelta(text.trim()),
      );
    } on TimeoutException {
      return OrganizeFailure(
        OrganizeErrorKind.network,
        'Ollama への接続がタイムアウトしました (${timeout.inSeconds}s)。',
      );
    } on SocketException catch (error) {
      return OrganizeFailure(
        OrganizeErrorKind.network,
        'Ollama への接続に失敗しました: ${error.message}',
      );
    } on http.ClientException catch (error) {
      return OrganizeFailure(
        OrganizeErrorKind.network,
        'Ollama への HTTP 送信に失敗しました: ${error.message}',
      );
    } catch (error) {
      stderr.writeln('OrganizeService.batchClassify Ollama error: $error');
      return OrganizeFailure(
        OrganizeErrorKind.network,
        '不明なエラーが発生しました: $error',
      );
    }
  }

  Future<OrganizeResult> _callClaudeForClassify({
    required String apiKey,
    required String systemPrompt,
    required String userMessage,
  }) async {
    if (apiKey.isEmpty) {
      return const OrganizeFailure(
        OrganizeErrorKind.key,
        'Claude API キーが設定されていません。',
      );
    }
    final body = jsonEncode({
      'model': 'claude-sonnet-4-5-20250929',
      'max_tokens': 2048,
      'system': systemPrompt,
      'messages': [
        {'role': 'user', 'content': userMessage},
      ],
    });
    stdout.writeln(
      '[batchClassify] Claude call apiKey=${redactApiKey(apiKey)} userLen=${userMessage.length}',
    );
    final uri = Uri.parse('https://api.anthropic.com/v1/messages');
    try {
      // M0 audit fix 2026-05-10 (Subagent A OOS): batch-classify Claude 経路
      // にも retry 適用 (Inbox 一括分類で 5xx/429 transient を吸収)。
      final response = await _retryHttpRequest(
        () => _httpClient
            .post(
              uri,
              headers: {
                'Content-Type': 'application/json',
                'anthropic-version': '2023-06-01',
                'x-api-key': apiKey,
              },
              body: body,
            )
            .timeout(timeout),
      );
      if (response.statusCode == 401 || response.statusCode == 403) {
        return const OrganizeFailure(
          OrganizeErrorKind.key,
          'Claude API キーが拒否されました。',
        );
      }
      if (response.statusCode == 429) {
        return const OrganizeFailure(
          OrganizeErrorKind.rateLimit,
          'Claude がレート制限を返しました。',
        );
      }
      if (response.statusCode >= 500) {
        return OrganizeFailure(
          OrganizeErrorKind.server,
          'Claude サーバエラー (${response.statusCode})。',
        );
      }
      if (response.statusCode >= 400) {
        return OrganizeFailure(
          OrganizeErrorKind.server,
          'Claude がエラーを返しました (${response.statusCode})。',
        );
      }
      final decoded = _safeDecodeJson(response.body);
      if (decoded is! Map<String, dynamic>) {
        return const OrganizeFailure(
          OrganizeErrorKind.parse,
          'Claude のレスポンスが解釈できませんでした。',
        );
      }
      final content = decoded['content'];
      if (content is! List || content.isEmpty) {
        return const OrganizeFailure(
          OrganizeErrorKind.parse,
          'Claude のレスポンスに content がありません。',
        );
      }
      final first = content.first;
      if (first is! Map) {
        return const OrganizeFailure(
          OrganizeErrorKind.parse,
          'Claude のレスポンス content 要素が不正です。',
        );
      }
      final text = first['text'];
      if (text is! String || text.trim().isEmpty) {
        return const OrganizeFailure(
          OrganizeErrorKind.parse,
          'Claude のレスポンスにテキストがありません。',
        );
      }
      return OrganizeSuccess(
        plainText: text.trim(),
        richText: buildPlainDelta(text.trim()),
      );
    } on TimeoutException {
      return OrganizeFailure(
        OrganizeErrorKind.network,
        'Claude への接続がタイムアウトしました (${timeout.inSeconds}s)。',
      );
    } on SocketException catch (error) {
      return OrganizeFailure(
        OrganizeErrorKind.network,
        'Claude への接続に失敗しました: ${error.message}',
      );
    } on http.ClientException catch (error) {
      return OrganizeFailure(
        OrganizeErrorKind.network,
        'Claude への HTTP 送信に失敗しました: ${error.message}',
      );
    } catch (error) {
      stderr.writeln('OrganizeService.batchClassify Claude error: $error');
      return OrganizeFailure(
        OrganizeErrorKind.network,
        '不明なエラーが発生しました: $error',
      );
    }
  }
}

/// Batch Classify のリクエスト: 1 ノート分の入力。
class ClassifyRequest {
  const ClassifyRequest({
    required this.noteId,
    required this.text,
  });

  final String noteId;
  final String text;
}

/// Batch Classify が参照する「既存グループ」の最小情報。
///
/// OrganizeService は GroupManager に直接依存しないよう、ID と表示名のみを
/// 受け取る。呼び出し元 (settings_window) が Inbox を除外して詰め替える。
class ClassifyGroup {
  const ClassifyGroup({required this.id, required this.name});
  final String id;
  final String name;
}

/// Batch Classify の結果。
/// - assignments[noteId] は既存グループ ID か `__new__:<name>` placeholder
/// - newGroupNames は呼び出し側で createGroup が必要な名前のユニーク一覧
/// - failures は分類に失敗した noteId とエラー種別 (全件失敗時は全 noteId に同じ kind)
class ClassifyResult {
  const ClassifyResult({
    required this.assignments,
    required this.newGroupNames,
    required this.failures,
  });

  final Map<String, String> assignments;
  final List<String> newGroupNames;
  final Map<String, OrganizeErrorKind> failures;
}

/// Batch classifier 関数型。OrganizeService.batchClassify をバインドした形で
/// 上位層が使えるようにしておく (テストで override 可能)。
typedef BatchClassifier = Future<ClassifyResult> Function({
  required List<ClassifyRequest> requests,
  required List<ClassifyGroup> existingGroups,
  required AppSettings settings,
});

/// batchClassify で送信できる最大ノート数 (過剰トークン対策)。
const int kBatchClassifyMaxNotes = 50;

/// batchClassify で 1 ノートあたりに含める最大文字数 (プロンプトサイズ制御)。
const int kBatchClassifyMaxCharsPerNote = 800;

/// Batch Classify 用 system プロンプトを生成する。
/// 既存グループ名は箇条書きで LLM に提示し、合致しない場合は新規グループ名を
/// 提案させる。出力は必ず JSON オブジェクト。
String buildBatchClassifyPrompt(List<ClassifyGroup> existingGroups) {
  final groupsText = existingGroups.isEmpty
      ? '(既存グループはありません。全ノートに新規グループ名を提案してください)'
      : existingGroups.map((g) => '- ${g.name}').join('\n');
  return '''
あなたはノート分類アシスタントです。与えられたメモ群を、
既存グループのいずれかに振り分けるか、新しいグループ名を提案してください。

既存グループ一覧:
$groupsText

出力は必ず JSON オブジェクトで、次の形式に厳密に従ってください:
{"assignments": {"<noteId>": "<groupName>", ...}}

ルール:
- groupName は既存グループ名と完全一致させるか、新規グループ名 (短い日本語、2-8 文字推奨) を提案する
- 各 noteId に必ず 1 つの groupName を割り当てる
- JSON 以外のテキスト・説明・前書き・コードフェンスは一切出力しない
- 内容が曖昧・分類不能な場合でも適当な新規グループ名 (例: "その他") を提案する
''';
}

/// batchClassify 用の user メッセージを組み立てる。ノート本文は長さ制限で丸める。
String buildBatchClassifyUserMessage(List<ClassifyRequest> requests) {
  final map = <String, String>{};
  for (final r in requests) {
    var text = r.text;
    if (text.length > kBatchClassifyMaxCharsPerNote) {
      text = text.substring(0, kBatchClassifyMaxCharsPerNote);
    }
    map[r.noteId] = text;
  }
  return '以下のメモを分類してください。noteId は必ず一致させてください。\n\n'
      '${jsonEncode(map)}';
}

/// LLM 応答 (JSON 文字列) を parse し、既存グループ名と照合して
/// `assignments` / `newGroupNames` / `failures` を組み立てる。
///
/// 可視性: ユニットテストから直接呼べるよう top-level 関数として公開している。
ClassifyResult parseBatchClassifyResponse({
  required String responseText,
  required List<ClassifyRequest> requests,
  required List<ClassifyGroup> existingGroups,
}) {
  final trimmed = _extractJsonObject(responseText);
  Map<String, dynamic>? decoded;
  try {
    final value = jsonDecode(trimmed);
    if (value is Map<String, dynamic>) {
      decoded = value;
    } else if (value is Map) {
      decoded = Map<String, dynamic>.from(value);
    }
  } catch (_) {
    decoded = null;
  }
  if (decoded == null) {
    return ClassifyResult(
      assignments: const {},
      newGroupNames: const [],
      failures: {for (final r in requests) r.noteId: OrganizeErrorKind.parse},
    );
  }
  final raw = decoded['assignments'];
  if (raw is! Map) {
    return ClassifyResult(
      assignments: const {},
      newGroupNames: const [],
      failures: {for (final r in requests) r.noteId: OrganizeErrorKind.parse},
    );
  }

  String normalize(String s) => s.trim().toLowerCase();
  final existingByName = <String, String>{};
  for (final g in existingGroups) {
    if (g.name.trim().isEmpty) continue;
    existingByName[normalize(g.name)] = g.id;
  }

  final assignments = <String, String>{};
  final newGroupNames = <String>{};
  final failures = <String, OrganizeErrorKind>{};

  for (final r in requests) {
    final proposed = raw[r.noteId];
    if (proposed is! String || proposed.trim().isEmpty) {
      failures[r.noteId] = OrganizeErrorKind.parse;
      continue;
    }
    final name = proposed.trim();
    final hit = existingByName[normalize(name)];
    if (hit != null) {
      assignments[r.noteId] = hit;
    } else {
      assignments[r.noteId] = '__new__:$name';
      newGroupNames.add(name);
    }
  }

  return ClassifyResult(
    assignments: assignments,
    newGroupNames: newGroupNames.toList(growable: false),
    failures: failures,
  );
}

/// LLM 応答からコードフェンス・前後テキストを除去し、最外側の `{...}` を抽出。
/// 失敗時は原文のまま返す (parse 段階で failures になる)。
String _extractJsonObject(String raw) {
  var text = raw.trim();
  if (text.startsWith('```')) {
    final firstNewline = text.indexOf('\n');
    if (firstNewline >= 0) {
      text = text.substring(firstNewline + 1);
    }
    if (text.endsWith('```')) {
      text = text.substring(0, text.length - 3);
    }
    text = text.trim();
  }
  final openIdx = text.indexOf('{');
  final closeIdx = text.lastIndexOf('}');
  if (openIdx >= 0 && closeIdx > openIdx) {
    return text.substring(openIdx, closeIdx + 1);
  }
  return text;
}
