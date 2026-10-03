# OHClash（HarmonyOS / ArkTS）

最新稳定性修复与验证范围见 [TESTING.md](../TESTING.md)。2026-10-01 已定位并处理后台空闲 GC 回收 VPN 授权观察者触发的原生崩溃；保留单一进程级观察者，逐次注销回调。应用内增加系统故障订阅，便于区分崩溃、卡死与系统回收。

基于 FlClash v0.8.98 的 HarmonyOS Stage 应用。界面、配置管理与 VPN 生命周期使用 ArkTS / ArkUI；代理数据面沿用原项目的 Go/mihomo 内核，通过 C N-API 接入系统 TUN。此工程不依赖 Flutter 运行时。

## 功能

- 订阅 URL 和本地 YAML 导入；配置查看、编辑、更新、选择。
- 启动/停止系统 VPN，使用选中的配置启动本地 mihomo；TUN 使用 sing-tun 的 system 网络栈处理 IPv4 流量。鸿蒙真机的 TUN 描述符在 gVisor 初始化时对 `Fstat` 返回权限错误，因此使用无需该调用的 system 栈。内核为每个出站 TCP/UDP socket 选取具备 `INTERNET` 和 `NOT_VPN` 能力的物理网络，并通过 `OH_NetConn_BindSocket` 绑定，避免出站连接重新进入 VPN。
- 本机 REST 控制器，以及可选的外部控制器；显示模式、代理组、连接、规则，支持切换模式、选择节点、测速、关闭连接。
- 配置文件位于应用文件目录；本地控制器仅监听 `127.0.0.1:9090`，首次启动时生成随机 Secret。
- 四个 ArkTS 页面按参考图实现深色仪表盘、代理卡片、配置卡片及工具列表；底部 Dock 使用 HDS `HdsTabs` 的自适应系统材质和沉浸光感。
- 订阅卡片从 `subscription-userinfo` 响应头读取用量、总量和到期时间；代理、速度与流量从 mihomo 控制器读取。

启动前请先导入并选择 Clash/Mihomo YAML 配置或 V2Ray 节点列表订阅。Base64 订阅支持标准及 URL 安全字母表、省略填充、换行，也可导入 Base64 编码的 YAML。节点列表由内置 mihomo 转换器生成代理组和匹配规则。鸿蒙 VPN 的 DNS 请求由 mihomo 接管，因此即使订阅未开启 DNS，应用也会在运行时启用它；若未提供上游，则使用配置中的默认上游。VPN 的 TUN 网段为 `172.19.0.0/30`，与常见的 `198.18.0.0/16` Fake-IP 网段分离。已连接时选择另一配置会自动停止并重新启动 VPN。当前 TUN 设置仅覆盖 IPv4；IPv6 VPN 路由尚未接入。

## 来源和构建

