# pi-pan-guardian

Raspberry Pi Zero 2 W の **Bluetooth PAN (NAP)** と Ubuntu Host の **PANU** を既存の NetworkManager プロファイルのまま維持し、切断時の再アクティベーション、任意で有効化できる Wi-Fi 復旧 AP、Bash + `fzf` の TUI を提供します。

> **実機では未検証。** 既存 PAN (`pi-bt-pan`, `btnap0`, `192.168.44.1`) と Ubuntu (`pi-zero2w-pan`, `98:FE:54:9C:41:B1`) を基準に作成。`bash -n`、モックテスト、インストーラのダウンロード整合性検証を実施。実機インストールは未実施。

## 1. GitHubへ公開後のインストール

公開リポジトリ: `github.com/yohi/Pi`。以下のURLは `master` にファイルが反映された後に使用できます。

### Pi Zero 2 W (Debian / Raspberry Pi OS, NetworkManager 使用)

```sh
curl -fsSL https://raw.githubusercontent.com/yohi/Pi/master/install.sh | sudo sh -s -- --role pi
sudo pi-panctl tui
```

### Ubuntu PC (Host)

```sh
curl -fsSL https://raw.githubusercontent.com/yohi/Pi/master/install.sh | sudo sh -s -- --role host
sudo pi-panctl tui
```

異なるリポジトリの場合は `PG_REPO=owner/repo` を `sudo env` 経由で渡し、インストールURLも合わせて変更してください。実運用では `master` ではなく**レビュー済みcommit SHA** でインストールURLと `--ref` を揃えて固定することを推奨します。`curl | sh` は取得したシェルコードをrootで実行するため、事前確認が必要です。

```sh
# Alternative: inspect first and run a local copy
curl -fsSLo install.sh https://raw.githubusercontent.com/yohi/Pi/master/install.sh
less install.sh
sudo sh install.sh --role pi
```

リポジトリには全ファイルが必要です。インストーラはGitHubの `MANIFEST.sha256` でファイル群の整合性を確認した後、`/usr/local/sbin/pi-panctl`、アンインストーラと4件の systemd unit をインストールします。必要に応じて `fzf` と `dnsmasq-base` を `apt-get` で導入します。`NetworkManager`/`bluetooth` は既存状態を前提とし、勝手に再インストール・再起動しません。

### Docker / CI でのオフライン検証

Dockerコンテナは通常、`systemd` がPID 1として稼働していないため、**通常の `--role pi` インストールは事前検査で停止**します。`systemctl` コマンドが存在するだけでは十分ではありません。依存パッケージを導入したり、`/etc` や `/usr/local/sbin` を変更したりする前に停止します。

コンテナ内では、インストールせずに以下を実行してください。**NetworkManager・BlueZ・systemdの起動、Bluetoothデバイス、実Wi-Fi機器、fzfの導入は不要**です。

```sh
curl -fsSL https://raw.githubusercontent.com/yohi/Pi/master/install.sh \
  | sh -s -- --role pi --offline-test
```

`--offline-test` は配布ファイルのSHA-256検証、シェル構文確認、NetworkManager・systemctlを模擬した8ケースのテストだけを行います。実ネットワークやサービス、インストール先は変更しません（root権限で実行する現行仕様）。`--role host --offline-test` でも同じ模擬テストを実行できます。`--dry-run` は取得・ハッシュ・構文検証のみ行います。

`fzf`の対話画面、実機のBluetooth PAN、Wi-Fi APの起動やDHCP動作はこのモードでは検証できません。**Docker内で `sudo pi-panctl tui` を起動するものではありません。**

### Dockerで実際のTUIを操作する（デモ）

非systemdのDockerでも、**インストールせず**に `fzf` メニューを体験できます。Pi/Hostの役割別メニューを表示し、選んだ項目にはサンプル応答だけを返します。NetworkManager、Bluetooth、systemd、Wi-Fiプロファイルを参照・変更しません。実際の接続操作は検証できません。

