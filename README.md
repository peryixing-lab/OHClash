# OHClash

面向 **HarmonyOS NEXT** 的原生代理客户端。界面与应用逻辑使用 **ArkTS / ArkUI**，代理数据面使用 **Go / mihomo**，通过 C N-API 对接鸿蒙系统 VPN / TUN。项目基于 FlClash 源码适配，不依赖 Flutter 运行时。

应用包含仪表盘、代理、配置、工具四个页面，支持白色浅色、原有深色和跟随系统外观。

> 当前为开发验证版本，面向 **HarmonyOS 7.0 及以上、支持 API 26 的 arm64 设备**。目标 SDK 与最低兼容 SDK 均为 **26.0.0**。包内版本号目前为 `0.8.98`，沿用原项目标识；更高系统版本仍需实际验证，不代表已兼容所有设备或完成上架认证。

## 当前实现的功能

| 模块 | 功能 |
| --- | --- |
| 仪表盘 | 实时上传/下载速度、最近 60 次采样曲线、累计流量与占比、连接时长、内网 IPv4、出口 IP 与地区检测 |
| VPN | 启动、停止、断开重连；会话隔离、启动取消与资源清理；独立 VPN 扩展处理 TUN |
| 出站模式 | 规则、全局、直连；在线切换后读取内核确认，离线可预设下次启动模式 |
| 代理 | 代理组、节点搜索与选择、离线预选；在线/离线真实延迟测试、最多 8 个并发、进度与取消 |
| 配置 | URL 订阅与本地文件导入、编辑、删除、选择、更新；订阅提供用量响应头时显示用量与到期信息 |
| Base64 | 标准/URL 安全 Base64、省略填充与换行；支持编码后的 YAML 与 mihomo 转换器识别的节点分享链接列表 |
| 工具 | 查看活动请求/连接、关闭指定连接、查看规则、本地或外部控制器设置、本地文件备份与恢复、免责声明 |
| 外观 | 深色 / 浅色 / 跟随系统，保存选择；图表、图标、状态栏与 HDS Dock 同步适配 |
| 动效 | 底部标签切换过渡、详情页位移与淡入淡出、滚动边缘弹性回弹；页面切换适配系统“减少动画”设置 |

速度和流量来自 mihomo 控制器的真实计数；网络检测和测速使用真实请求。失败时显示失败状态，不生成模拟延迟或固定定位结果。

## 下载与安装：DevEco Studio 个人签名侧载

目前通过下载源码、使用 **DevEco Studio 配置自己的调试签名，再构建并侧载**的方式安装。仓库不附带预编译 HAP 或原生库，首次构建需先编译 Go 内核。

本文的“自签名”指使用自己的华为开发者账号生成调试证书与 Profile。调试包受 Profile 中的设备列表和有效期约束，需要为自己的设备生成签名；不能将其他人的调试 HAP 视为通用安装包。签名流程参考华为官方[配置调试签名](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-signing)与[自动签名](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-signing-auto)文档。

### 1. 准备设备与开发环境

| 项目 | 要求 |
| --- | --- |
| 设备系统 | HarmonyOS 7.0 及以上，设备实际支持的 API 不低于工程最低要求 API 26 |
| 设备架构 | arm64；当前仅配置 `arm64-v8a`，不提供 x86 模拟器内核 |
| 开发工具 | 能安装并使用 **26.0.0 SDK** 的 DevEco Studio，包含 HarmonyOS SDK、Native C/C++ 工具链和 HDC |
| 华为账号 | 用于 DevEco Studio 的开发者登录与调试签名；若提示开通开发者服务或认证，按官方流程完成 |
| USB 连接 | 支持数据传输的数据线，设备开启开发者模式和 USB 调试，并授权这台电脑 |
| 内核工具链 | 支持 `GOOS=openharmony` 的 OpenHarmony Go 1.24.5；普通 Go 不能直接替代 |

