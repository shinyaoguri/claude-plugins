---
name: gyazo-capture
description: "GUI を伴う作業 (画面・見た目・動き・操作手順) を Issue・PR に記録するとき、スクリーンショットやアニメーション WebP を Gyazo にアップロードして URL を得る (リポジトリに画像をコミットしないため)。Use when a screenshot, animated WebP or GIF, or other visual evidence needs to be attached to a GitHub issue or pull request."
allowed-tools: "mcp__gyazo-mac__gyazo_list_capturable_windows, mcp__gyazo-mac__gyazo_get_captured_image"
---

## 何を載せるか

- **見た目が変わる / 見た目を説明する** → 静止画。画面そのものは A で撮る
- **動きが分からないと正誤を判定できない** (アニメーション・遷移・ドラッグ等のインタラクション・時間依存の描画・進行してはじめて出る不具合) → **静止画に加えてアニメーション WebP**。B で載せる
- 動きは静止画の置き換えではなく**併載**。差分の精査は静止画の方が向く

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

## B. 手元のファイル (動き・画像) を載せる

MCP のツールは画面キャプチャ専用で、**手元のファイルを上げる手段がない**。Upload API を直接叩く。

1. **アニメーション WebP を作る。アプリ・ライブラリ自身が吐いたフレームから作るのが既定** (連番 PNG・フレームダンプ → `img2webp`)。画面収録と違い、他アプリの映り込みもウィンドウ位置への依存もない。目安は幅 720 / 15fps / 3〜6 秒

   ```bash
   img2webp -loop 0 -mixed -d 67 frames/frame.*.png -o motion.webp
   ```

   `-d` はフレーム間隔 (ミリ秒。15fps なら 67)。`-mixed` はフレームごとに可逆 / 非可逆を選ばせる指定で、実測ではこれが最小になる。**微細な差分を見せたい証跡では `-lossless`** を使う (サイズは増えるが 1 ビットも劣化しない)。

   **GIF ではなく WebP なのは、同じ絵で小さく・きれいだから** (2026-08-22 実測):

   | 素材 | GIF | WebP |
   |---|---|---|
   | 色数の少ない絵 (グラデ + 図形) | 916KB / PSNR 52.8dB | **375KB / 劣化なし** (可逆) |
   | 色数の多い絵 (写真的) | 277KB / PSNR **22.7dB** | **193KB / 45.1dB** |

   GIF は 256 色パレットに落とすため、色数が多い絵で目に見えて劣化する。ディザで補うとフレーム間差分が効かなくなり、今度はサイズが膨らむ — **サイズか画質かのどちらかを諦める構造**で、WebP にはこのトレードオフがない。GitHub も camo 経由で**バイト同一のまま**配信する (sha256 一致を実測)。

   幅を変えたいときは ffmpeg で連番を縮めてから渡す:

   ```bash
   ffmpeg -y -i frames/frame.%04d.png -vf "scale=720:-1:flags=lanczos" small/f.%04d.png
   ```

   GUI の操作そのものを見せたいときだけ画面収録に落とす (Gyazo GIF アプリはエージェントから駆動できないのでユーザーへ依頼、`screencapture -V` は映り込みの確認が要る)

2. **アップロードする**。返り値 `url` (`https://i.gyazo.com/<id>.webp`) をそのまま貼る。GitHub は外部画像を camo 経由で配信するが、アニメーションは保たれる

   ```bash
   curl -s -F "access_token=$(secret-read "${GYAZO_TOKEN_REF:-op://Automation/Gyazo API/credential}")" \
     -F "imagedata=@motion.webp" -F "title=<何の動きか>" https://upload.gyazo.com/api/upload
   ```

   **1 ファイル 40MB が上限** (2026-08-22 実測。38.3MB は通り、40.5MB は `413 Request Entity Too Large`)。証跡がこの桁に届くことはまずないが、届いたらフレーム数か幅を落とす。Gyazo は**縮小も再エンコードもしない** — 5250x5250 / 38.3MB がそのまま配信されることを確認済み。

3. **動きのすぐ近くに、何を撮ったのか・何を意図したのかをテキストで書く**。フレームの中身を後から人間が検める代わりの記録なので、**撮影範囲 (どのウィンドウ・どの画面か)** と **どの操作の何秒間で、どこを見てほしいか**の両方を書く

   ```markdown
   ![ドラッグ中のスナップ挙動](https://i.gyazo.com/<id>.gif)

   撮影範囲: `metaphor watch` 実行中のスケッチウィンドウのみ (他アプリ・通知は含まない)。
   意図: ドラッグ開始からグリッドにスナップするまでの約 4 秒。カーソル追従が 1 フレーム遅れる点を見てほしい。
   ```

## 守ること

