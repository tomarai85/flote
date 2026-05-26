import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/sticky_note.dart';
import '../../providers/app_settings.dart';
import '../../theme/tokens.dart';

String richTextToPlainText(String richTextJson) {
  if (richTextJson.trim().isEmpty) {
    return '';
  }

  try {
    final document = _documentFromRichTextJson(richTextJson);
    return _trimSingleTrailingNewline(document.toPlainText());
  } catch (_) {
    return '';
  }
}

/// Sprint 4 Feature 4.3: Delta JSON が実質空か判定する。
///
/// - 空文字 / 空白のみ -> true
/// - 不正 JSON -> true (プレーン化不可なので空扱い、非空の誤判定より誤って空扱いの方が
///   削除前確認が出ずに済むので、非空判定は「確実にテキストがある」ものに限る)
/// - `[]` / `[{"insert":"\n"}]` のような改行のみ -> true
/// - insert text が非空 -> false
bool isRichTextContentEmpty(String richTextJson) {
  final plain = richTextToPlainText(richTextJson);
  return plain.trim().isEmpty;
}

class NoteRichTextEditor extends ConsumerStatefulWidget {
  const NoteRichTextEditor({
    super.key,
    required this.note,
    required this.textColor,
    required this.hintColor,
    required this.onRichTextChanged,
    this.onPlainTextChanged,
    this.externalController,
  });

  final StickyNote note;
  final Color textColor;
  final Color hintColor;
  final ValueChanged<String> onRichTextChanged;
  final ValueChanged<String>? onPlainTextChanged;
  final QuillController? externalController;

  @override
  ConsumerState<NoteRichTextEditor> createState() => _NoteRichTextEditorState();
}

class _NoteRichTextEditorState extends ConsumerState<NoteRichTextEditor> {
  late final QuillController _controller;
  late final bool _ownsController;
  late final FocusNode _focusNode;
  late final ScrollController _scrollController;
  late final VoidCallback _controllerListener;
  late String _lastEmittedJson;

  @override
  void initState() {
    super.initState();

    final document = _initialDocument(widget.note);
    _ownsController = widget.externalController == null;
    _controller =
        widget.externalController ??
        QuillController(
          document: document,
          selection: const TextSelection.collapsed(offset: 0),
        );

    if (!_ownsController) {
      _controller.document = document;
      _controller.updateSelection(
        const TextSelection.collapsed(offset: 0),
        ChangeSource.local,
      );
    }

    _focusNode = FocusNode();
    _scrollController = ScrollController();
    _lastEmittedJson = _documentToJson(_controller.document);
    _controllerListener = _handleControllerChanged;
    _controller.addListener(_controllerListener);
  }

  @override
  void dispose() {
    _controller.removeListener(_controllerListener);
    _focusNode.dispose();
    _scrollController.dispose();
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Phase 2: ユーザー選択のフォントファミリを本文に適用。
    // サブ engine 側では appSettingsProvider が独立した state を持つが、
    // 設定保存時にメインから IPC で push する仕組みは Phase 2 では省略し、
    // サブ engine 側で独自に読み直す (settings.json は共有ファイル)。
    final AppFontFamily fontFamily =
        ref.watch(appSettingsProvider).maybeWhen(
              data: (s) => s.fontFamily,
              orElse: () => AppFontFamily.hiraginoSans,
            );
    final baseStyles = DefaultStyles.getInstance(context);
    final baseTextStyle = DefaultTextStyle.of(context).style.copyWith(
          color: widget.textColor,
          fontFamily: fontFamily.macosFontName,
          fontFamilyFallback: <String>[fontFamily.fallbackFontName],
        );
    final customStyles = baseStyles.merge(
      DefaultStyles(
        paragraph: baseStyles.paragraph?.copyWith(style: baseTextStyle),
        placeHolder: baseStyles.placeHolder?.copyWith(
          style: baseTextStyle.copyWith(color: widget.hintColor),
        ),
        color: widget.textColor,
      ),
    );

    return QuillEditor(
      focusNode: _focusNode,
      scrollController: _scrollController,
      controller: _controller,
      config: QuillEditorConfig(
        placeholder: 'メモを入力',
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        expands: true,
        autoFocus: false,
        customStyles: customStyles,
      ),
    );
  }

  void _handleControllerChanged() {
    final json = _documentToJson(_controller.document);
    if (json == _lastEmittedJson) {
      return;
    }

    _lastEmittedJson = json;
    widget.onRichTextChanged(json);
    widget.onPlainTextChanged?.call(
      _trimSingleTrailingNewline(_controller.document.toPlainText()),
    );
  }
}

Document _initialDocument(StickyNote note) {
  if (note.richText.trim().isNotEmpty) {
    try {
      return _documentFromRichTextJson(note.richText);
    } catch (_) {}
  }

  return Document()..insert(0, note.text);
}

Document _documentFromRichTextJson(String richTextJson) {
  final decoded = jsonDecode(richTextJson);
  if (decoded is! List) {
    throw const FormatException('richText は List 形式である必要があります');
  }

  final delta = Delta.fromJson(decoded);
  return Document.fromJson(delta.toJson());
}

String _documentToJson(Document document) {
  return jsonEncode(document.toDelta().toJson());
}

String _trimSingleTrailingNewline(String value) {
  if (value.endsWith('\n')) {
    return value.substring(0, value.length - 1);
  }
  return value;
}