```sh
# fzfとcurlが利用できる対話型コンテナ (docker run -it) で実行
curl -fsSL https://raw.githubusercontent.com/yohi/Pi/master/install.sh \
  | sh -s -- --role pi --demo
# Hostの見た目を確認する場合
curl -fsSL https://raw.githubusercontent.com/yohi/Pi/master/install.sh \
  | sh -s -- --role host --demo
```

`--demo` はroot、Bluetooth、NetworkManager、systemdを必要とせず、GitHubから取得したファイルのハッシュ検証後に一時ディレクトリから起動します。`fzf` の事前インストールとTTYが必要です。`--demo` はローカルの既存 `pi-panctl` を更新しません。`--offline-test` は従来どおり自動モック試験を実行します。

## 2. 何が起こるか

| 機能 | Pi | Ubuntu Host |
|---|---|---|
| 既存 PAN プロファイルの自動接続・無制限リトライ | `pi-bt-pan` (既存のNAP用Bridge `btnap0`) | `pi-zero2w-pan` (PANU) |
| PAN再接続のためのsystemd timer | 60秒程度ごとに未接続のみ接続試行 | 同左 |
| Wi-Fi復旧AP | 手動プロファイル設定、明示的に自動フォールバック有効化 | なし |
| Bash + fzf TUI | PAN, Wi-Fi, Bluetooth, 復旧AP, ログ | PAN, Bluetooth, ログ |

Pi側は既存の `btnap0` Bridgeプロファイルを再利用します（BlueZのNAP登録そのものは既存構成を前提とし、本ツールでは新規作成しません）。両方のPANは既存プロファイルを **上書きせず**、`autoconnect=yes`, `autoconnect-retries=0` のみ変更します。PANがすでに繋がっている場合はsystemd timerから接続操作を呼びません。タイマーを有効にすると初回実行が行われる場合があるため、設定を戻す場合は `sudo systemctl disable --now pi-pan-guardian-pan.timer` を使います。

### Wi-Fi復旧APの準備 (Piのみ)

```sh
sudo pi-panctl recovery setup     # 既存の Pi-Zero2W-Recovery プロファイルは維持
sudo pi-panctl recovery password  # root権限でPSKを見る (共有しない)
sudo pi-panctl recovery enable    # フォールバックの自動監視開始
```

**重要：** `recovery setup` だけではAPは起動しません。Wi-Fiが `disconnected` の状態で約90秒継続した場合に限り、起動後120秒以降から監視するtimerがAPを起動します。Wi-Fi接続中、接続処理中、管理外/Unavailable中はAPを起動しません。切断時間はRAM上で追跡し、再起動時にリセットします。

新規作成時のSSIDは `Pi-Zero2W-Recovery`、AP IPは `192.168.77.1/24`、WPA2-PSKは24桁のランダム16進文字列をroot権限のNMキーファイルに格納します。既存の同名APがあれば**秘密情報を保持して再利用**します。`ipv4.method shared` は NetworkManager により DHCP と NAT/ルーティングを有効にすることがあります。**このAPは厳密な隔離ネットワークではありません。** 他のネットワークへの共有を禁止したい場合はファイアウォールポリシー確認まで自動APを有効化しないでください。

**単一Wi-Fi無線の制約：** Wi-Fi APが起動している間、Piの `wlan0` を同時にiPhoneテザリングへ接続することは期待できません。iPhone Wi-Fiへ戻すときはPAN SSHを保持してから:

```sh
sudo pi-panctl recovery disable   # 自動AP監視を止める (AP自体は維持)
sudo pi-panctl recovery stop      # AP停止 (AP経由SSH中は拒否)
sudo nmcli --ask connection up 'YusukeOhi_iPhone17' ifname wlan0
```

`pi-recovery-wifi.timer` という旧システムが `enabled` または `active` の場合は競合防止のため、このツールは新しいAP自動監視を**拒否**します。旧タイマーを自動削除しません。移行すると判断した場合のみ、TUI の **「disable legacy recovery timer (explicit migration)」** または `sudo pi-panctl recovery legacy-disable` を選び、明示的に旧タイマーだけを停止・無効化できます。旧プロファイル・既存APは維持します。