- **外部サービスへの送信になる**。静止画は撮る前に、画面に秘密情報・個人情報・実データが写っていないか確かめる。判断がつかなければユーザーに確認する
- **動きの証跡はフレームを読み込んで検めない** (全フレームの画像読み込みはトークンが高く、写り込みの確率に見合わない)。代わりに B-3 のとおり**撮影範囲と意図をテキストで残す**。写り込みが後から見つかったときは、ユーザーが Gyazo 側で当該画像を削除して対処する
- アクセストークンは **`secret-read` で都度読む** (`op read` を直接呼ばない)。値を出力させない・平文の環境変数として常駐させない・チャットに貼らせない。環境変数に持たせてよいのは参照文字列 (`GYAZO_TOKEN_REF`) だけ。`secret-read` は 1Password から読んだ値を macOS Keychain にキャッシュするので、**1Password がロックされていても無人セッションが止まらない**。キャッシュしてよい参照は setup の `secret-cache-allowlist` が決めており、SSH 鍵やアカウント認証は載らない
- **`gyazo_get_captured_image` は URL と画像そのものを返す**。画像の読み込みはトークン高コストなので、URL が目的なら**呼び出しは 1 回に留める** (待ちが必要でも連打しない)
- 完了済みのキャプチャが複数あるとまとめて返る。狙った 1 枚だけが欲しいなら、キャプチャ → 取得を 1 セットずつ行う
- **リポジトリに画像・動きの証跡をコミットしない** (容量を圧迫する)
- frontmatter の `allowed-tools` に載せてあるのは読み取りの 2 つ (`gyazo_list_capturable_windows` / `gyazo_get_captured_image`) だけ。**`gyazo_capture_and_upload_*` を載せていないのは意図的**で、アップロードは外部サービスへの送信であり、写り込みの確認 (上記) を人間が飛ばせなくするため。頻度も 1 作業あたり 1〜2 回で、確認が作業の妨げにならない

## うまくいかないとき

- **`No windows found`** — Gyazo Menu.app と MCP サーバーが両方起動していても返ることがある。macOS の画面収録の許可が MCP サーバーに無いのが原因。システム設定 > プライバシーとセキュリティ > 画面収録 で Gyazo を確認する。**許可の付与は GUI 操作なので代行せず、ユーザーへ依頼する**
- **取得結果が空 / 「まだ完了していない」旨が返る** — アップロードが未完了なだけ。**間隔を空けて**もう一度呼ぶ (画像が返るコストがあるので連打しない)。**`gyazo_list_capturable_windows` がウィンドウを返せている = 画面収録の許可は足りている**ので、ここで権限を疑わない (許可が無ければ上の `No windows found` が返る)。数分待っても返らないときは回線の遅さを疑い、ユーザーへ**権限ではなく状況**を伝える
- **`isn't a vault in this account`** — vault 名かアイテム名の間違い。`op vault list` / `op item list --vault <name>` で実体を確かめる (値は表示しない)
- **`secret-read: command not found`** — setup リポジトリの `bin/` が PATH に無い。恒久対処は `ansible-playbook playbook_sillicon_mac.yml --tags zshrc` で symlink を張り直すこと (個人環境では zshenv が PATH を通す)。その場で続けたいときは順に:
  1. **絶対パスで呼ぶ** — `~/.setup/bin/secret-read "$GYAZO_TOKEN_REF"`。実体はここにあるので、PATH が通っていないだけならこれで足りる。**Keychain キャッシュが効くので 1Password のロックに依存しない**
  2. setup リポジトリ自体が無い環境のときだけ `op read` へ読み替える。**1Password のロック解除が要るので、無人セッションでは承認待ちで止まる** (実際に 2 分ハングした事例がある)。最後の手段として扱う
- **アップロードが `unauthorized`** — まず `secret-read --refresh "$GYAZO_TOKEN_REF"` を試す (Gyazo 側でトークンを作り直したのに Keychain のキャッシュが古いままだと、これで直る)。それでも通らなければトークン自体を発行し直す。https://gyazo.com/oauth/applications でアプリを登録して発行する。OAuth フローは不要で、developer ページで出せるトークン 1 本でよい
- **動きはアニメーション WebP で載せる。mp4 は経路が無い** (2026-08-22 実測)。MCP 側に動画キャプチャは無く、**Gyazo の Upload API は mp4 を `400 Not an Image` で拒む — Pro アカウントでも同じ**。GitHub 側も外部 URL の mp4 は貼れず、`<video>` タグは**属性ではなく要素ごと**サニタイズで消える (Markdown の `![](...)` に mp4 を渡すと camo が画像として扱い、壊れた画像になる)。GitHub が再生するのは Issue / PR へ**直接アップロード**した mp4 だけで、そこには公式 API が無いためエージェントからは扱えない
- 上記で解決しないこのスキル自体の不具合・使いにくさは、report-issue スキルで shinyaoguri/claude-plugins へ気軽に起票する (Gyazo アプリ本体の不具合は起票せずユーザーへ報告)

## 前提

- macOS は Gyazo v9.9.0 以降 / Windows は v5.8.0 以降。MCP サーバーの登録は setup の `tasks/claude.yml` が行う (バイナリは cask の gyazo が入れる)
- 開発者向けプレビュー版のため仕様変更の可能性があり、公式サポート対象外
- B は `img2webp` (連番から動きを作る場合。`brew install webp`) と `secret-read` を使う。幅を変えるときだけ `ffmpeg` も要る。`secret-read` は setup リポジトリの `bin/` にあり、zshenv が PATH へ通す (値は macOS Keychain から読み、**キャッシュが無いときだけ** `op` = 1Password CLI を呼ぶ)
