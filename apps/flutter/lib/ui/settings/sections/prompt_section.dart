// Settings Prompt セクション (Sprint 5 Feature 5.4)。
//
// 3 preset (簡潔 / 標準 / カスタム) から選択。custom 選択時は大きな TextField で
// 編集可能。保存ボタンで AppSettings に永続化。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/prompts.dart';
import '../../../providers/app_settings.dart';
import '../../../theme/tokens.dart';
import '../settings_components.dart';

class PromptSection extends ConsumerStatefulWidget {
  const PromptSection({super.key, this.onSaved});

  final Future<void> Function(PromptPreset preset, String customText)? onSaved;

  @override
  ConsumerState<PromptSection> createState() => _PromptSectionState();
}

class _PromptSectionState extends ConsumerState<PromptSection> {
  PromptPreset? _selected;
  final TextEditingController _customController = TextEditingController();
  bool _initialized = false;
  bool _isSaving = false;

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  void _initializeIfNeeded(PromptPreset preset, String customText) {
    if (_initialized) {
      return;
    }
    _selected = preset;
    _customController.text = customText;
    _initialized = true;
  }

  @override
  Widget build(BuildContext context) {
    final asyncSettings = ref.watch(appSettingsProvider);
    return asyncSettings.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(child: Text('読込失敗: $error')),
      data: (settings) {
        _initializeIfNeeded(settings.promptPreset, settings.promptCustomText);
        final current = _selected ?? settings.promptPreset;
        return SettingsSection(
          heading: 'Prompt',
          description: 'AI Organize に渡すプロンプトのプリセット',
          children: [
            _buildRadio(PromptPreset.concise, promptConcise),
            _buildRadio(PromptPreset.standard, promptStandard),
            _buildRadio(PromptPreset.custom, promptCustomDefault),
            if (current == PromptPreset.custom) _buildCustomEditor(),
            const SettingsDivider(),
            _buildActions(),
          ],
        );
      },
    );
  }

  Widget _buildRadio(PromptPreset preset, String previewSource) {
    final preview = _preview(previewSource);
    final current = _selected ?? PromptPreset.standard;
    return RadioListTile<PromptPreset>(
      value: preset,
      // ignore: deprecated_member_use
      groupValue: current,
      // ignore: deprecated_member_use
      onChanged: (next) {
        if (next == null) return;
        setState(() => _selected = next);
      },
      title: Text(
        preset.displayName,
        style: TypographyTokens.bodyBold.copyWith(
          color: ColorTokens.onSurface,
        ),
      ),
      subtitle: Text(
        preview,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TypographyTokens.caption.copyWith(
          color: ColorTokens.onSurfaceMuted,
        ),
      ),
    );
  }

  Widget _buildCustomEditor() {
    return Padding(
      padding: const EdgeInsets.only(top: SpacingTokens.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'カスタムプロンプト',
            style: TypographyTokens.caption.copyWith(
              color: ColorTokens.onSurfaceMuted,
            ),
          ),
          const SizedBox(height: SpacingTokens.xs),
          TextField(
            controller: _customController,
            maxLines: 12,
            minLines: 8,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'AI に渡す指示を編集...',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton.icon(
          onPressed: _handleResetCustom,
          icon: const Icon(Icons.restart_alt, size: 16),
          label: const Text('カスタムを初期値に戻す'),
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

  Future<void> _handleResetCustom() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('カスタムを初期値に戻しますか'),
        content: const Text('編集中のカスタムプロンプトは失われます。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('戻す'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() {
      _customController.text = promptCustomDefault;
    });
  }

  Future<void> _handleSave() async {
    final preset = _selected ?? PromptPreset.standard;
    final customText = _customController.text;
    setState(() => _isSaving = true);
    try {
      await widget.onSaved?.call(preset, customText);
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('プロンプト設定を保存しました')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('保存に失敗: $error')),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  String _preview(String source) {
    final normalized = source.replaceAll('\n', ' ').trim();
    if (normalized.length <= 80) {
      return normalized;
    }
    return '${normalized.substring(0, 80)}...';
  }
}
