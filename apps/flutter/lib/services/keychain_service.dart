// Keychain / Credential Locker サービス雛形 (Sprint 5 の Feature 5.3 で本実装)。
//
// flutter_secure_storage で macOS Keychain + Windows Credential Locker を透過的に扱う。
// 保存後は read-back 検証を行い、失敗時はエラーを UI に返す (現行 M8 修正踏襲)。

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 読み戻し検証が失敗した場合の例外。
class KeychainReadBackMismatchException implements Exception {
  const KeychainReadBackMismatchException(this.message);

  final String message;

  @override
  String toString() {
    return 'KeychainReadBackMismatchException: $message';
  }
}

/// セキュアストレージのラッパー。Claude API キーなど機微情報を保管する。
class KeychainService {
  KeychainService({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
              mOptions: MacOsOptions(
                accessibility: KeychainAccessibility.first_unlock,
                synchronizable: false,
              ),
              wOptions: WindowsOptions(),
            );

  static const String _claudeApiKeyKey = 'flote.claudeApiKey';
  static const String _ollamaUrlKey = 'flote.ollamaUrl';

  final FlutterSecureStorage _storage;

  /// Claude API キーを保存する。
  Future<void> saveClaudeApiKey(String key) async {
    await _saveValue(
      storageKey: _claudeApiKeyKey,
      value: key,
      logName: 'saveClaudeApiKey',
    );
  }

  /// Claude API キーを読み込む。未設定時は null。
  Future<String?> loadClaudeApiKey() async {
    return _loadValue(
      storageKey: _claudeApiKeyKey,
      logName: 'loadClaudeApiKey',
    );
  }

  /// Claude API キーを削除する。
  Future<void> deleteClaudeApiKey() async {
    await _deleteValue(
      storageKey: _claudeApiKeyKey,
      logName: 'deleteClaudeApiKey',
    );
  }

  /// Claude API キーが設定済みかを返す。
  Future<bool> hasClaudeApiKey() async {
    final value = await loadClaudeApiKey();
    return value != null && value.isNotEmpty;
  }

  /// Ollama URL を保存する。
  Future<void> saveOllamaUrl(String url) async {
    await _saveValue(
      storageKey: _ollamaUrlKey,
      value: url,
      logName: 'saveOllamaUrl',
    );
  }

  /// Ollama URL を読み込む。未設定時は null。
  Future<String?> loadOllamaUrl() async {
    return _loadValue(
      storageKey: _ollamaUrlKey,
      logName: 'loadOllamaUrl',
    );
  }

  /// Ollama URL を削除する。
  Future<void> deleteOllamaUrl() async {
    await _deleteValue(
      storageKey: _ollamaUrlKey,
      logName: 'deleteOllamaUrl',
    );
  }

  Future<void> _saveValue({
    required String storageKey,
    required String value,
    required String logName,
  }) async {
    try {
      if (value.isEmpty) {
        await _storage.delete(key: storageKey);
        stdout.writeln('[$logName] save: deleted empty value');
        return;
      }
      await _storage.write(key: storageKey, value: value);
      final readBack = await _storage.read(key: storageKey);
      if (readBack != value) {
        throw KeychainReadBackMismatchException(
          '$logName read-back mismatch',
        );
      }
      // M0 audit fix: API key length をログに残さない
      // (redactApiKey の prefix-4 と組合せでブルートフォース narrowing になる)
      stdout.writeln('[keychain] $logName: save success');
    } on MissingPluginException catch (error) {
      stderr.writeln('[keychain] $logName: plugin unavailable ($error)');
      rethrow;
    } on PlatformException catch (error) {
      stderr.writeln('[keychain] $logName: platform error (${error.code})');
      rethrow;
    } catch (error) {
      stderr.writeln('[keychain] $logName: failed (${error.runtimeType})');
      rethrow;
    }
  }

  Future<String?> _loadValue({
    required String storageKey,
    required String logName,
  }) async {
    try {
      final value = await _storage.read(key: storageKey);
      if (value == null || value.isEmpty) {
        stdout.writeln('[keychain] $logName: empty');
        return null;
      }
      stdout.writeln('[keychain] $logName: load success');
      return value;
    } on MissingPluginException catch (error) {
      stderr.writeln('[keychain] $logName: plugin unavailable ($error)');
      rethrow;
    } on PlatformException catch (error) {
      stderr.writeln('[keychain] $logName: platform error (${error.code})');
      rethrow;
    } catch (error) {
      stderr.writeln('[keychain] $logName: failed (${error.runtimeType})');
      rethrow;
    }
  }

  Future<void> _deleteValue({
    required String storageKey,
    required String logName,
  }) async {
    try {
      await _storage.delete(key: storageKey);
      stdout.writeln('[keychain] $logName: success');
    } on MissingPluginException catch (error) {
      stderr.writeln('[keychain] $logName: plugin unavailable ($error)');
      rethrow;
    } on PlatformException catch (error) {
      stderr.writeln('[keychain] $logName: platform error (${error.code})');
      rethrow;
    } catch (error) {
      stderr.writeln('[keychain] $logName: failed (${error.runtimeType})');
      rethrow;
    }
  }
}
