# OnePlus Pad Pro (caihong)：Ubuntu 26.04.1 LTS + KDE Plasma 刷机包

## 文件

| 文件 | 大小 | 说明 |
| --- | --- | --- |
| `caihong-ubuntu-plasma.ext4.sparse.img` | 4.6 GB | Android sparse ext4 镜像，逻辑大小 7.8 GiB，刷入 `linux` 分区后首次开机自动扩容到 148 GB |
| `caihong-ubuntu-plasma.ext4.sparse.img.sha256` | — | SHA-256：`e95bb8d81b46d4bac53fb52a508c40309336f4a0a44858857f5f0e1baa9e7fbf` |

> 这个文件名保持不变，每次重建只更新内容和 SHA-256；以本文件里的哈希为准。

镜像内容：

- Ubuntu 26.04.1 LTS (resolute) arm64 base
- KDE Plasma 6.6.6 + SDDM（自动登录 `hederek`，Plasma Wayland 会话）
- 桌面应用：LibreOffice（Writer/Calc/Impress + 中文语言包）、Firefox 159（Mozilla 官方 deb 源，非 snap）+ 中文语言包、VLC、mpv、ffmpeg、Okular、Gwenview、Krita、Kamoso、KHelpCenter、KCalc、Ark/7zip/unrar、GParted、KDE 分区管理器、KWallet 管理器、Bluedevil、CUPS 打印、Dolphin 插件/KIO Admin、Discover（Flatpak 后端）+ flatpak
- **不含**：snapd、Thunderbird（Ubuntu 只提供 snap 版），也没有预装你的个人数据（见下）
- 面板默认 200% 缩放（`~/.config/kwinoutputconfig.json`，沿用你现在 Plasma 的配置）
- fcitx5 + 拼音输入法、Noto CJK 字体
- 原 Caihong 内核 7.3.0 与其模块（含 OTG VBUS 修复、USB 网卡驱动、VOOC 重试补丁）
- 完整固件包（`qcom`/`ath12k`/`qca`/`novatek`…）、音频 UCM + AudioReach topology
- 设备集成：`caihong-*` 服务（热键、笔、蓝牙键盘、热点、MAC、A/B slot、根分区扩容）
- SSC 传感器运行库（iio-sensor-proxy + hexagonrpcd）、NPU 运行库、adbd、qbootctl
- NetworkManager / BlueZ / PipeWire + WirePlumber / power-profiles-daemon / zram

## 刷机（需要电脑 + fastboot）

Android 与 `userdata` 分区**完全不动**，只覆盖 `linux` 分区；boot 分区里的内核不用重刷。

1. 平板保持现在的系统运行，把镜像拉到电脑。

   SSH/SCP（平板上 sshd 已开机自启，当前地址 `192.168.3.224`，用户 `hederek`，用你现在的密码）：

   ```sh
   scp hederek@192.168.3.224:/home/hederek/Downloads/caihong-ubuntu-plasma.ext4.sparse.img \
       /home/hederek/Downloads/caihong-ubuntu-plasma.ext4.sparse.img.sha256 .
   sha256sum -c caihong-ubuntu-plasma.ext4.sparse.img.sha256     # 应输出 OK
   ```

   想断点续传就用 rsync：`rsync -avP hederek@192.168.3.224:/home/hederek/Downloads/caihong-ubuntu-plasma.ext4.sparse.img .`

   USB 方式也可以：`adb pull /home/hederek/Downloads/caihong-ubuntu-plasma.ext4.sparse.img`

2. 校验（可选但建议）：

   ```sh
   sha256sum caihong-ubuntu-plasma.ext4.sparse.img
   # e95bb8d81b46d4bac53fb52a508c40309336f4a0a44858857f5f0e1baa9e7fbf
   ```

