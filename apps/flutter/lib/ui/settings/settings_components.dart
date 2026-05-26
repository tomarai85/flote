// Settings 画面の共通部品をまとめた UI コンポーネント集。
//
// セクション枠、2 カラム行、簡易タイル、区切り線を定義し、
// SettingsWindow 配下の 6 セクションで統一した見た目を維持する。

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// Settings の 1 セクション全体を包む共通ラッパー。
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    required this.heading,
    required this.children,
    super.key,
    this.description,
    this.headerTrailing,
    this.padding,
  });

  final String heading;
  final String? description;
  final Widget? headerTrailing;
  final List<Widget> children;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(RadiusTokens.large),
        border: Border.all(
          color: ColorTokens.onSurfaceMuted.withValues(alpha: 0.14),
        ),
        boxShadow: [
          BoxShadow(
            color: ColorTokens.onSurface.withValues(alpha: 0.04),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Scrollbar(
        thumbVisibility: false,
        child: SingleChildScrollView(
          padding: padding ??
              const EdgeInsets.all(
                SpacingTokens.lg,
              ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          heading,
                          style: TypographyTokens.heading.copyWith(
                            color: ColorTokens.onSurface,
                          ),
                        ),
                        if (description != null) ...[
                          const SizedBox(height: SpacingTokens.xs),
                          Text(
                            description!,
                            style: TypographyTokens.body.copyWith(
                              color: ColorTokens.onSurfaceMuted,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (headerTrailing != null) ...[
                    const SizedBox(width: SpacingTokens.md),
                    headerTrailing!,
                  ],
                ],
              ),
              const SizedBox(height: SpacingTokens.lg),
              ..._withSpacing(children),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _withSpacing(List<Widget> items) {
    final spaced = <Widget>[];
    for (var index = 0; index < items.length; index++) {
      spaced.add(items[index]);
      if (index < items.length - 1) {
        spaced.add(const SizedBox(height: SpacingTokens.md));
      }
    }
    return spaced;
  }
}

/// 左ラベル + 右コンテンツの 2 カラム行。
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    required this.label,
    required this.child,
    super.key,
    this.description,
    this.labelWidth = 140,
    this.crossAxisAlignment = CrossAxisAlignment.center,
  });

  final String label;
  final String? description;
  final Widget child;
  final double labelWidth;
  final CrossAxisAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 640;
        if (isCompact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _LabelBlock(label: label, description: description),
              const SizedBox(height: SpacingTokens.sm),
              child,
            ],
          );
        }

        return Row(
          crossAxisAlignment: crossAxisAlignment,
          children: [
            SizedBox(
              width: labelWidth,
              child: _LabelBlock(label: label, description: description),
            ),
            const SizedBox(width: SpacingTokens.md),
            Expanded(child: child),
          ],
        );
      },
    );
  }
}

class _LabelBlock extends StatelessWidget {
  const _LabelBlock({
    required this.label,
    this.description,
  });

  final String label;
  final String? description;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TypographyTokens.bodyBold.copyWith(
            color: ColorTokens.onSurface,
          ),
        ),
        if (description != null) ...[
          const SizedBox(height: SpacingTokens.xs),
          Text(
            description!,
            style: TypographyTokens.caption.copyWith(
              color: ColorTokens.onSurfaceMuted,
            ),
          ),
        ],
      ],
    );
  }
}

/// ListTile 風の軽量タイル。
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    required this.title,
    super.key,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.isSelected = false,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isSelected
          ? ColorTokens.accent.withValues(alpha: 0.12)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(RadiusTokens.medium),
      child: InkWell(
        borderRadius: BorderRadius.circular(RadiusTokens.medium),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: SpacingTokens.md,
            vertical: SpacingTokens.sm,
          ),
          child: Row(
            children: [
              if (leading != null) ...[
                leading!,
                const SizedBox(width: SpacingTokens.sm),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TypographyTokens.bodyBold.copyWith(
                        color: ColorTokens.onSurface,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: SpacingTokens.xs),
                      Text(
                        subtitle!,
                        style: TypographyTokens.caption.copyWith(
                          color: ColorTokens.onSurfaceMuted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: SpacingTokens.sm),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// セクション内の薄い区切り線。
class SettingsDivider extends StatelessWidget {
  const SettingsDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      thickness: 1,
      color: ColorTokens.onSurfaceMuted.withValues(alpha: 0.14),
    );
  }
}
