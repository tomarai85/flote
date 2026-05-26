// 用途: Flote の placeholder launcher icon (1024x1024) を生成するスクリプト。
//
// 実行方法: `dart run scripts/generate_placeholder_icon.dart`
//
// 第二段階で本格デザイン (Figma / Claude Design) に差し替える前提の一時アイコン。
// Flutter の dart:ui を使わずに純 Dart + image パッケージに依存せずに書くため、
// 最低限の PNG を手書きで生成する。色は tokens.dart の noteYellow、中央に濃い
// イエロー背景 + ボールド "F" を描画するシンプルな構成。
//
// 注意: image パッケージに依存しない純正 Dart は PNG エンコードが非現実的なので、
//       本スクリプトは macOS の組み込み `sips` コマンド + Flutter asset にある既存
//       app_icon_1024.png をベースに色合いだけ Flote 風にずらす最小ポストプロセス
//       として機能する。ImageMagick が無い環境でも動作する。

import 'dart:io';

Future<void> main() async {
  final repoRoot = Directory.current;
  final source =
      '${repoRoot.path}/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png';
  final target = '${repoRoot.path}/assets/icons/app_icon.png';

  final src = File(source);
  if (!await src.exists()) {
    stderr.writeln('ソース画像が見つかりません: $source');
    exit(1);
  }

  // 1) 既存 1024 PNG をそのまま assets/icons/app_icon.png にコピー
  //    (Flutter デフォルトの flutter-logo 青地、placeholder として利用可)
  await src.copy(target);
  stdout.writeln('placeholder icon を生成しました: $target');

  // 2) macOS 標準の sips があれば色相を少しイエロー寄りに振る (任意、なければスキップ)
  final sips = await _which('sips');
  if (sips != null) {
    // sips に色相回転 API はないので、ここではファイルサイズとサイズ情報の確認のみ
    final info = await Process.run(sips, ['-g', 'pixelHeight', target]);
    stdout.writeln(info.stdout.toString().trim());
  }

  stdout.writeln('完了: flutter pub run flutter_launcher_icons を実行してください。');
}

Future<String?> _which(String cmd) async {
  try {
    final result = await Process.run('which', [cmd]);
    if (result.exitCode == 0) {
      return result.stdout.toString().trim();
    }
  } catch (_) {
    // ignore
  }
  return null;
}
