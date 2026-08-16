---
name: gyazo-capture
description: "GUI を伴う作業 (画面・見た目・動き・操作手順) を Issue・PR に記録するとき、スクリーンショットや GIF を Gyazo にアップロードして URL を得る (リポジトリに画像をコミットしないため)。Use when a screenshot, animated GIF, or other visual evidence needs to be attached to a GitHub issue or pull request."
---

## 何を載せるか

- **見た目が変わる / 見た目を説明する** → 静止画。画面そのものは A で撮る
- **動きが分からないと正誤を判定できない** (アニメーション・遷移・ドラッグ等のインタラクション・時間依存の描画・進行してはじめて出る不具合) → **静止画に加えて GIF**。B で載せる
- GIF は静止画の置き換えではなく**併載**。差分の精査は静止画の方が向く

## A. 画面を撮る (MCP)

1. **何を撮るか決める。ウィンドウ単位が既定** (全画面は他アプリの内容・通知・個人情報が写り込む)

   ```
   gyazo_list_capturable_windows     # windowId / アプリ名 / タイトルの一覧
   gyazo_capture_and_upload_window   # windowId を指定して撮る
   ```

2. アップロードの完了を**待ってから** URL を取得する。投入から取得まで **30〜60 秒**は見込む (回線が細いと数分かかる)。待たずに呼ぶと未完了が返るだけで、そのぶん画像取得のコストだけ払うことになる

   ```
   gyazo_get_captured_image
   ```

3. `![説明](URL)` の形で Issue・PR の本文に貼る。何の画面か・どこを見てほしいかを本文で補う (画像だけでは検索に引っかからない)

## B. 手元のファイル (GIF・画像) を載せる

MCP のツールは画面キャプチャ専用で、**手元のファイルを上げる手段がない**。Upload API を直接叩く。

1. **GIF を作る。アプリ・ライブラリ自身が吐いたフレームから作るのが既定** (連番 PNG・フレームダンプ → ffmpeg)。画面収録と違い、他アプリの映り込みもウィンドウ位置への依存もない。目安は幅 720 / 15fps / 3〜6 秒

   ```bash
   ffmpeg -y -framerate 15 -start_number 0 -i frames/frame.%04d.png \
     -filter_complex "[0:v]fps=15,scale=720:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5" \
     -loop 0 motion.gif
   ```

   GUI の操作そのものを見せたいときだけ画面収録に落とす (Gyazo GIF アプリはエージェントから駆動できないのでユーザーへ依頼、`screencapture -V` は映り込みの確認が要る)

2. **アップロードする**。返り値 `url` (`https://i.gyazo.com/<id>.gif`) をそのまま貼る。GitHub は外部画像を camo 経由で配信するが、アニメーションは保たれる

   ```bash
   curl -s -F "access_token=$(secret-read "${GYAZO_TOKEN_REF:-op://Automation/Gyazo API/credential}")" \
     -F "imagedata=@motion.gif" -F "title=<何の動きか>" https://upload.gyazo.com/api/upload
   ```

3. **GIF のすぐ近くに、何を撮ったのか・何を意図したのかをテキストで書く**。フレームの中身を後から人間が検める代わりの記録なので、**撮影範囲 (どのウィンドウ・どの画面か)** と **どの操作の何秒間で、どこを見てほしいか**の両方を書く

   ```markdown
   ![ドラッグ中のスナップ挙動](https://i.gyazo.com/<id>.gif)

   撮影範囲: `metaphor watch` 実行中のスケッチウィンドウのみ (他アプリ・通知は含まない)。
   意図: ドラッグ開始からグリッドにスナップするまでの約 4 秒。カーソル追従が 1 フレーム遅れる点を見てほしい。
   ```

## 守ること

