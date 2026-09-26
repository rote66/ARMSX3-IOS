# ARMSX3 for iOS / ARMSX3 iOS 版

ARMSX3 for iOS is an experimental arm64/iPhoneOS frontend around the RPCS3 core. It reuses the
same emulation core and, where practical, the same frontend assets and behavior as ARMSX3 on
Android, while keeping iOS-specific lifecycle, input, audio, storage and JIT handling separate.

ARMSX3 iOS 版是基于 RPCS3 Core 的实验性 arm64/iPhoneOS 前端。在可行的范围内，它复用
Android 版 ARMSX3 的前端资源和交互逻辑，同时针对 iOS 单独处理生命周期、输入、音频、
存储、JIT 和系统集成。

> **Status / 状态:** experimental. Game compatibility, performance and memory behavior can vary
> significantly by title and device. / 目前仍属于实验阶段，不同游戏、设备的兼容性、性能和
> 内存表现可能有明显差异。

## Platform / 平台

- **Architecture / 架构:** arm64 only / 仅 arm64
- **Deployment target / 最低系统:** iOS 15.0
- **Renderer / 渲染器:** Vulkan through MoltenVK / Vulkan（通过 MoltenVK）
- **CPU recompiler / CPU 重编译器:** LLVM AArch64 JIT
- **Current validated build toolchain / 当前已验证构建环境:** Xcode 27.0
- **CMake project minimum / CMake 工程最低版本:** 3.28

The produced IPA is ad-hoc signed for development/testing. RPCS3's recompilers generate executable
code at runtime, so the app also needs an installation/JIT environment that permits that execution.
The packaging script verifies the memory/JIT-related entitlement set used by the current iOS port
and deliberately rejects several incompatible signing entitlements. A normal App Store-style build
should not be assumed to work unchanged.

生成的 IPA 使用开发/测试用 ad-hoc 签名。RPCS3 重编译器需要在运行时生成并执行代码，因此
安装环境还必须允许相应的 JIT 执行方式。当前打包脚本会检查 iOS 移植所需的内存/JIT 相关
entitlement，并主动拒绝若干不兼容的签名 entitlement；不能假设普通 App Store 式签名可直接
运行。

## Features / 已实现功能

### Emulation and runtime / 模拟器与运行时

- RPCS3 ARM64 core with LLVM PPU/SPU recompilation paths adapted for iOS.  
  RPCS3 ARM64 Core，包含为 iOS 适配的 LLVM PPU/SPU 重编译路径。
- Vulkan rendering through MoltenVK, Metal-backed presentation and an iOS-native audio backend.  
  通过 MoltenVK 使用 Vulkan，Metal 显示链路，以及 iOS 原生音频后端。
- iOS-specific JIT arena/lifecycle handling and executable-memory checks before boot.  
  iOS 专用 JIT 内存区、生命周期处理，以及游戏启动前的可执行内存检查。
- iOS RSX/Vulkan ring-buffer pressure handling, bounded growable heaps and memory-pressure recovery
  intended to reduce process kills on memory-constrained devices.  
  针对 iOS 的 RSX/Vulkan 环形缓冲区内存压力处理、增长上限及回收逻辑，用于降低小内存设备
  被系统直接终止的概率。
- Runtime pause/resume/stop, screenshots, save-state slots and performance OSD controls.  
  运行中暂停/继续/停止、截图、即时存档槽位以及性能 OSD 控制。

### Game library and content / 游戏库与内容管理

- Folder/disc-style games from `Documents/Games`, additional Files-provider folders and ISO images.  
  支持 `Documents/Games`、通过“文件”选择的额外目录以及 ISO 游戏。
- Library metadata, cover art, custom names/covers, search, sorting and recent-game tracking.  
  游戏元数据、封面、自定义名称/封面、搜索、排序和最近游玩记录。
- PS3 firmware installation/reinstallation from `PS3UPDAT.PUP`, plus XMB/VSH boot.  
  从 `PS3UPDAT.PUP` 安装/重装 PS3 系统软件，并支持启动 XMB/VSH。
- PKG installation and licence import paths used by RPCS3.  
  PKG 安装以及 RPCS3 所需许可证导入。
- Installed-content browser/uninstaller and import of an already-installed PC RPCS3 Title ID folder
  into `dev_hdd0/game`.  
  已安装内容浏览/卸载，以及把 PC RPCS3 已安装好的 Title ID 文件夹导入 `dev_hdd0/game`。
