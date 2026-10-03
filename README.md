# OHClash

面向 **HarmonyOS NEXT** 的原生代理客户端。界面与应用逻辑使用 **ArkTS / ArkUI**，代理数据面使用 **Go / mihomo**，通过 C N-API 对接鸿蒙系统 VPN / TUN。项目基于 FlClash 源码适配，不依赖 Flutter 运行时。

应用包含仪表盘、代理、配置、工具四个页面，支持白色浅色、原有深色和跟随系统外观。

> 当前为开发验证版本，目标 SDK 与最低兼容 SDK 均为 **26.0.0**，包含 arm64 原生库。包内版本号目前为 `0.8.98`，沿用原项目标识；不代表已兼容所有设备或完成上架认证。

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

`.gitignore` 排除个人签名配置与证书、本机 SDK 路径、工具链和依赖缓存、IDE 状态、构建产物、预览文件、日志、订阅及备份目录。请将个人配置放在这些本地目录，不要写入源码或测试用例。上游 `Clash.Meta` 的公开测试证书仅供测试，不得用于实际服务。

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