从[华为 DevEco Studio 官网](https://developer.huawei.com/consumer/cn/deveco-studio/)下载开发工具，首次启动按引导安装 SDK 与依赖。当前原生内核构建脚本已在 macOS 环境验证；其他主机环境需自行准备对应工具链和兼容的 shell 环境。

### 2. 下载项目源码

任选一种方式：

- **ZIP 下载**：在[仓库首页](https://github.com/peryixing-lab/OHClash)点击 **Code → Download ZIP**，解压到本地；也可[直接下载 main 分支源码 ZIP](https://github.com/peryixing-lab/OHClash/archive/refs/heads/main.zip)。
- **Git 克隆**：在终端执行以下命令，后续可用 Git 更新源码。

```sh
git clone https://github.com/peryixing-lab/OHClash.git
cd OHClash
```

ZIP 解压后的文件夹通常名为 `OHClash-main`。后面的命令均在项目根目录执行，也就是能看到 `README.md`、`entry/`、`native/` 和 `build-profile.example.json5` 的目录。内核源码已包含在仓库中，无需另外初始化子模块。

### 3. 创建本机构建配置并打开工程

首次下载时，将 `build-profile.example.json5` 复制为同目录下的 `build-profile.json5`：

```sh
# macOS / Linux
cp build-profile.example.json5 build-profile.json5
```

```powershell
# Windows PowerShell
Copy-Item build-profile.example.json5 build-profile.json5
```

也可以用文件管理器复制并重命名。已有个人构建或签名配置时不要覆盖。

在 DevEco Studio 欢迎页选择 **Open**，打开项目根目录，等待工程同步和 OHPM 依赖安装完成。如果提示缺少 SDK，按提示安装 **26.0.0** 对应组件；不要通过降低 `compatibleSdkVersion` 来绕过检查，本项目使用了 API 26 功能。确保 SDK 中的 Native 工具链已安装，后续 Go 内核编译需要它。

### 4. 编译原生代理内核

此步骤必须在首次运行应用前完成，否则 CMake 会找不到 `libflclash_core.so` 或生成的头文件。

先准备 OpenHarmony Go 工具链，版本和精确提交见 [native/SOURCE.md](native/SOURCE.md)。若已准备好，直接执行：

```sh
# 以下示例使用 macOS 默认 DevEco Studio 路径。
# 将 OHOS_GO 替换为你本机 OpenHarmony Go 的实际路径。
OHOS_GO=/path/to/openharmony-go/bin/go \
OHOS_SDK=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony \
sh native/build-core.sh
```

`/path/to/openharmony-go/bin/go` 是占位路径，不能原样执行。如果还没有该工具链，见下方[原生内核构建说明](#原生内核)中的准备步骤。首次编译会下载 Go 依赖，需要可用的网络连接。

脚本成功后应生成：

```text
entry/libs/arm64-v8a/libflclash_core.so
entry/src/main/cpp/prebuilt/arm64-v8a/flclash_core.h
```

### 5. 连接 HarmonyOS 设备

1. 在设备设置中搜索“软件版本”，进入对应页面，连续点击版本号 7 次，按提示启用开发者模式；系统要求重启时完成重启。
2. 进入 **设置 → 系统 → 开发者选项**，开启 **USB 调试**。不同设备的菜单名称可能略有区别，可以在设置中搜索“开发者选项”。
3. 用数据线连接电脑，解锁设备，在设备端确认允许这台电脑进行 USB 调试。
4. 确认 DevEco Studio 的设备选择框出现该设备。安装和启动时保持设备解锁、亮屏，以便处理调试授权与 VPN 授权提示。

启用方式参考[华为官方 USB 调试说明](https://consumer.huawei.com/cn/support/content/zh-cn00407281/)。如果电脑只能充电却识别不到设备，先检查数据线是否支持数据传输，以及设备端是否完成授权。

### 6. 在 DevEco Studio 中生成个人调试签名

1. 保持目标设备已连接，在 DevEco Studio 打开 **File → Project Structure… → Project → Signing Configs**。
2. 点击 **Sign In**，登录自己的华为开发者账号，并选择对应的个人或团队账号。
3. 使用未关联注册应用的调试签名流程，勾选 **Automatically generate signature**；如果界面提供 **Support HarmonyOS**，一并勾选。仅为个人侧载时，无需把工程关联到作者的应用或账号。
4. 检查 Bundle name 与 `AppScope/app.json5` 中的 `com.flclash.harmony` 一致，首次安装建议保留默认包名。若因账号下的包名冲突必须修改，除了 `AppScope/app.json5`，还需要同步修改 `entry/src/main/ets/pages/ReferenceHome.ets` 和 `Home.ets` 中 VPN 启动 Want 的固定 `bundleName`，然后重新生成签名；后文 HDC 启动命令中的包名也要同步修改。
5. 点击 **Apply / OK**，等待签名完成。确认界面显示已生成的证书和 Profile，工程级 `build-profile.json5` 中有 `signingConfigs`，`default` 产品关联了对应签名配置。

官方操作与界面变化以[自动签名指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-signing-auto)为准。自动签名不可用时，可按[手动签名指南](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-signing-manual)准备自己的调试证书与设备 Profile，再填入 Signing Configs；不要使用作者或其他人的私钥。

### 7. 构建并侧载到自己的设备

**方法 A：通过 DevEco Studio 直接安装，推荐首次使用。**

在顶部选择 `entry` 运行配置和已连接的真机，点击 **Run ▶**。DevEco Studio 会编译、签名、安装并启动应用；手机桌面出现 **OHClash** 后即可使用。

**方法 B：先构建 HAP，再通过 HDC 安装。**

在 DevEco Studio 的 **Build** 菜单选择构建 HAP 的操作（不同版本通常显示为 **Build Hap(s)/APP(s) → Build Hap(s)**），或使用下方[命令行构建步骤](#arkts-应用)。构建成功后，找到：

```text
entry/build/default/outputs/default/entry-default-signed.hap
```

将 SDK 自带的 `hdc` 加入 PATH，或使用它的完整路径。在项目根目录执行：

```sh
hdc list targets
hdc install entry/build/default/outputs/default/entry-default-signed.hap
hdc shell aa start -a EntryAbility -b com.flclash.harmony
```

macOS 默认安装位置下，也可以直接执行：

```sh
/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc \
  install entry/build/default/outputs/default/entry-default-signed.hap
```

连接多个设备时，在 HDC 命令中添加 `-t <设备标识>`，例如 `hdc -t <设备标识> install <HAP路径>`。请将占位内容替换为 `hdc list targets` 的实际结果。命令和参数可查阅[官方 HDC 文档](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/hdc)或 SDK 中的 `hdc -h`。

侧载应使用 **signed** HAP；`entry-default-unsigned.hap` 未包含有效设备签名，不能直接用于上述安装流程。复制 HAP 到手机后点击文件，也不能代替 DevEco Studio / HDC 的调试侧载流程。

### 8. 首次使用、更新与安装问题

安装后，在“配置”页导入自己的合法订阅或 YAML 配置，选择节点，再在仪表盘连接；首次连接需要确认系统 VPN 授权。已有其他 VPN 占用连接时，先在原应用或系统设置中断开它。

更新源码后，按需要重新编译内核，再用**同一包名、同一签名密钥**构建和覆盖安装；通常可保留应用数据。换签名或换包名时不能视为原应用的正常覆盖升级。卸载前，请先从“工具 → 备份与恢复”导出备份，卸载会删除应用内部配置。

| 现象 | 检查方法 |
| --- | --- |
| 找不到工程配置 | 确认已复制 `build-profile.example.json5`，且打开的是项目根目录 |
| SDK / HDS / API 缺失 | 安装与工程匹配的 API 26 SDK 和相应 DevEco Studio 组件，不要仅修改版本号 |
| 缺少 `.so` 或 `flclash_core.h` | 先完成原生内核编译，检查工具链路径和构建输出 |
| `unsupported GOOS/GOARCH pair` | 检查是否误用普通 Go；应使用 OpenHarmony Go 分支 |
| 设备未识别 / 未授权 | 检查数据线、USB 调试、设备端授权和 DevEco Studio 的设备列表 |
| 签名或 Profile 校验失败 | 核对包名、证书有效期、Profile 授权设备和产品签名配置，重新签名并构建 |
| 无法覆盖安装 | 检查现有应用与新 HAP 的包名和签名是否一致；需要卸载时先导出备份 |
| 安装成功但系统拒绝启动 | 解锁并保持亮屏，确认开发者模式已开启，并检查 Run 窗口的具体错误 |

个人签名生成的 `.p12`、证书密码、设备 UDID 和 Profile 只应保存在自己的开发环境中。仓库的 `.gitignore` 已排除个人构建配置与常见签名文件；提交修改前仍应检查实际文件范围。

## 使用方法

1. 在“配置”页导入自己的订阅 URL 或本地配置，并选择配置。
2. 在“代理”页选择节点。未连接 VPN 时，也可对本地已有完整参数的节点测速。
3. 在仪表盘点击连接，首次使用时允许系统 VPN 授权。
4. 根据需要切换规则、全局或直连模式；全局模式使用 `GLOBAL` 组的节点选择。
5. 在“工具 → 主题”选择深色、浅色或跟随系统，立即应用并保存。
6. 卸载前，在“工具 → 备份与恢复”将备份导出至应用外的文件目录；重新安装后导入恢复。

本软件不提供代理节点、订阅或网络服务。备份包含订阅链接和节点凭据，请妥善保管；恢复操作会替换当前配置。

## 来源与参考项目

| 项目 | 用途 |
| --- | --- |
| [FlClash](https://github.com/chen08209/FlClash) | 原始项目基础，使用用户提供的 v0.8.98 源码；参考页面结构、配置管理与内核接口 |
| [Clash.Meta · FlClash 分支](https://github.com/chen08209/Clash.Meta/tree/FlClash) | 实际使用的 mihomo 子模块来源，包含本项目的鸿蒙适配修改 |
| [mihomo](https://github.com/MetaCubeX/mihomo) | 代理协议、规则、DNS、控制器与流量处理能力的上游项目 |
| [ClashBox](https://github.com/xiaobaigroup/ClashBox) | 参考鸿蒙 VPN 扩展、TUN 配置及原生内核接入方式；实际构建内核来自上述 FlClash 子模块 |
| [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev) | 参考订阅/配置处理与客户端功能组织，未引入其桌面运行时 |
| ClashH（用户提供的本地项目） | 对照鸿蒙 VPN 服务、网络保护与生命周期实现，用于排查连接问题 |
| [OpenHarmony Go](https://gitcode.com/openharmony-sig/ohos_golang_go) | 提供支持 `GOOS=openharmony` 的 Go 工具链，用于构建 arm64 原生内核 |

精确提交和工具链来源见 [native/SOURCE.md](native/SOURCE.md)。页面布局也参考了用户提供的 FlClash 截图。OHClash 图标使用生成式图像工具制作，[提示词](design/ohclash-icon-prompt.md)已保留。

本项目与上述上游项目不具有官方隶属或背书关系，保留源码中的原始版权与许可信息。

## 当前限制

- VPN 目前覆盖 IPv4；IPv6 VPN 路由尚未接入。
- 离线测速需要本地节点参数。尚未缓存的 provider 节点与依赖 `dialer-proxy` 的链式代理需连接后测试。
- “请求”页面展示当前活动请求，不是持久化历史审计日志。
- 当前语言为简体中文；尚未实现语言切换、分应用代理和 WebDAV 同步。
- 节点可用性取决于订阅、服务端和网络环境；超时重试不保证失效节点恢复。
- 长时间息屏、运行中 Wi-Fi/蜂窝切换、折叠屏及分屏仍需进一步设备验证。
- 系统强制停止应用、撤销授权或其他 VPN 占用时，不能保证连接继续运行。

## 构建

### ArkTS 应用

首次克隆后，先复制无签名构建模板，并按照下节编译原生内核：

```sh
cp build-profile.example.json5 build-profile.json5
```

随后使用包含 **API 26 SDK** 的 DevEco Studio 打开项目、同步依赖，配置自己的签名证书与调试设备。`build-profile.json5` 和 `local.properties` 仅保存在本机，不提交到 Git。已有本地配置时不要重复复制覆盖。

```sh
/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin/ohpm install

DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap --no-daemon
```

以上为 macOS 默认安装路径，其他环境请按实际路径调整。不要发布个人签名密钥或本地订阅文件。

输出位于 `entry/build/default/outputs/default/`：`entry-default-signed.hap`（配置有效签名后生成）与 `entry-default-unsigned.hap`。

### 原生内核

仓库包含完整 Go 内核源码（包括本项目修改的 `Clash.Meta` 源码），不上传预编译 `.so`、生成的 C 头文件或 HAP。首次克隆及修改 Go 内核后，必须使用支持 OpenHarmony 的 Go 1.24.5 编译内核，再构建 HAP。构建脚本会生成 `entry/libs/arm64-v8a/libflclash_core.so` 和所需 C 头文件：

若尚未准备工具链，可在 macOS 上先安装官方主机版 **Go 1.24.5**，然后编译项目使用的 OpenHarmony Go 分支。下面将工具链放在已忽略的 `.local-toolchains/` 中，命令从项目根目录开始：

```sh
mkdir -p .local-toolchains
git clone --branch release-branch.go1.24 \
  https://gitcode.com/openharmony-sig/ohos_golang_go.git \
  .local-toolchains/ohos-go
git -C .local-toolchains/ohos-go checkout 302a5306b6fad2f47196360b82561d1db1f954cf
cd .local-toolchains/ohos-go/src
GOROOT_BOOTSTRAP=/path/to/host-go1.24.5 bash make.bash
cd ../../..
```

`GOROOT_BOOTSTRAP` 指向已安装的主机 Go **根目录**（其中应有 `bin/go`），而非 `go` 可执行文件。将占位路径替换为自己的安装位置；主机 Go 下载见 [Go 官方下载页](https://go.dev/dl/)。工具链编译成功后，从项目根目录运行：

```sh
OHOS_GO="$PWD/.local-toolchains/ohos-go/bin/go" \
OHOS_SDK=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony \
sh native/build-core.sh
```

若已有工具链，可指定现有路径：

```sh
OHOS_GO=/path/to/openharmony-go/bin/go \
OHOS_SDK=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony \
sh native/build-core.sh
```

版本和提交见 [native/SOURCE.md](native/SOURCE.md)。

## 项目结构

```text
entry/src/main/ets/
  pages/                 页面、交互与导航
  components/            实时速度曲线与流量圆环
  data/                  配置、备份、主题、授权及故障诊断
  entryability/          应用生命周期与系统主题变化
  vpnextension/          VPN 扩展与会话清理
entry/src/main/resources/
  base/                  浅色资源与共享资源
  dark/                  深色配色与图标
entry/src/main/cpp/       C N-API 桥接
native/core/             Go 内核与鸿蒙适配
native/core/Clash.Meta/   mihomo 子模块源码
tests/                  ArkTS 逻辑的宿主回归测试
```

## 开源文件范围

提交内容包括 ArkTS / C / Go 源码、应用图标与资源、依赖锁文件、测试、构建模板和上游许可证。

`.gitignore` 排除个人签名配置与证书、本机 SDK 路径、工具链和依赖缓存、IDE 状态、构建产物、预览文件、日志、订阅及备份目录；上游含认证字段的 `docs/config.yaml` 和 `test/config/` 测试配置也不提交。请将个人配置放在这些本地目录，不要写入源码或测试用例。

本项目回归测试不依赖上述上游测试配置。运行 mihomo 上游完整协议集成测试时，需自行从 [对应公开提交](https://github.com/chen08209/Clash.Meta/tree/70f0570405c3c2c47bb113b88db95006d239b346/test/config) 获取测试文件，或生成自己的测试证书与配置；不要将它们用于实际服务。

## 验证记录

构建、真机节点出站、离线测速、备份恢复、重复连接与后台崩溃修复已有验证记录。具体结果及未覆盖范围见 [TESTING.md](TESTING.md)，历史适配记录见 [docs/DEVELOPMENT_HISTORY.md](docs/DEVELOPMENT_HISTORY.md)。这些记录不等于所有设备和功能均已完成完整测试。

```sh
node --test tests/vpn-lifecycle.test.cjs tests/vpn-authorization.test.cjs tests/backup-validator.test.cjs
```

测试依赖 DevEco Studio 自带 TypeScript；原生生命周期、真实回环代理请求及控制器启停另有 Go race 测试。

## 免责声明

OHClash 仅供学习、技术研究与交流使用。使用本软件时，请遵守所在地的法律法规。

不得利用本软件从事任何违法犯罪行为，不得侵犯他人的合法权益。

使用者应对自己的使用行为负责。因使用者违法使用本软件而产生的责任，由使用者自行承担，软件作者不承担相关责任。

本软件不提供代理节点、订阅或网络服务，请自行确认所使用服务的合法性与安全性。

## 许可证

本项目保留原项目的 **GNU GPL v3** 许可证，见 [LICENSE](LICENSE)。第三方源码分别保留其版权和许可声明。修改与分发时请遵守对应许可证；免责声明不替代或变更开源许可证条款。