- The iOS frontend and RPCS3 VFS now share one `dev_hdd0`; older iOS builds' legacy
  `config/dev_hdd0` content is migrated into the unified location at startup.  
  iOS 前端和 RPCS3 VFS 现在使用同一个 `dev_hdd0`；旧版 iOS 构建遗留的
  `config/dev_hdd0` 内容会在启动时迁移到统一位置。
- Game-update manager, save-data manager, trophy browser, patches/cheats manager and mods manager.  
  游戏更新管理、存档管理、奖杯浏览、补丁/作弊码管理以及 Mods 管理。

### Settings and per-game configuration / 设置与单游戏配置

- App settings plus a native browser/editor for the RPCS3 configuration tree.  
  应用设置，以及原生 RPCS3 配置树浏览/编辑界面。
- Core categories for application/general, performance/CPU, graphics, audio, network and input, with
  bool, numeric and enum/choice controls.  
  Core 设置按应用/常规、性能/CPU、图形、音频、网络、输入等分类，并支持布尔、数值和枚举选择。
- Per-game settings and in-game quick settings for the currently running title.  
  单游戏设置，以及针对当前运行游戏的游戏内快速设置。
- Runtime graphics controls including resolution scale, aspect/display behavior and portrait render
  position overrides.  
  运行中可调内部渲染分辨率、画面比例/显示行为以及竖屏渲染位置。
- App themes, OLED mode, custom colors/backgrounds, launcher orientation, toolbar placement, boot
  intro, battery warnings and library screensaver/backdrop options.  
  主题、OLED 模式、自定义颜色/背景、启动器方向、工具栏位置、启动动画、电量提醒和游戏库动态背景。
- Library/pause music, menu SFX and configurable trophy sound/volume, including user imports.  
  游戏库/暂停菜单音乐、菜单音效以及可配置奖杯音效/音量，并支持用户导入。
- Full frontend backup/restore and frontend-only factory reset.  
  前端完整备份/恢复，以及只重置前端设置的恢复出厂功能。

### Touch and controller input / 触控与手柄

- Android-style on-screen controls: split D-pad directions, dual analog sticks, face buttons,
  shoulders/triggers, Start/Select and L3/R3.  
  Android 风格虚拟手柄：独立方向键、双摇杆、动作键、肩键/扳机、Start/Select、L3/R3。
- Editable touch layout with drag, scaling, overlap indication, opacity control, grid/floating-stick
  options and reusable controller skins.  
  可编辑触控布局，支持拖动、缩放、重叠提示、透明度、网格/浮动摇杆以及控制器皮肤。
- Touch gestures, multi-touch behavior and configurable haptics.  
  触控手势、多点触控行为和可配置触觉反馈。
- Physical controller support for multiple PS3 pad ports, per-player remapping and controller-manager
  refresh/reset actions.  
  多 PS3 手柄端口、分玩家实体手柄映射，以及控制器管理器刷新/重置功能。
- Controller hotkeys, macros, turbo, gyro/motion mapping and rumble bridge.  
  控制器快捷键、宏、连发、陀螺仪/体感映射和震动桥接。

### Frontend utilities / 前端工具

- Onboarding/setup flow and multi-language UI using the shared ARMSX3 translation assets with iOS
  overrides where needed.  
  首次设置流程；复用 ARMSX3 多语言资源，并针对 iOS 补充必要文案。
- RPCN account/configuration UI and friends view backed by RPCS3 RPCN functionality.  
  基于 RPCS3 RPCN 功能的账号/配置和好友界面。
- News/release-notes view with offline cache.  
  带离线缓存的新闻/发布说明界面。
- Update checker/downloader for GitHub release IPA assets. The downloaded IPA is handed to the
  system share sheet or an external installer; ARMSX3 does **not** silently self-install updates.  
  GitHub Release IPA 更新检查/下载。下载后交给系统分享菜单或外部安装器，ARMSX3 **不会**静默
  自行安装更新。
- Overlay-art import/catalog support and touch-controller skin manager.  
  Overlay Artwork 导入/目录浏览，以及虚拟手柄皮肤管理。

## Experimental / 实验性功能

The following items exist in the UI/code but should still be treated as experimental rather than
fully validated features.

以下项目已经有 UI/代码实现，但目前仍应视为实验性功能，而不是已经全面验证的稳定功能。

