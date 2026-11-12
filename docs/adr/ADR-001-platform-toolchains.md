# ADR-001: 対象OS・runner・初期ツールチェーン

- 状態: ARM64対象を追加。GitHub CIと最低対応OSの実機検証後に確定する
- 決定日: 2026-11-08

## 背景

初版はWindows 11 x64 / ARM64、Ubuntu 24.04 LTS x64 / ARM64、macOS 14以降のarm64 / x64を候補とする。Tauriのネイティブ依存とWebViewはOS・architectureごとに異なるため、クロスコンパイルだけで対応可とは判定しない。

## 決定

### 製品サポート候補

| OS / arch | 最低版候補 | WebView | 実機候補 |
|---|---|---|---|
| Windows x64 | Windows 11 | WebView2 Evergreen | Windows 11 x64のIntel / AMDノートPC |
| Windows ARM64 | Windows 11 | WebView2 Evergreen ARM64 | Windows 11 ARM64のSnapdragon搭載PC |
| Ubuntu x64 | Ubuntu 24.04 LTS | WebKitGTK 4.1 | Ubuntu 24.04 x64をクリーンインストールしたIntel / AMDノートPC |
| Ubuntu ARM64 | Ubuntu 24.04 LTS | WebKitGTK 4.1 | Ubuntu 24.04 ARM64をクリーンインストールした対応SoC機 |
| macOS arm64 | macOS 14 | WKWebView | Apple Silicon MacBook Air (M1以降) |
| macOS x64 | macOS 14 | WKWebView | Intel Mac mini (2018)またはmacOS 14対応Intel MacBook Pro |

上記は実機の合格証跡ではなく、調達・借用する試験候補。各OS / architectureでnative build、起動、WebView、SecretStore、IME、インストールを検証してから最低版を確定する。LinuxはUbuntu 24.04 LTS以外のディストリビューションを初版対象外とする。

### CI runner候補

| 検証対象 | GitHub-hosted runner |
|---|---|
| Ubuntu x64 | `ubuntu-24.04` |
| Ubuntu ARM64 | `ubuntu-24.04-arm` |
| Windows x64 | `windows-2025` |
| Windows ARM64 | `windows-11-arm` |
| macOS arm64 | `macos-15` |
| macOS x64 | `macos-15-intel` |

GitHub-hosted runnerの公式一覧でラベルとarchを確認した（2026-11-08）。ARM64 runnerは対象リポジトリのプランで利用可能性・料金を確認する。runner上の成功は最低対応OSの実機検証を代替しない。

2026-11-12更新: native Run 642で`macos-14-arm64-us-default`がunsupportedとして実行前に拒否されたため、公式一覧にARM64として掲載されている`macos-15`へ変更する。CI targetと手動入力も`macos-15-arm64`へ揃える。これはrunner更新であり、製品の最低OS候補macOS 14や最低OS実機検証要件を変更しない。先行する同リポジトリのRun 624で同runnerのfull検証成功を確認済み。

### 固定ツールチェーン

| 項目 | 固定値 |
|---|---|
| Node.js | 26.13.1 (LTS) |
| pnpm | 12.14.0 |
| Rust | 1.99.1、`clippy` / `rustfmt` component |
| Tauri CLI | 2.12.3 |
| Tauri JS API | 2.12.4 |
| Tauri Rust crate / build crate | 2.12.4 / 2.7.3 (`Cargo.lock`) |
| Vue | 3.5.44 |
| TypeScript | 6.0.3、strict |
| Vite | 8.3.4 |
| pnpm lock | `pnpm-lock.yaml`、frozen install |
| Cargo lock | workspace rootの`Cargo.lock`、`--locked` |

バージョンは公式配布情報とregistryで確認した時点の固定値。Tauri 1の設定・APIは使わない。

2026-11-12にNode.js 26.13.1 (LTS)へ更新。公式release indexで26系がLTS、26.13.1が現行patchとして掲載されていることを確認した。pnpm 12.14.0のNode engineは`>=18`のため、この固定版を満たす。Node 24.22.0への参照は過去の検証履歴であり、現在の開発・CI pinではない。

開発環境はNode公式Debian Bookwormイメージのdigest固定Dev Containerとし、Linux向けTauri依存、Xvfb、D-Bus、Rust toolchainを含める。Docker Desktop上ではlinux/arm64で動作するが、これはLinux arm64の製品サポートを意味しない。

### Windows ARM64ローカル検証

Visual Studio Build ToolsのARM64 C++ toolsとWindows SDKに加え、`ring`のビルドにはC++ Clang component（`Microsoft.VisualStudio.Component.VC.Llvm.Clang`）が必要。MSVC環境を初期化するだけでは`clang`が見つからない場合があるため、ARM64 Clangの`bin`を同じプロセスのPATHへ追加する。2026-11-09のローカル検証では次の手順でsecurity-test buildと実WebView試験が成功した。インストール先は環境に合わせて変更する。

```powershell
$env:PATH = 'C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Tools\Llvm\ARM64\bin;' + $env:PATH
& $env:ComSpec /c 'call "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvarsarm64.bat" >nul && pnpm exec tauri build --no-bundle --ci --features security-test --config src-tauri/tauri.security-test.conf.json'
if ($LASTEXITCODE -ne 0) { throw 'ARM64 security-test build failed' }
pnpm exec wdio run .\wdio.security.conf.mjs
```

実Procmon監査は管理者権限と操作可能なデスクトップが必要。Microsoft署名を検証した`Procmon64a.exe`を`MAIL_CLIENT_PROCMON_PATH`へ設定して`pnpm run test:security:file-access:windows`を実行する。他のProcmon captureが動作中なら実行しない。実WebView試験単体の成功や合成foreground拒否fixtureの成功を、Procmon file-access auditの成功へ読み替えない。`security-test`バイナリは配布用ではなく、通常本番buildでは引き続きテストplugin除外を検証する。

## 選択肢

- OS標準の最新node/rustをそのまま使う: 再現性が低いため不採用。
- 1つのLinux runnerから全OSへcross-compile: WebView・OS依存build・実機起動を検証できないため不採用。
- macOSを単一archに限定: 初期設計のarm64 / x64要件を満たさないため不採用。

## 結果と制限

- `native.yml`は6 runner候補でformat、Rust test/clippy、frontend build、native build、smoke launch/exitを実行する。Windows ARM64ではnative Procmon executable `Procmon64a.exe`を使用する。
- Linux CIはWebKitGTK 4.1依存を導入する。Windows runnerのWebView2 / MSVC、macOS runnerのXcode提供環境はGitHub-hosted imageに依存する。
- ARM64を含む追加matrixは設定済みだが、runner上のnative build / WebView / smokeの実行結果と最低OS実機試験は未確認。
- Tauri起動smoke testは`smoke-test` Cargo featureでのみ自動終了処理を有効にする。通常buildにはfeatureを含めない。
- 署名、公証、installer、最低OSの実機確認は本ADRの対象外。

## 再評価条件

runnerラベルの廃止、OS/WebViewのサポート終了、Rust/Node/Tauriの互換性問題、または最低OS実機試験の失敗があれば更新する。

## 根拠

- [Tauri prerequisites](https://v2.tauri.app/start/prerequisites/)
- [GitHub-hosted runners reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)（ubuntu-24.04-arm / windows-11-armを含むrunner architecture一覧）
- [Tauri configuration reference](https://v2.tauri.app/reference/config/)
- [Node.js release index](https://nodejs.org/dist/index.json)
- [Rust stable channel manifest](https://static.rust-lang.org/dist/channel-rust-stable.toml)