- **外部サービスへの送信になる**。静止画は撮る前に、画面に秘密情報・個人情報・実データが写っていないか確かめる。判断がつかなければユーザーに確認する
- **GIF はフレームを読み込んで検めない** (全フレームの画像読み込みはトークンが高く、写り込みの確率に見合わない)。代わりに B-3 のとおり**撮影範囲と意図をテキストで残す**。写り込みが後から見つかったときは、ユーザーが Gyazo 側で当該画像を削除して対処する
- アクセストークンは **`secret-read` で都度読む** (`op read` を直接呼ばない)。値を出力させない・平文の環境変数として常駐させない・チャットに貼らせない。環境変数に持たせてよいのは参照文字列 (`GYAZO_TOKEN_REF`) だけ。`secret-read` は 1Password から読んだ値を macOS Keychain にキャッシュするので、**1Password がロックされていても無人セッションが止まらない**。キャッシュしてよい参照は setup の `secret-cache-allowlist` が決めており、SSH 鍵やアカウント認証は載らない
- **`gyazo_get_captured_image` は URL と画像そのものを返す**。画像の読み込みはトークン高コストなので、URL が目的なら**呼び出しは 1 回に留める** (待ちが必要でも連打しない)
- 完了済みのキャプチャが複数あるとまとめて返る。狙った 1 枚だけが欲しいなら、キャプチャ → 取得を 1 セットずつ行う
- **リポジトリに画像・GIF をコミットしない** (容量を圧迫する)

## うまくいかないとき

- **`No windows found`** — Gyazo Menu.app と MCP サーバーが両方起動していても返ることがある。macOS の画面収録の許可が MCP サーバーに無いのが原因。システム設定 > プライバシーとセキュリティ > 画面収録 で Gyazo を確認する。**許可の付与は GUI 操作なので代行せず、ユーザーへ依頼する**
- **取得結果が空 / 「まだ完了していない」旨が返る** — アップロードが未完了なだけ。**間隔を空けて**もう一度呼ぶ (画像が返るコストがあるので連打しない)。**`gyazo_list_capturable_windows` がウィンドウを返せている = 画面収録の許可は足りている**ので、ここで権限を疑わない (許可が無ければ上の `No windows found` が返る)。数分待っても返らないときは回線の遅さを疑い、ユーザーへ**権限ではなく状況**を伝える
- **`isn't a vault in this account`** — vault 名かアイテム名の間違い。`op vault list` / `op item list --vault <name>` で実体を確かめる (値は表示しない)
- **`secret-read: command not found`** — setup リポジトリの `bin/` が PATH に無い。個人環境では zshenv が通すので、`ansible-playbook playbook_sillicon_mac.yml --tags zshrc` で symlink を張り直す。応急処置として `op read` に読み替えてもよい (その場合 1Password のロック解除が要る)
- **アップロードが `unauthorized`** — まず `secret-read --refresh "$GYAZO_TOKEN_REF"` を試す (Gyazo 側でトークンを作り直したのに Keychain のキャッシュが古いままだと、これで直る)。それでも通らなければトークン自体を発行し直す。https://gyazo.com/oauth/applications でアプリを登録して発行する。OAuth フローは不要で、developer ページで出せるトークン 1 本でよい
- MCP 側での動画キャプチャは非対応 (mp4 のアップロードは Gyazo Pro / Teams のみ。GIF は B で載せる)
- 上記で解決しないこのスキル自体の不具合・使いにくさは、report-issue スキルで shinyaoguri/claude-plugins へ気軽に起票する (Gyazo アプリ本体の不具合は起票せずユーザーへ報告)

## 前提

- macOS は Gyazo v9.9.0 以降 / Windows は v5.8.0 以降。MCP サーバーの登録は setup の `tasks/claude.yml` が行う (バイナリは cask の gyazo が入れる)
- 開発者向けプレビュー版のため仕様変更の可能性があり、公式サポート対象外
- B は `ffmpeg` (連番から GIF を作る場合) と `secret-read` を使う。`secret-read` は setup リポジトリの `bin/` にあり、zshenv が PATH へ通す (内部で `op` = 1Password CLI を呼ぶ)