3. 刷入并重启：

   ```sh
   fastboot devices
   fastboot flash linux caihong-ubuntu-plasma.ext4.sparse.img
   fastboot reboot
   ```

   首次开机 `caihong-grow-rootfs.service` 会把文件系统扩到分区大小，可能需要几十秒。

4. 登录：自动登录 `hederek`，密码就是你 Arch 里那个（哈希直接迁移过来了）。

## 关于数据（重要）

这个镜像是**全新系统**，`/home` 里只有默认骨架配置，不含你现在 Arch 上的任何文件。刷入 `linux` 分区会不可恢复地清掉当前 Arch 根分区和整个 `/home/hederek`（18 GB，其中 Documents 3.3 GB、WeChat 记录 `Documents/xwechat_files`、`.local/share/debrun` 3.3 GB、Downloads 4.2 GB）。你选的是「不要数据，全新开始」，如果其中还有只在这里存过的东西，刷机前先 `adb pull` 或 U 盘拷走。

## 回滚

- 想回 Arch：把 Arch 的 rootfs 镜像（`caihong-rootfs-*.ext4.sparse.img`）用同一条 `fastboot flash linux` 刷回去即可。
- boot 分区没动过；万一 boot 出问题，镜像我另存了 `boot-linux.img`：

  ```sh
  fastboot flash boot_b boot-linux.img
  ```

## 已知问题

- **相机**：v2 已内置 Caihong 定制 libcamera（`caihong-camera` 分支 `b297636`，QCOM ICP/BPS simple pipeline）和 Kamoso 相机应用，但还没在真机上实测，需要你刷完试一下。
- **NPU / 传感器**：运行库已按 Arch 预编译版本装入（glibc 2.38 需求 < 26.04 的 2.43，可加载），但没在 Ubuntu 下实测，可能有小问题。
- `netplan-configure.service` 已在镜像里 mask，不会再报失败（网络由 NetworkManager 接管）。
- 已额外合入 Realtek 固件（`realtek`/`rtl_nic`/`rtl_bt`/`rtw88`），RTL8153/8156 USB 网卡、Realtek 蓝牙与 rtw88 无线网卡可直接工作；老式 USB 串口猫（keyspan/moxa/edgeport/kaweth/whiteheat/ti_usb/mts）的固件未收录。
- 文件索引（baloo）默认关闭（`/etc/xdg/baloofilerc`），需要 Dolphin/KRunner 全文搜索时手动开启。
- 中文输入法：fcitx5 + 中文附加组件（拼音/双拼/五笔/仓颉）已装好并随登录自启；`~/.config/fcitx5/profile` 里已把 **拼音设为默认输入法**，`Ctrl+Space` / `Super+Space` 切换，任务栏会出现输入法托盘。
- Arch 专属的 pacman 增量包在这里没有对应机制；系统更新走 apt，内核更新需要重刷 rootfs 或手动跑 `/usr/lib/linux-caihong/install-current-slot`。

## 构建方式（可复现）

镜像由 fork 里的 `scripts/package-ubuntu-rootfs.sh` 生成：

```sh
sudo env UBUNTU_PASSWORD_HASH="$(sudo getent shadow hederek | cut -d: -f2)" \
  LIBCAMERA_SOURCE=/var/tmp/libcamera-probe \
  EXTRA_FIRMWARE="realtek rtl_nic rtl_bt rtw88" \
  scripts/package-ubuntu-rootfs.sh caihong-ubuntu-plasma.ext4.sparse.img
```

- base：`ubuntu-base-26.04.1-base-arm64.tar.gz`（清华镜像，HTTP 引导 + 装好 ca-certificates 后切 HTTPS）
- 相机：`LIBCAMERA_SOURCE=/var/tmp/libcamera-probe`（`Osilvfe/libcamera` 的 `caihong-camera` 分支）
- overlay：`rootfs/ubuntu/`
- 内核模块/启动镜像：取自本机已安装的 `linux-caihong`（`/usr/lib/modules/7.3.0`、`/usr/lib/linux-caihong`）
