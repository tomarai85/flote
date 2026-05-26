# Flutter デスクトップ開発用ターゲット (Sprint 6 で dist-* を実装)

.DEFAULT_GOAL := help

.PHONY: help build-mac build-win run-mac run-win clean dist-mac dist-win icons analyze test

help:
	@echo "Available targets:"
	@echo "  help       - 利用可能なターゲット一覧を表示"
	@echo "  build-mac  - macOS リリースビルドを実行"
	@echo "  build-win  - Windows リリースビルドを実行"
	@echo "  run-mac    - macOS でデバッグ実行"
	@echo "  run-win    - Windows でデバッグ実行"
	@echo "  clean      - Flutter と build 出力を削除"
	@echo "  dist-mac   - macOS 配布用ビルド (dmg + ad-hoc 署名) を作成"
	@echo "  dist-win   - Windows 配布用 Zip をローカル (PowerShell) で作成する案内"
	@echo "  icons      - flutter_launcher_icons で macOS/Windows アイコンを生成"
	@echo "  analyze    - flutter analyze を実行"
	@echo "  test       - flutter test を実行"

build-mac:
	flutter build macos --release

build-win:
	flutter build windows --release

run-mac:
	flutter run -d macos

run-win:
	flutter run -d windows

clean:
	flutter clean && rm -rf build dist

# Sprint 6 Feature 6.2: ad-hoc dmg スクリプト経由
dist-mac:
	./scripts/dist-mac.sh

# Sprint 6 Feature 6.3: Windows 配布は通常 GitHub Actions (build-windows.yml)。
# ローカル (Windows 上) で検証したい場合のみ scripts/dist-win.ps1 を直接 pwsh で実行する。
dist-win:
	@echo "Windows 配布は通常 .github/workflows/build-windows.yml で実行します。"
	@echo "ローカル (Windows PowerShell) からは 'pwsh scripts/dist-win.ps1' を直接実行してください。"
	@echo "(参考) GitHub Actions 手動実行は Actions タブから 'Build Windows' を workflow_dispatch で起動。"

# Sprint 6 Feature 6.1: アイコン生成 (flutter_launcher_icons)
icons:
	dart run flutter_launcher_icons

analyze:
	flutter analyze

test:
	flutter test