### TUI表示スタイル

`sudo pi-panctl tui` のメニューは [dotfiles-term の `tmux-selector.sh`](https://github.com/yohi/dotfiles-term/blob/master/tmux/tmux-selector.sh) に合わせ、角括弧付きのアクション名（`[Status]`、`[PAN Activate]` など）、`fzf --height=40% --reverse --border`、役割ごとの `Select Pi action: ` / `Select Host action: ` プロンプトを使います。Escで終了し、設定変更は従来どおり `YES` の明示確認が必要です。無線サービスの制御ロジックや役割別メニューの権限制限は変更していません。

### 主なCLI

```sh
sudo pi-panctl tui
pi-panctl status
sudo pi-panctl pan configure
sudo pi-panctl pan ensure
pi-panctl wifi profiles
sudo pi-panctl wifi connect  # fzfで保存済みWi-Fiから選択
pi-panctl bt info
sudo pi-panctl recovery start   # wlan0切断中に限る
sudo pi-panctl recovery stop
sudo pi-panctl recovery disable
sudo pi-panctl recovery legacy-disable # 旧タイマーの明示的停止（必要な場合のみ）
```

## 3. 運用上のガード

- Bluetooth停止、`rfkill`、`brcmfmac`再読み込み、NetworkManager再起動、IPアドレス/Bridgeの無断変更は**実装しません**。
- Pi NAPとHost PANUを同じ役割にしない。Roleが違うマシンへの上書きインストールは拒否します。
- PANのパスワード、Wi-Fi PSK、Bluetooth鍵、SSH鍵、Tailscaleの設定は変更しません。
- タイマーはデバイスが未接続のときだけ1回の接続を試み、失敗時はログに残し次周期に再試行します。
- Wi-Fiの強制切断や自動的なAP⇄STA切替は行いません。復旧AP稼働中はユーザーがPANで切り替えます。
- 旧リカバリタイマーとの競合を検出した場合はAP自動化を停止します。
- Bluetooth PANは機能維持を意図しますが、Bluetoothと2.4GHz Wi-Fiは同じ無線系を使うため、実機での安定性は保証されません。
- `curl | sh` 形式は公開URLとハッシュ・commit pinningを確認して利用してください。MANIFESTは同じGitHub refから取得するため、独立した署名検証ではありません。

## 4. アンインストール

```sh
sudo pi-pan-guardian-uninstall
```

インストールしたプログラム/タイマーだけ削除します。**既存のNetworkManagerプロファイル、生成したリカバリAP、PSK、`/etc/pi-pan-guardian` は消しません。** 元に戻す必要がある場合は別途Human Owner判断が必要です。

## 5. 検証・残余リスク

```sh
bash -n bin/pi-panctl
sh -n install.sh
sh -n uninstall.sh
bash tests/test_guardian.sh
bash tests/test_installer_dryrun.sh  # --offline-test / non-systemd fail-fast を含む
sha256sum -c MANIFEST.sha256
```

実機未検証のため、BlueZ/NetworkManagerのバージョンによる挙動、AP+PAN同時運用、ブート直後のタイミング、旧タイマー移行時の競合、既存APプロファイルのフォーマット差は未確定です。**最初は既存PANを維持してPiとHostに導入し、APを無効のまま確認**することを推奨します。

### Reference

- NetworkManager Bluetooth NAP/PANU example: https://networkmanager.pages.freedesktop.org/NetworkManager/NetworkManager/nmcli-examples.html
- NetworkManager settings: https://networkmanager.pages.freedesktop.org/NetworkManager/NetworkManager/nm-settings-nmcli.html
- BlueZ NAP registration: https://github.com/bluez/bluez/blob/master/doc/org.bluez.NetworkServer.rst
- Raspberry Pi Zero 2 W wireless: https://www.raspberrypi.com/documentation/computers/zero.html
