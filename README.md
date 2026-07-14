# Codex Quota

<p align="center"><strong>简体中文</strong> · <a href="README_EN.md">English</a></p>

<p align="center">
  <img src="assets/codex-quota-icon-transparent.png" alt="Codex Quota icon" width="160" />
</p>

<p align="center">
  <img src="assets/codex-quota-interface-clean.png" alt="Codex Quota 状态栏与完整菜单界面" width="460" />
</p>

一个常驻在 macOS 状态栏的轻量工具，直接显示 Codex 剩余额度与距离下次刷新时间。

## 功能

- 状态栏常驻显示：`Codex 74% · 6天`
- 启动时读取额度，并每 60 秒自动刷新；Token 累计会结合本机会话日志实时递增
- 在菜单中显示今日、本月和本年累计 Token，并可选择是否显示在状态栏
- 可分别开关今日 Token、各额度窗口和刷新倒计时，自定义状态栏长度
- 状态栏文字支持默认模式与自定义标签
- 菜单中展示每个限额窗口的精确刷新时间
- 在应用菜单中点击 5 小时、1 周、1 月额度行，可切换是否显示在状态栏
- 支持手动刷新，以及一键打开 Codex 用量设置
- 通过本机 Codex app-server 读取已登录账号的数据；不会保存或上传令牌

## 要求

- macOS 14 或更高版本
- 已安装并登录 Codex 桌面版（或本机可执行 `codex`）
- Swift 6 工具链

## 安装

1. 从 [GitHub Releases](https://github.com/zkilxx/Codex-Quota/releases) 下载最新的 `Codex-Quota-*.dmg`。
2. 打开 DMG，将 **Codex Quota** 拖入“应用程序”文件夹。
3. 在“应用程序”中启动 Codex Quota；右上角状态栏会显示额度与刷新时间。

若 macOS 首次阻止打开，请在“系统设置 → 隐私与安全性”中确认打开。

## 开发

```bash
swift build
./script/build_and_run.sh --verify
```

可选运行模式：

- `--debug`：使用 LLDB 启动
- `--logs`：启动后查看应用日志
- `--telemetry`：查看统一日志中的应用子系统事件
- `--verify`：启动后检查进程是否存在

## 数据来源与隐私

Codex Quota 调用本机 `codex app-server --stdio` 读取账号用量和限额，并以只读方式读取 `~/.codex/sessions` 中的 Token 计数事件，用于补足服务端日统计的更新延迟。身份认证由本地 Codex 管理，应用不会读取、存储或传输账号凭据，也不会上传会话内容。

## 许可证

MIT
