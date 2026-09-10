import SwiftUI

struct MenuBarView: View {
    var body: some View {
        Button(L("新規ノート", "New Note")) {
            let note = NoteManager.shared.createNote()
            PanelManager.shared.createPanel(for: note, focus: true)
        }
        .keyboardShortcut(" ", modifiers: [.option])

        Button(L("ノートを検索", "Search Notes")) {
            SearchPaletteController.shared.show()
        }
        .keyboardShortcut(" ", modifiers: [.option, .shift])

        Button(L("ノートを整列", "Tidy Notes")) {
            PanelManager.shared.tidyVisiblePanels()
        }

        Button(L("新機能を見る", "What's New")) {
            openWhatsNewNote()
        }

        Divider()

        // S6 recents (Codex UX-gap #8): one-click return to what you were
        // just writing. MenuBarExtra(.menu) re-evaluates body on every open,
        // so this list is always current — no observation plumbing needed.
        let recents = Self.recentNotes()
        if !recents.isEmpty {
            Text(L("最近のノート", "Recent notes"))
            ForEach(recents, id: \.id) { note in
                Button(Self.menuTitle(for: note)) {
                    openOrFocus(note.id)
                }
            }
            Divider()
        }

        Button(L("設定…", "Settings…")) {
            SettingsWindowController.shared.show()
        }
        .keyboardShortcut(",", modifiers: .command)

        Button(L("グループを見る…", "View Groups…")) {
            SettingsWindowController.shared.show(section: .groups)
        }

        Button(L("履歴を見る…", "View History…")) {
            SettingsWindowController.shared.show(section: .history)
        }

        Divider()

        Button(L("Flote を再起動", "Restart Flote")) {
            restartApp()
        }

        Button(L("Flote を終了", "Quit Flote")) {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    // MARK: - Recents (S6)

    /// Last 5 notes worth returning to: non-deleted, non-empty, newest
    /// modification first. Computed on menu open — 5 items, no caching.
    private static func recentNotes() -> [StickyNote] {
        Array(
            NoteManager.shared.notes
                .filter {
                    $0.deletedAt == nil
                        && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                .sorted { $0.modifiedAt > $1.modifiedAt }
                .prefix(5)
        )
    }

    /// displayTitle skips checkbox/bullet lines by design (scroll labels);
    /// a note that is ALL checkboxes would come back nil, so fall back to
    /// its literal first line before giving up to 無題.
    private static func menuTitle(for note: StickyNote) -> String {
        // lockedSafeTitle is the ONLY title accessor (r3b NEW-1) — the old
        // displayTitle-first order made the lock guard unreachable.
        if note.isLocked { return note.lockedSafeTitle ?? L("ロック中のノート", "Locked note") }
        if let t = note.lockedSafeTitle { return t }
        let firstLine = note.text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return firstLine.isEmpty ? L("無題", "Untitled") : String(firstLine.prefix(12))
    }

    /// S7 discovery ("パッと見なにも増えてない" fix): the features live
    /// inside interactions, so nothing announces itself. This opens ONE
    /// feature-map note. Idempotent: the note id is persisted; re-click
    /// focuses it; recreated only if the user deleted it. The note is never
    /// updated in place — user edits are theirs (content protection).
    ///
    /// KEY VERSIONING: the map was rewritten for the v45-v56 feature wave
    /// (calc/units/currency, timers, themes, backup, send-to, …). Updating
    /// an existing map note in place would overwrite user edits, so a NEW
    /// key mints a fresh note instead — the old map simply stays behind as
    /// a normal user note. Bump the suffix whenever the map is rewritten.
    private static let whatsNewNoteIDKey = "floteWhatsNewNoteID.v2"

    private func openWhatsNewNote() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Self.whatsNewNoteIDKey),
           let id = UUID(uuidString: raw),
           NoteManager.shared.note(byID: id) != nil {
            openOrFocus(id)
            return
        }
        let note = NoteManager.shared.createNote()
        let text = Self.whatsNewText()
        NoteManager.shared.updateText(id: note.id, text: text)
        NoteManager.shared.updateRolledTitle(
            id: note.id, title: L("Flote の使い方地図", "Flote feature map"))
        defaults.set(note.id.uuidString, forKey: Self.whatsNewNoteIDKey)
        PanelManager.shared.createPanel(for: NoteManager.shared.note(byID: note.id) ?? note, focus: true)
        PanelManager.shared.reloadTextView(for: note.id, data: nil, plain: text)
    }

    /// The single discovery index for everything that ships in-hand but
    /// announces nothing. Organized by situation (書く / 計算する / 整える /
    /// 守る / 繋ぐ); every line carries the EXACT trigger, verified against
    /// the shipped code (RichTextEditor calc/units/currency/aggregates/
    /// markdown/links/OCR, TimerEngine syntax, ShortcutNames defaults,
    /// FloteThemeRegistry count, NoteView menus, SettingsView sections).
    /// The # section lines and **bold**/`code` tokens double as a live
    /// demo of the markdown render. Checkboxes make it a try-it list.
    private static func whatsNewText() -> String {
        L("""
          Flote の使い方地図（このノートは消してOK）

          # 書く
          [ ] ⌥Space どこにいても新しい付箋
          [ ] 1行目に list か リスト とだけ書くと、続く行が全部チェックボックスに
          [ ] [ ] の行末で /x と打つとチェックが付く（/x は消える）
          [ ] ⌘V は書式を捨てて貼り付け。そのまま貼るなら ⌘⇧V
          [ ] 画像をドロップ → 中の文字がテキストになる（Mac の外に出ない）
          [ ] # 見出し・**太字**・`コード` と打つと、その場で見た目が変わる
          [ ] 長い URL は自動で短く畳まれる。⌘⏎ で開く
          [ ] コピーボタン（ノート上部）を右クリック → クリップボード収集。コピーした物が全部たまる

          # 計算する・計る
          [ ] 34x213= と打つと答え。% ^ ! sqrt( log( も使える
          [ ] 出た答えはクリックでコピー
          [ ] 幅 : 58 と書くと変数。幅*2= が効き、58 を書き換えると答えも追従
          [ ] 58cm to in= で単位変換
          [ ] 10 USD to JPY= で為替。$10 to 円= や BTC も
          [ ] 数字を並べた下の行で sum=（合計=）avg=（平均=）count=
          [ ] 1行目に timer 5 → 5分タイマー。timer 25 5 でポモドーロ

          # 整える
          [ ] Organize で AI が整理。「戻す」でいつでも原文へ
          [ ] 本文を右クリック → AI 変換。Organize ピル右クリックにも同じメニュー
          [ ] ∧（巻き取り）→ 風船みたいに飛んで、上端に紐が残る。紐をタップで戻る
          [ ] ⌥⇧A で全ノートを一気にかくす / もどす
          [ ] ⌥⇧Space で全ノートを検索
          [ ] メニューバー → ノートを整列
          [ ] 端をドラッグで自由にサイズ変更。基本サイズは 設定 > 外観（小・中・大）
          [ ] テーマ 21 種（ダーク 6 種）と 和紙・金属・ガラスの質感 → 設定 > 外観
          [ ] 空っぽのノートは閉じると自動で消える

          # 守る
          [ ] 明日15時 と書いた行を右クリック → その時刻にリマインド
          [ ] Organize ピルを右クリック → Touch ID でロック
          [ ] 設定 > バックアップ → 今すぐバックアップ / 復元

          # 繋ぐ
          [ ] コピーボタンを右クリック → 送信 → Apple Notes / Obsidian / Bear
          [ ] 同じメニューから TXT / Markdown / PDF に書き出し
          """,
          """
          Flote feature map (safe to delete)

          # Write
          [ ] ⌥Space — a new note from anywhere
          [ ] A first line of just list turns every line you write into a checkbox
          [ ] Type /x at the end of a [ ] line to check it off (the /x vanishes)
          [ ] ⌘V pastes clean text. ⌘⇧V pastes as-is
          [ ] Drop an image → its text is pulled out (never leaves this Mac)
          [ ] Type # heading, **bold**, `code` — they render as you type
          [ ] Long URLs fold themselves. ⌘⏎ opens the one at the caret
          [ ] Right-click the copy button (top of a note) → Collect clipboard: everything you copy lands here

          # Calculate & time
          [ ] Type 34x213= for the answer. % ^ ! sqrt( log( work too
          [ ] Click an answer to copy it
          [ ] width : 58 makes a variable. width*2= works, and editing the 58 updates every answer
          [ ] 58cm to in= converts units
          [ ] 10 USD to JPY= converts money. $10 to JPY= and BTC too
          [ ] On a line under numbers: sum= avg= count=
          [ ] First line timer 5 → a 5-minute timer. timer 25 5 = pomodoro

          # Tidy
          [ ] Organize lets AI clean up. Revert brings the original back anytime
          [ ] Right-click the text → AI transform. Same menu on the Organize pill
          [ ] ∧ (roll up) → the note floats off like a balloon; a string stays at the top. Tap it to pull the note back
          [ ] ⌥⇧A hides / shows every note at once
          [ ] ⌥⇧Space searches across all notes
          [ ] Menu bar → Tidy Notes lines them up
          [ ] Drag any edge to resize. Default size: Settings > Appearance (S / M / L)
          [ ] 21 themes (6 dark) plus washi, metal, glass textures → Settings > Appearance
          [ ] An empty note removes itself when closed

          # Protect
          [ ] Write tomorrow 3pm in a line, right-click it → a reminder at that exact time
          [ ] Right-click the Organize pill → lock with Touch ID
          [ ] Settings > Backup → Back up now / Restore

          # Connect
          [ ] Right-click the copy button → Send to → Apple Notes / Obsidian / Bear
          [ ] Same menu: export as TXT / Markdown / PDF
          """)
    }

    /// Same open-or-focus path as the Groups tab (SettingsView card tap):
    /// focus the live panel, or re-open a closed note on screen.
    private func openOrFocus(_ noteID: UUID) {
        if PanelManager.shared.hasPanel(noteID: noteID) {
            PanelManager.shared.focusPanel(noteID: noteID)
        } else {
            NoteManager.shared.openPanel(noteID: noteID)
            if let updated = NoteManager.shared.note(byID: noteID) {
                PanelManager.shared.createPanel(for: updated)
            }
        }
    }

    private func restartApp() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
