# Go 内核源码来源

- FlClash 发布版：`v0.8.98` (`7c61c90ac20493b474d19c75ec96262b478b4b88`)
- 子模块：`https://github.com/chen08209/Clash.Meta.git`
- 子模块提交：`70f0570405c3c2c47bb113b88db95006d239b346`
- `native/core/` 从用户提供的 `FlClash-main/core/` 复制；`native/core/Clash.Meta/` 从上述公开提交检出后复制。
- OpenHarmony Go 工具链：`https://gitcode.com/openharmony-sig/ohos_golang_go.git` 的 `release-branch.go1.24`，构建时提交 `302a5306b6fad2f47196360b82561d1db1f954cf`（Go 1.24.5）。用官方 Go 1.24.5 作为 `GOROOT_BOOTSTRAP` 执行 `src/make.bash`，再运行 `native/build-core.sh`。

内核与子模块的原始许可保留在各自源码目录。

开源仓库直接包含上述内核源码，无需额外初始化 Git 子模块。本项目对 `Clash.Meta/hub/route/server.go` 增加控制器生命周期适配，并新增 `server_lifecycle_test.go`。含认证字段的上游 `docs/config.yaml` 和 `test/config/` 测试配置不随本仓库发布，不影响应用和内核构建；上游完整协议集成测试需另行准备这些测试文件。

工具链、编译后的共享库和生成的 C 头文件不提交；首次克隆后请按根目录 README 编译。构建启用 `-trimpath`，避免将本机源码绝对路径写入新生成的 Go 二进制。

为避免发布固定私钥，`Clash.Meta/transport/openvpn/config_test.go` 的静态证书和 EC 私钥改为测试启动时在内存中生成临时证书与密钥；不写入文件、不改变生产协议实现。