`native/core/Clash.Meta` 从原项目所指向的 [FlClash 分支](https://github.com/chen08209/Clash.Meta/tree/FlClash) 的精确提交获取，版本信息见 [native/SOURCE.md](../native/SOURCE.md)。保留原项目 GPL-3.0 许可证及第三方源码版权。`entry/libs/arm64-v8a/libflclash_core.so` 是对应的本地 OpenHarmony arm64 构建产物，公开仓库需从源码生成。

重新编译内核需使用支持 `GOOS=openharmony` 的 Go 1.24.5 工具链（来源见 `native/SOURCE.md`），并安装 DevEco Studio API 26 SDK：

```sh
OHOS_GO=/path/to/openharmony-go/bin/go \
OHOS_SDK=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony \
sh native/build-core.sh
```

构建 HAP：

```sh
/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin/ohpm install
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw clean --no-daemon
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap --no-daemon
```

本地构建产物：`entry-default-signed.hap` 和 `entry-default-unsigned.hap`（不随源码上传）。已验证构建通过，HAP 中含 `libflclash_core.so` 与 `libflclash_napi.so`。在 HarmonyOS 7 虚拟机中，订阅准备已完成，但 `startVpnExtensionAbility` 未返回，也未创建 VPN 扩展进程；当前版本等待系统授权最多 120 秒；授权后另有 45 秒内核启动期限，超时会清理本次会话并允许重试。

2026-09-25 真机验证：系统 VPN、mihomo 控制器、TUN 和节点出站均可运行。控制器监听 `127.0.0.1:9090`；`DIRECT` 对国内网站测速返回 211 ms，一个真实订阅节点测速返回 4474 ms（延迟随网络和节点变化）。在全局模式选择节点后，系统浏览器成功加载维基百科页面；打开第二个页面时，`vpn-tun` 的 RX 从 371959 增至 1322363 字节、TX 从 556753 增至 1605207 字节。此前控制器未启动的原因是 OpenHarmony Go 工具链运行时将 `runtime.GOOS` 报为 `linux`，现改用构建标签判定鸿蒙平台；此前节点测速超时的原因是核心出站 socket 源地址落在 VPN TUN 上，现改为逐 socket 绑定物理网络。

2026-09-26 在 Wi-Fi 下重新启动验证：核心成功绑定新的物理网络，真实节点的主动测速返回 736 ms；默认规则模式加载 `MATCH,节点选择`，系统浏览器成功打开新的维基百科文章。此检查验证了两次启动分别使用蜂窝网络和 Wi-Fi，尚未覆盖运行中切换网络的场景。

真机若出现 `2203002`，表示系统中已有 VPN 连接。请先在原 VPN 应用或系统设置中断开该连接，再启动 FlClash；应用不会主动关闭其他应用的 VPN。VPN 路由参数参考 [ClashBox 的公开 ArkTS 实现](https://github.com/xiaobaigroup/ClashBox/blob/master/proxy_core/src/main/ets/rpc/CommonVpnService.ets)；ClashBox 的改版内核并未完整开源，因此本工程继续使用可编译的 mihomo 子模块。

## 2026-09-26 仪表盘与未连接测速

- 本地 YAML / Base64 / 分享链接订阅无需开启系统 VPN 即可显示节点和测速。临时 mihomo 协议适配器执行真实 HTTP HEAD 请求，并在完成后释放；不启动控制器或 TUN，不会在节点失败时降级直连。长按测试单个节点，延迟测试按钮最多八个并发持续补位测试当前组，在线与离线都会递归展开子组、去重具体节点，支持查看进度和停止。结果显示测试中、实际毫秒数或失败；离线结果在本次应用会话中按配置版本缓存。
- 离线测速需要节点参数包含在本地订阅中；仅有 provider 引用而未下载的节点、依赖 `dialer-proxy` 的链式代理仍需连接后测试。测速失败不会生成模拟延迟。
- 网络速度来自 mihomo `/connections` 累计计数的每秒差值，按实际采样间隔计算；图表绘制最近 60 个样本的上传与下载总速度。累计上传和下载包含已关闭连接，圆环依据真实占比绘制。应用回到前台时刷新累计量，长时间后台间隔不当作瞬时速度。
- VPN 扩展成功启动 TUN 后记录会话开始时间，仪表盘显示暂停按钮和 `HH:mm:ss`，停止后清除。模式切换 PATCH 内核并 GET 读回确认；未连接时可预选下次启动模式。全局模式使用 GLOBAL 组所选节点。
- 网络检测明确使用 IPv4（匹配当前 TUN 路由覆盖范围），关闭 HTTP 连接复用与缓存，避免切换模式后仍沿用旧出口连接。检测失败有重试状态，不显示固定国家或模拟位置。
- 保留 HDS 自适应沉浸光感 Dock；修复顶部标题、分组标签宽度、卡片裁切及 ArkUI Builder 参数导致的数值不刷新。速度渐变曲线、上传下载圆环和连接按钮按参考图实现。

验证：标准 macOS Go 工具链运行 `profile_preview_test.go` / `offline_delay_test.go` 通过，包括 YAML/Base64 解析、敏感字段不进入预览、真实回环 HTTP 代理请求以及代理失败时不回退直连。HAP 构建成功并已覆盖安装真机。未启动 VPN 时日本节点卡片实际显示 4926 ms；直连与代理模式检测到不同出口地区，全局切换节点后出口地区同步改变并成功打开维基百科 HarmonyOS 页面。随后累计上传 184.8 KB、下载 791.5 KB，曲线与连接计时均更新。以上延迟、出口与流量为本次验证样本，不保证固定数值；尚未验证折叠屏和分屏显示。

## 2026-09-27 稳定性与布局修复

- Dock 两侧留白 48 vp，高度 68 vp，保留 HDS 自适应材质；配置列表从顶部排列，卡片更新键包含配置版本与选中状态，订阅更新未返回用量头时保留上次数据。
- 测速改用 `https://www.gstatic.com/generate_204`，单次上限 10 秒，失败重试一次；离线任务由 Go 的 8 个工作协程执行，避免 NAPI 异步线程池限制，逐项回传结果。慢节点不会阻塞下一批全部任务，停止后取消在途请求。
- 测速、节点选择与页面刷新分别维护状态；普通数据刷新失败不会标记 VPN 已断开。扩展通过原子状态文件通知 TUN 就绪，避免跨进程 Preferences 缓存造成启动状态误判。
- 未连接时可保存每个配置的节点选择，下次启动传给内核；在线切换会读取控制器确认结果。缓存刷新不再覆盖刚保存的选择。

验证：原生库及签名 HAP 编译通过。标准 macOS Go 的 race 检查通过，覆盖八并发上限、慢首项不阻塞后续任务、取消队列、YAML/Base64 预览、真实 HTTP 代理请求和失败不回退直连。离线 provider 和链式代理限制仍见上节；超时重试不保证不可达节点恢复。

## OHClash 视觉标识

应用桌面名称、能力标签和启动图标已更新为 OHClash。保留原 bundle ID 以支持覆盖升级并保留配置。新图标通过内置 image_gen 生成，将 Clash 猫形意象与鸿蒙圆环意象融合，使用暖黑、柔粉与少量淡紫；[提示词](../design/ohclash-icon-prompt.md) 保留供后续迭代。Dock 四个 SVG 图标使用统一圆角线条与视觉尺寸，选中态采用柔粉描边胶囊；HDS 自适应系统材质继续由系统处理。签名 HAP 编译通过并覆盖安装，已通过手机截图检查 Dock 显示。