- **iOS JIT and long sessions / iOS JIT 与长时间运行:** runtime code generation works on the
  current test setup, but entitlement/signing behavior and memory limits differ across installation
  methods and devices.  
  当前测试环境可运行 JIT，但不同安装方式、设备的签名权限和内存限制并不相同。
- **MoltenVK/RSX behavior / MoltenVK/RSX:** the iOS port contains additional memory-pressure and
  ring-buffer recovery logic that is intentionally different from desktop RPCS3.  
  iOS 端带有桌面 RPCS3 没有的内存压力和环形缓冲区恢复逻辑，需要继续扩大游戏验证范围。
- **Second Screen / 第二屏:** an external-display status/control panel exists, including live stats,
  save/load state, pause, screenshot and macro actions. It still uses the older `UIScreen` external
  display path and needs broader testing on modern scene-based iOS versions, HDMI and AirPlay.  
  已有外接屏状态/控制面板（实时数据、即时存档、暂停、截图、宏），但仍使用较旧的 `UIScreen`
  外接屏路径，需要在现代 Scene 生命周期、HDMI 和 AirPlay 上继续验证。
- **Shader Chain manager / Shader Chain 管理器:** `.slangp` packs/presets can be downloaded,
  imported, browsed and selected, but this port does **not currently include a librashader runtime
  rendering path**. Preset selection must not be interpreted as an active post-processing shader.  
  可下载/导入/浏览/选择 `.slangp` 包和预设，但目前 **没有接入 librashader 实际渲染运行时**；
  选中预设不代表游戏画面已经应用后处理 Shader。
- **RPCN/network flows / RPCN 与网络功能:** account creation, activation/reset operations,
  configuration and friends UI are wired to the RPCS3 backend, but real-world service/game coverage
  still needs testing.  
  RPCN 注册、激活/重置、配置和好友 UI 已连接 RPCS3 后端，但真实服务和游戏覆盖仍需验证。
- **Updater / 更新器:** release checking and IPA download are implemented, but installation is
  intentionally delegated to iOS/the chosen external installer.  
  已实现 Release 检查和 IPA 下载，但安装过程有意交给 iOS/外部安装器处理。
- **Game updates, mods and imported installed-content layouts / 游戏更新、Mods 与已安装目录导入:**
  these work on normal RPCS3 layouts but unusual title-specific layouts still need device testing.  
  标准 RPCS3 目录结构已有支持，但特殊游戏/特殊目录结构仍需要真机验证。

## Still Need Test / 仍需测试

- More titles across different engines, especially games with high RSX memory use, long loading
  sequences or unusual HDD install layouts.  
  扩大游戏覆盖，重点测试高 RSX 内存占用、长加载流程和特殊 HDD 安装结构的游戏。
- Long-session memory stability on 4 GB and other memory-constrained iPhone/iPad models.  
  4 GB 等内存较紧张设备上的长时间运行稳定性。
- Frame pacing/performance with title-specific settings such as Multithreaded RSX; do not assume a
  setting that helps one game is a good global default.  
  针对不同游戏验证多线程 RSX 等性能选项，不应把单个游戏的收益直接作为全局默认。
- PKG launcher + separate `dev_hdd0/game` data-title combinations after the unified VFS migration,
  including large folders imported from Files providers.  
  统一 VFS 后继续验证“PKG 启动器 + 独立 `dev_hdd0/game` 本体数据”的游戏，以及通过“文件”
  Provider 导入的大体积目录。
- Multi-controller P1-P7 assignment/remapping, hotkeys, macros/turbo, gyro and rumble across more
  controller vendors.  
  P1-P7 多手柄分配/映射、快捷键、宏/连发、陀螺仪和震动在更多品牌手柄上的兼容性。
- Save-state compatibility/reliability across long sessions and core changes; important saves should
  still use normal PS3 save data.  
  即时存档在长时间运行和 Core 更新后的可靠性；重要进度仍建议保留正常 PS3 存档。
- Full backup/restore with large save/trophy/licence sets and interrupted imports.  
  大量存档/奖杯/许可证场景下的完整备份恢复，以及导入被中断时的处理。
- Game-update installation, patches/cheats and mods on a wider set of titles.  
  更多游戏上的更新安装、补丁/作弊码和 Mods。
- RPCN sign-up/reset/friends and actual RPCN-enabled multiplayer titles.  
  RPCN 注册/重置/好友以及真实支持 RPCN 的联机游戏。
