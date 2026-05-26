// Settings AI Organize セクション (Sprint 5 Feature 5.3 / 5.4)。
//
// - Ollama URL / model 入力 + 接続テスト
// - Claude API キー入力 (マスク表示 + show/hide トグル + ペースト可)
// - 保存ボタンで AppSettings と Keychain に永続化
// - URL validation は OrganizeService.isValidOllamaUrl を利用

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/app_settings.dart';
import '../../../services/organize_service.dart';
import '../../../theme/tokens.dart';
import '../settings_components.dart';

/// AI セクション用のコールバック型。
typedef AISaveCallback = Future<void> Function(
  String ollamaUrl,
  String ollamaModel,
  String? claudeApiKey,
);

typedef AITestOllamaCallback = Future<String> Function(String url, String model);
typedef AITestClaudeCallback = Future<String> Function(String? key);

class AISection extends ConsumerStatefulWidget {
  const AISection({
    super.key,
    this.onSave,
    this.onDelete,
    this.onTestOllama,
    this.onTestClaude,
  });

  final AISaveCallback? onSave;
  final Future<void> Function()? onDelete;
  final AITestOllamaCallback? onTestOllama;
  final AITestClaudeCallback? onTestClaude;

  @override
  ConsumerState<AISection> createState() => _AISectionState();
}

class _AISectionState extends ConsumerState<AISection> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _modelController = TextEditingController();
  final TextEditingController _apiKeyController = TextEditingController();
  bool _showApiKey = false;
  bool _initialized = false;
  bool _isSaving = false;
  bool _isTestingOllama = false;
  bool _isTestingClaude = false;

  @override
  void dispose() {
    _urlController.dispose();
    _modelController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  void _initializeIfNeeded(String url, String model) {
    if (_initialized) {
      return;
    }
    _urlController.text = url;
    _modelController.text = model;
    _initialized = true;
  }

  @override
  Widget build(BuildContext context) {
    final asyncSettings = ref.watch(appSettingsProvider);
    return asyncSettings.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(
        child: Text('設定読込失敗: $error',
            style: TypographyTokens.body.copyWith(color: ColorTokens.error)),
      ),
      data: (settings) {
        _initializeIfNeeded(settings.ollamaUrl, settings.ollamaModel);
        return SettingsSection(
          heading: 'AI Organize',
          description: 'Ollama と Claude の接続先・認証情報',
          children: [
            _buildOllamaRows(),
            const SettingsDivider(),
            _buildClaudeRows(),
            const SettingsDivider(),
            _buildActionsRow(),
          ],
        );
      },
    );
  }

  Widget _buildOllamaRows() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsRow(
          label: 'Ollama URL',
          description: 'https / localhost / Tailscale (100.64.0.0/10) のみ',
          child: TextField(
            controller: _urlController,
            decoration: InputDecoration(
              hintText: 'http://localhost:11434/api/generate',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: _isTestingOllama
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.network_check, size: 18),
                tooltip: '接続テスト',
                onPressed: _isTestingOllama ? null : _handleTestOllama,
              ),
            ),
          ),
        ),
        const SizedBox(height: SpacingTokens.sm),
        SettingsRow(
          label: 'モデル名',
          child: TextField(
            controller: _modelController,
            decoration: const InputDecoration(
              hintText: 'gemma3:12b',
              border: OutlineInputBorder(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildClaudeRows() {
    return SettingsRow(
      label: 'Claude API キー',
      description: '200 文字超 または 5 行超の整理で使用',
      child: TextField(
        controller: _apiKeyController,
        obscureText: !_showApiKey,
        enableSuggestions: false,
        autocorrect: false,
        decoration: InputDecoration(
          hintText: 'sk-ant-api03-...',
          border: const OutlineInputBorder(),
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: _isTestingClaude
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.bolt, size: 18),
                tooltip: '接続テスト',
                onPressed: _isTestingClaude ? null : _handleTestClaude,
              ),
              IconButton(
                icon: Icon(
                  _showApiKey ? Icons.visibility_off : Icons.visibility,
                  size: 18,
                ),
                tooltip: _showApiKey ? '隠す' : '表示',
                onPressed: () {
                  setState(() {
                    _showApiKey = !_showApiKey;
                  });
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionsRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton.icon(
          onPressed: widget.onDelete == null ? null : _handleDelete,
          icon: const Icon(Icons.delete_outline, size: 16),
          label: const Text('キーを削除'),
        ),
        const SizedBox(width: SpacingTokens.sm),
        FilledButton.icon(
          onPressed: _isSaving ? null : _handleSave,
          icon: _isSaving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save, size: 16),
          label: const Text('保存'),
        ),
      ],
    );
  }

  Future<void> _handleSave() async {
    final url = _urlController.text.trim();
    final model = _modelController.text.trim();
    final apiKey = _apiKeyController.text;

    if (!isValidOllamaUrl(url)) {
      _showSnack('Ollama URL が許可されていません (https / localhost / CGNAT)');
      return;
    }
    if (model.isEmpty) {
      _showSnack('モデル名を入力してください');
      return;
    }

    setState(() => _isSaving = true);
    try {
      // API キーは空なら null を渡す (呼び出し側で削除扱いにする)。
      await widget.onSave?.call(url, model, apiKey.isEmpty ? null : apiKey);
      if (!mounted) return;
      _showSnack('保存しました');
      _apiKeyController.clear();
      setState(() => _showApiKey = false);
    } catch (error) {
      _showSnack('保存に失敗しました: $error');
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _handleDelete() async {
    try {
      await widget.onDelete?.call();
      if (!mounted) return;
      _apiKeyController.clear();
      _showSnack('Claude API キーを削除しました');
    } catch (error) {
      _showSnack('削除に失敗しました: $error');
    }
  }

  Future<void> _handleTestOllama() async {
    final url = _urlController.text.trim();
    final model = _modelController.text.trim();
    if (!isValidOllamaUrl(url)) {
      _showSnack('Ollama URL が許可されていません');
      return;
    }
    setState(() => _isTestingOllama = true);
    try {
      final result = await widget.onTestOllama?.call(url, model);
      if (!mounted) return;
      _showSnack(result ?? 'テスト未実装');
    } catch (error) {
      _showSnack('Ollama 接続テスト失敗: $error');
    } finally {
      if (mounted) {
        setState(() => _isTestingOllama = false);
      }
    }
  }

  Future<void> _handleTestClaude() async {
    final apiKey = _apiKeyController.text;
    setState(() => _isTestingClaude = true);
    try {
      final result = await widget.onTestClaude?.call(
        apiKey.isEmpty ? null : apiKey,
      );
      if (!mounted) return;
      _showSnack(result ?? 'テスト未実装');
    } catch (error) {
      _showSnack('Claude 接続テスト失敗: $error');
    } finally {
      if (mounted) {
        setState(() => _isTestingClaude = false);
      }
    }
  }

  void _showSnack(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) {
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 3),
      ),
    );
  }
}
