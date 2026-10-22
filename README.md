# dsh-auto-shutdown

A [DeepSeek Harness](https://www.npmjs.com/package/@deepseek-ai/dsh) plugin that shuts the dsh instance down
once the web UI stays disconnected past a short grace period, with a Windows exit progress window.

面向 Windows 的 DeepSeek Harness 插件：浏览器页面全部断开并持续超过宽限期（默认 5 秒）后，让 dsh 实例优雅退出。
宽限期结束后弹出与 Windows 启动器一致的鲸鱼女仆卡片，显示“正在关闭…”及用时；确认 dsh 进程结束后显示“已退出”，约 1 秒后自动收起。无需点击确认。

检测逻辑跑在 dsh 服务进程内，窗口由独立的 PowerShell 进程显示，并由一个临时 Node 托管进程陪伴运行，因此能在 dsh 结束后继续显示退出结果。两者均隐藏控制台，窗口结束后自动退出。窗口代码和素材均包含在本插件中，无需安装 `dsh-windows-launcher`。

## 环境要求

- Windows 10 / 11，Windows PowerShell 5.1（系统自带）
- Node.js，并已全局安装 dsh：`npm i -g @deepseek-ai/dsh`

## 兼容性

`package.json` 的 `engines.dsh` 声明为 `>=0.2.1-rc.1 <0.3.0-0`。实测环境：

| dsh 运行时 | 结果 |
| --- | --- |
| `0.2.1-rc.2` | 既有插件启动已验证；退出窗口改动通过模拟宿主和一次性测试进程验证，不关闭用户正在运行的实例 |

依赖的宿主接口（`ctx.typertGateway.remoteEventClients`、`ctx.appExit`）在 `0.2.1-rc.2` 仍在。
dsh 在启动时会用 `engines.dsh` 校验插件；不在范围内会被整包跳过，因此升级 dsh 后请对照上表复核。

## 安装

安装本次稳定版：

```powershell
git clone --branch v0.2.0 https://github.com/xy-12177/dsh-auto-shutdown.git
cd dsh-auto-shutdown
dsh plugin --profile web add .
```

`dsh plugin --profile web add .` 以**链接**方式注册插件，所以克隆目录别删、别挪（挪了就重跑一次）。

装完如果已经有 `dsh web` 在跑，先重启它，插件才会加载。

也可以从 [GitHub Releases](https://github.com/xy-12177/dsh-auto-shutdown/releases/latest) 下载 ZIP 安装包，解压后进入 `dsh-auto-shutdown` 文件夹，执行 `dsh plugin --profile web add .`。安装目录同样需要保留。已有链接安装的用户可在原目录运行 `git fetch origin --tags`、`git checkout v0.2.0`，然后重启 dsh。

版本变化见 [CHANGELOG.md](CHANGELOG.md)。

## 卸载

```powershell
dsh plugin --profile web remove dsh-auto-shutdown
```

## 自动关闭插件

每个浏览器页面都会通过 `/api/remote.mux` 保持一条 `$events` 流。
插件轮询 `ctx.typertGateway.remoteEventClients`：数量为 0 且持续 `disconnectGraceMs` 后，准备退出窗口，交接完成再调用 `ctx.appExit(0)`。
同时它会挂一个 `unref()` 的 8 秒 `process.exit(0)` 兜底，因为 dispose 成功后进程并不保证会退出。

窗口显示前的准备最多等待 5 秒，交接确认最多再等待 1 秒；正常耗时取决于 PowerShell 和窗口编译速度。失败时继续关闭 dsh，不因窗口失败阻塞退出。准备期间页面重连会取消退出；提交交接后继续完成退出。

窗口使用保留的进程句柄观察 dsh 是否结束，仅进程真正结束才显示“已退出”。窗口接管后最多存活 30 秒，超时自行收起，不误报成功，也不额外杀进程。非 Windows 环境保持原有无窗口退出行为。

在 profile 的 `cordis.patch.yml` 里可以覆盖以下配置：

| key | 默认 | 说明 |
| --- | --- | --- |
| `enabled` | `true` | 总开关 |
| `pollMs` | `1000` | 采样间隔 |
| `disconnectGraceMs` | `5000` | 断开多久才开始退出；能盖住刷新标签页、短暂睡眠。`0` = 检测到断开即开始 |
| `requireEverConnected` | `true` | 至少连上过一次 UI 才开始计时（`--no-open` 这类启动不会被误杀） |
| `showExitWindow` | `true` | Windows 退出卡片；设为 `false` 恢复原有无窗口退出行为 |

```yaml
- id: auto-shutdown
  config:
    disconnectGraceMs: 30000
```

已知边界：

- 机器休眠、网络硬断时，要靠 mux 心跳（2 秒 ping，丢 2 次 pong）才能发现，会晚几秒。
- 计数单位是 `$events` 流，不是页面。事件源被注销或出错时，网关会一次清空所有流，这时页面还开着也会被判定为 0。
- 多个标签页时，任意一个还活着就不会退出。
- 实际检测受 `pollMs` 采样影响；窗口仅用于自动关闭路径，手动结束进程不会触发窗口。

## 预览与测试

仅预览窗口（不会启动 dsh、浏览器或创建工作目录/运行状态）：

```powershell
npm run preview
# 或使用 Windows PowerShell 5.1 的完整路径，不依赖 PATH：
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File .\lib\windows\exit-window.ps1 -Preview
```

```powershell
npm test
npm run test:windows
npm run test:visuals
```

JS 测试模拟宿主、时钟和窗口交接；Windows 集成测试只使用一次性测试进程，不结束当前 dsh。视觉测试在内存中覆盖浅色/深色及 100%/150% 缩放，不修改系统主题或 DPI；截图位于 `tests/windows/artifacts/`。升级链接安装的插件后，重启 dsh 生效。

## 说明

非 DeepSeek 官方项目。

## License

MIT