- External second-screen behavior on current iOS/iPadOS with wired displays and AirPlay.  
  当前 iOS/iPadOS 下有线外接屏和 AirPlay 的第二屏行为。
- Update-check/download flows against future release/nightly asset naming.  
  后续 Release/Nightly 的资产命名变化对更新检查/下载的影响。
- Localization coverage and layout on long translations and right-to-left languages.  
  长文本翻译和从右到左语言下的本地化覆盖与布局。

## Storage layout / 存储目录

Paths below are relative to the app sandbox; no host/developer path is required.

以下路径均相对于 App 沙盒，不需要任何开发者机器的绝对路径。

| Purpose / 用途 | Location / 位置 |
| --- | --- |
| User-visible game folder / 用户可见游戏目录 | `Documents/Games/` |
| RPCS3 virtual HDD / RPCS3 虚拟硬盘 | `Library/Application Support/ARMSX3/dev_hdd0/` |
| Installed PS3 content / 已安装 PS3 内容 | `Library/Application Support/ARMSX3/dev_hdd0/game/<TITLE_ID>/` |
| RPCS3 configuration / RPCS3 配置 | `Library/Application Support/ARMSX3/config/` |
| ARMSX3 caches / ARMSX3 缓存 | `Library/Application Support/ARMSX3/cache/` and system Caches |
| User-shareable logs / 可导出的日志 | `Documents/Logs/` |

`dev_hdd0/game` contains both directly bootable titles and data/update/helper directories. The home
library intentionally lists only entries with a recognized boot target; a data-only directory can
still be required by a separate PKG-installed launcher.

`dev_hdd0/game` 既可能包含可直接启动的游戏，也可能包含纯数据、更新或辅助目录。首页只显示
存在有效启动入口的项目；纯数据目录仍可能被另一个通过 PKG 安装的启动器使用。

## How to Build / 如何构建

### 1. Requirements / 环境要求

Use macOS with a full Xcode installation and the iPhoneOS SDK. The current tree has been validated
with Xcode 27.0. The CMake project requires CMake 3.28 or newer, and the iOS LLVM cross-build needs a
host `llvm-tblgen` from LLVM 22.

使用 macOS 和完整 Xcode/iPhoneOS SDK。当前源码已用 Xcode 27.0 验证。CMake 工程要求
CMake 3.28 或更新版本；iOS LLVM 交叉编译还需要主机端 LLVM 22 的 `llvm-tblgen`。

The build scripts locate CMake from `PATH` first and also recognize the usual Apple Silicon and
Intel Homebrew locations. If CMake is installed elsewhere, set `ARMSX3_CMAKE` to its executable.

构建脚本会优先从 `PATH` 查找 CMake，并兼容 Apple Silicon / Intel Homebrew 的常见安装位置。
如果 CMake 安装在其它位置，可通过 `ARMSX3_CMAKE` 指定其可执行文件。

With Homebrew, a typical setup is:

使用 Homebrew 时可安装：

```sh
brew install cmake llvm@22
```

Also make sure Xcode command-line tools point at the intended Xcode installation and that the Xcode
license/setup has been completed.

同时确认 Xcode Command Line Tools 指向正确的 Xcode，并已完成首次启动/许可证配置。

### 2. Clone with submodules / 克隆并初始化子模块

```sh
git clone --recursive https://github.com/ARMSX2/ARMSX3.git
cd ARMSX3
git submodule update --init --recursive
```

If the repository is already cloned, only the last command is needed after pulling changes that
modify submodule revisions.

如果已经克隆仓库，在更新到包含子模块版本变化的提交后执行最后一条即可。

### 3. Build iOS dependencies / 构建 iOS 依赖

Point the dependency script at an LLVM 22 host `llvm-tblgen`. Using Homebrew keeps this portable
between Apple Silicon and Intel Homebrew prefixes:

把依赖脚本指向 LLVM 22 的主机 `llvm-tblgen`。下面的写法不会写死 Apple Silicon 或 Intel
Homebrew 的安装前缀：

```sh
export ARMSX3_LLVM_TABLEGEN="$(brew --prefix llvm@22)/bin/llvm-tblgen"
./ios/build-dependencies.sh all
```

