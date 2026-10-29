# ARMSX3 开发代理指南

## 适用范围与阅读顺序

本文件适用于整个仓库；下级目录的 `AGENTS.md` 优先约束其目录内的工作。以下 iOS 专用规则
不应直接套用到 Android 或桌面端。

1. 查看 `git status --short`，区分当前任务、用户和其他会话留下的更改。
2. 阅读 `README-IOS.md`，了解平台、功能、用户目录与公开构建入口。

## 操作边界

- **真机由用户操作。** 构建请求不包含安装 IPA、导入配置、启动或重启 App、发送按键、
  重启手机的授权；设备已连接也不改变这一点。经用户要求可以只读采集现场日志。
- **只保留一个交付 IPA：** `build/ios-output/ARMSX3-iOS15-arm64.ipa`。新包覆盖固定路径，
  不生成带构建号的重复 IPA；包不在本地时，不因清理或文档任务自行重新打包。
- 不随意清空模拟器沙盒、PS3 固件、游戏、许可证、存档或缓存。临时测试配置必须先备份，
  结束后逐字节恢复，不能把 Null 音频等隔离配置混入交付默认值。
- 只有用户明确要求时才创建分支、提交或推送。需要以代理身份提交时使用
  `Codex <noreply@openai.com>`，按职责分类，不擅自包含文档或其他会话的更改。
- 清理前检查目标构建目录是否仍被使用；仅凭进程中的相对目录名，不能判断它属于本仓库。

## 代码与平台约束

| 范围 | 主要入口 |
| --- | --- |
| iOS 前端、生命周期、存储及输入 | `ios/src/` |
| iOS 构建与签名 | `ios/CMakeLists.txt`、`ios/Info.plist.in`、`ios/*.sh` |
| JIT、线程及虚拟内存 | `Utilities/`、`rpcs3/util/`、`rpcs3/Emu/Memory/` |
| PPU / SPU | `rpcs3/Emu/Cell/` |
| RSX / Vulkan / MoltenVK 适配 | `rpcs3/Emu/RSX/` |
| 共享翻译、皮肤及资源 | `android/armsx3-ui/app/src/main/assets/` |

- iOS 前端复用 RPCS3 Core 和适用的 Android 资源，平台生命周期、音频、输入和 JIT 处理保持分离。
- iOS 特有改动使用现有 `ARMSX3_IOS` 或 Apple / ARM64 / `TargetConditionals.h` 条件，
  不改变 Android、macOS 或桌面的默认行为。
- 真机与模拟器都是 arm64，但 SDK、静态库和 JIT 授权不同，不能混用依赖或可执行文件。
- 按用途区分通用修复和游戏兼容措施；标题特例必须限定到对应 Title ID，不能提升为全局默认。
- 保持 JIT 预留、提交、释放的尺寸一致；同步上游时特别检查本地较小 arena 与上游内存策略的组合。
- 保留 GPU 在途资源的生命周期保护。不能为了减少内存而直接释放尚在使用的 ring、纹理或缓冲。
- 不把延长游戏 watchdog、隐藏断言或修改游戏二进制当作已解决宿主问题的证据。
- 优先沿用现有代码风格与构建入口，不引入无关重构；不把生成文件或编译产物加入 Git。

## 构建入口

### 环境与依赖

- macOS、完整 Xcode 和对应 iPhoneOS / iPhoneSimulator SDK；本项目最近验证使用 Xcode 27.0。
- 最低 iOS 15.0、仅 arm64；CMake 至少 3.28，交叉构建 LLVM 需要主机 LLVM 22 的 `llvm-tblgen`。
- 初始化所需 Git 子模块。上游修改 gitlink 后检查子模块工作树，再更新对应依赖。
- LLVM、FFmpeg、MoltenVK 静态链接；主工程使用 `FETCHCONTENT_FULLY_DISCONNECTED=ON`，
  Abseil 源码由依赖脚本显式准备。

从仓库根目录执行：

```sh
export ARMSX3_LLVM_TABLEGEN="$(brew --prefix llvm@22)/bin/llvm-tblgen"
zsh ios/build-dependencies.sh all
zsh ios/build-ipa.sh
```

已有依赖时，真机重新构建只需 `zsh ios/build-ipa.sh`。依赖脚本还支持
`absl`、`ffmpeg`、`moltenvk`、`llvm` 单独目标。

| 参数 | 用途 / 默认值 |
| --- | --- |
| `ARMSX3_CMAKE` | 指定 CMake；否则查找 `PATH` 和常见 Homebrew 路径 |
| `ARMSX3_LLVM_TABLEGEN` | 主机 LLVM 22 的 `llvm-tblgen` |
| `ARMSX3_IOS_BUILD_DIR` | 真机默认 `build/ios-device`，模拟器默认 `build/ios-simulator` |
| `ARMSX3_IOS_BUILD_JOBS` | 真机默认 2，模拟器默认 4；注意本机内存和其他会话负载 |
| `ARMSX3_JOBS` | 依赖构建并行数，默认宿主逻辑处理器数 |
| `ARMSX3_CONFIGURATION` | 默认 `Release`，需要时指定 `Debug` |
| `ARMSX3_IOS_DEPENDENCY_SOURCES_DIR` | 依赖源码缓存目录；模拟器脚本优先复用已有真机缓存 |
| `ARMSX3_IOS_SDK` | 依赖目标 SDK；模拟器脚本自动设置为 `iphonesimulator` |

### 交付检查

- 新交付包的构建号同时更新 `ios/CMakeLists.txt` 和 `ios/Info.plist.in`。
- 构建脚本会检查签名、entitlement、最低系统版本和非系统动态库依赖，不绕过这些检查。
- 保持 `ios/ARMSX3.entitlements` 的现有权限集合：
  `get-task-allow`、`com.apple.developer.kernel.extended-virtual-addressing`、
  `com.apple.developer.kernel.increased-memory-limit`。
- 不为绕过 JIT 问题加入当前打包脚本拒绝的 `dynamic-codesigning`、
  `com.apple.security.cs.allow-jit` 或 `com.apple.security.cs.allow-unsigned-executable-memory`。
- 校验 IPA ZIP 完整性、版本、签名后可执行文件与包内文件的一致性、SHA-256、实际 IPA 数量。
- 明确区分构建通过、模拟器回归、真机运行；交付时不能用前两项代替真机游戏通过。

## 模拟器测试

```sh
zsh ios/build-simulator.sh
xcrun simctl list devices available
zsh ios/run-simulator.sh <device-udid> "$HOME/Downloads/PS3UPDAT.PUP"
```

- 构建不等于授权运行测试。`run-simulator.sh` 会安装模拟器 App、复制并安装固件、启动 XMB，
  仅在任务包含相应测试时执行。
- 模拟器产物位于 `build/ios-simulator/bin/ARMSX3.app`，不覆盖真机 IPA。
- 模拟器不要求真机专用的 `CS_DEBUGGED` 标志，但仍执行共享 arena 的 JIT canary。
- `ARMSX3_SIMULATOR_FIRMWARE` 只启用模拟器固件入口。固件启动使用既有静态 PPU / SPU
  解释器覆盖，XMB 冒烟通过不代表 LLVM 游戏通过。
- 模拟器使用 private 纹理 / texel buffer、staging 上传、完整 image-view swizzle，
  关闭 Metal argument buffer，不请求不支持的 depth clamp。
- 控制台位于 `build/ios-simulator/simulator.stderr.log`；App 日志在沙盒 `Documents/Logs/`。
- 调试器附加会暂停游戏，可能触发原型游戏的 watchdog；复测应保留无调试器对照。

### 无界面输入

需要输入测试时，以 `SIMCTL_CHILD_ARMSX3_SIMULATOR_INPUT=1` 启动模拟器 App，再调用：

```sh
udid="<device-udid>"
SIMCTL_CHILD_ARMSX3_SIMULATOR_INPUT=1 xcrun simctl launch "$udid" com.armsx3.ios
container="$(xcrun simctl get_app_container "$udid" com.armsx3.ios data)"
game="$container/Library/Application Support/ARMSX3/dev_hdd0/game/<title-id>"
zsh ios/simulator-input.sh "{\"boot\":\"$game\"}" "$udid"
zsh ios/simulator-input.sh '{"digital1":8,"duration_ms":200}' "$udid"
zsh ios/simulator-input.sh '{"digital2":64,"duration_ms":200}' "$udid"
zsh ios/simulator-input.sh '{"keys":["space"],"duration_ms":50}' "$udid"
```

- App 已运行时，需在测试授权范围内先结束旧进程，再以该环境变量启动；已有进程不会自动获得它。
- 脚本原子替换沙盒 `Documents/SimulatorInput.json`，它是最新状态，不是队列。
  每次输入后先观察结果，菜单单步用 50ms。
- Start 为 `digital1=8`，Cross 为 `digital2=64`；`boot` 仅在没有活动游戏时接受目标路径。
- 摇杆为 `left_x`、`left_y`、`right_x`、`right_y`，范围 0–255、中心 128；
  扳机为 `left_trigger`、`right_trigger`，范围 0–255。
- `duration_ms` 默认 200，限制 50–5000，到期释放手柄和键盘输入。
- `keys` 需要 Basic Keyboard，支持 `space`、`enter`、`backspace`、`escape`、`tab`、
  四个英文方向名和单个 ASCII 字符。文件输入默认关闭，真机构建不编译该通道。

## 清理规则

- 默认 clean 只删除可再生成的 CMake / Xcode 工程缓存、对象、App 和打包暂存 `Payload`。
- 保留 `ios-deps/`、`_deps/absl-src/`、依赖源码缓存，以及日志、截图、诊断、测试配置和现有 IPA。
- 完整删除依赖不是普通 clean；需要全量重建时明确说明下载和交叉编译成本。
- 不触碰其他项目、其他会话的构建目录，也不清除设备或模拟器沙盒来“清理构建”。

## 文档分工

- `README-IOS.md` 面向用户：平台、功能、限制、存储和基本构建方式。
- `AGENTS.md` 面向开发代理：操作约束、工作流程、验证要求和检查点导航。
- PS3 固件、游戏、许可证及其他受版权保护的游戏内容不随源码或 IPA 分发。