The script builds/fetches the iOS dependencies used by this port, including the pinned Abseil source
required by protobuf, FFmpeg, MoltenVK and a cross-compiled AArch64 LLVM. By default they are stored
below `build/ios-device/`. Abseil is populated explicitly so the main CMake configure can remain
`FETCHCONTENT_FULLY_DISCONNECTED` and will not unexpectedly download dependencies.

脚本会准备本移植所需的 iOS 依赖，包括 protobuf 所需的固定版本 Abseil 源码、FFmpeg、
MoltenVK 和交叉编译的 AArch64 LLVM；默认存放在 `build/ios-device/` 下。Abseil 会在依赖阶段
显式准备，因此主工程 CMake 可以继续使用 `FETCHCONTENT_FULLY_DISCONNECTED`，不会在配置阶段
偷偷下载依赖。

Individual dependency targets are also available:

也可以单独构建：

```sh
./ios/build-dependencies.sh absl
./ios/build-dependencies.sh ffmpeg
./ios/build-dependencies.sh moltenvk
./ios/build-dependencies.sh llvm
```

### 4. Build and package the IPA / 构建并打包 IPA

```sh
./ios/build-ipa.sh
```

The script configures the Xcode generator for iPhoneOS/arm64/iOS 15.0, builds the `ARMSX3` Release
target, creates an ad-hoc signed app, verifies the expected entitlements and packages:

该脚本会使用 Xcode Generator 配置 iPhoneOS/arm64/iOS 15.0，编译 `ARMSX3` Release Target，
生成 ad-hoc 签名 App，检查 entitlement，并打包得到：

```text
build/ios-output/ARMSX3-iOS15-arm64.ipa
```

Useful optional environment variables / 可选环境变量：

```sh
# Main app build jobs / 主工程并行任务数
export ARMSX3_IOS_BUILD_JOBS=2

# Dependency build jobs / 依赖并行任务数
export ARMSX3_JOBS=8

# Alternate build root / 自定义构建目录
export ARMSX3_IOS_BUILD_DIR="$PWD/build/ios-device"

# CMake installed outside PATH/Homebrew defaults / CMake 位于其它目录时
export ARMSX3_CMAKE="/path/to/cmake"

# Debug instead of the default Release / 改为 Debug（默认 Release）
export ARMSX3_CONFIGURATION=Debug
```

### 5. Full clean rebuild / 完整干净重构建

The iOS dependencies live inside the default build tree, so a **full** clean also removes those
cross-compiled dependencies and rebuilds them from scratch:

iOS 依赖默认也位于构建目录中，因此 **完整 clean** 会同时删除交叉编译依赖，之后需要全部重建：

```sh
rm -rf build/ios-device build/ios-output
export ARMSX3_LLVM_TABLEGEN="$(brew --prefix llvm@22)/bin/llvm-tblgen"
./ios/build-dependencies.sh all
./ios/build-ipa.sh
```

For a normal incremental rebuild, keep `build/ios-device/` and simply run `./ios/build-ipa.sh` again.

普通增量构建不需要删除 `build/ios-device/`，直接再次运行 `./ios/build-ipa.sh` 即可。

## Build notes / 构建说明

- `ios/build-ipa.sh` expects the dependencies produced by `ios/build-dependencies.sh`.  
  `ios/build-ipa.sh` 依赖 `ios/build-dependencies.sh` 生成的依赖文件。
- The source tree is expected to have all Git submodules initialized.  
  源码树必须完成全部 Git submodule 初始化。
- The iOS build disables several desktop-only backends/features and statically links the required
  LLVM/FFmpeg/MoltenVK pieces.  
  iOS 构建会关闭部分桌面专用后端/功能，并静态链接所需的 LLVM/FFmpeg/MoltenVK 组件。
- The root CMake configuration uses `-ffile-prefix-map` when supported so absolute developer source
  paths are not embedded into shipped assertion/log source locations.  
  根 CMake 在编译器支持时使用 `-ffile-prefix-map`，避免把开发者机器的绝对源码路径嵌入发布
  二进制的断言/日志源码位置。
- PS3 firmware, games, licences and copyrighted game content are **not** included.  
  项目 **不包含** PS3 固件、游戏、许可证或受版权保护的游戏内容。

## License / 许可证

ARMSX3 follows the repository's licensing terms and is based on RPCS3. See `LICENSE` and individual
third-party/source-file notices for details.

ARMSX3 遵循仓库现有许可证并基于 RPCS3。详情请查看 `LICENSE` 以及各第三方/源码文件中的许可说明。
