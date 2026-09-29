# dsh-auto-shutdown

A [DeepSeek Harness](https://www.npmjs.com/package/@deepseek-ai/dsh) plugin that shuts the dsh instance down
once the web UI stays disconnected past a short grace period.

面向 Windows 的 DeepSeek Harness 插件：浏览器页面全部断开并持续超过宽限期（默认 5 秒）后，让 dsh 实例优雅退出。
它跑在 dsh 服务进程内部，所以关掉浏览器后，后台不会留一个没人用的 node 进程。

## 环境要求

- Windows 10 / 11，Windows PowerShell 5.1（系统自带）
- Node.js，并已全局安装 dsh：`npm i -g @deepseek-ai/dsh`

## 安装

```powershell
git clone https://github.com/xy-12177/dsh-auto-shutdown.git
cd dsh-auto-shutdown
dsh plugin --profile web add .
```

`dsh plugin --profile web add .` 以**链接**方式注册插件，所以克隆目录别删、别挪（挪了就重跑一次）。

装完如果已经有 `dsh web` 在跑，先重启它，插件才会加载。

## 卸载

```powershell
dsh plugin --profile web remove dsh-auto-shutdown
```

## 自动关闭插件

每个浏览器页面都会通过 `/api/remote.mux` 保持一条 `$events` 流。
插件轮询 `ctx.typertGateway.remoteEventClients`：数量为 0 且持续 `disconnectGraceMs` 后，调用 `ctx.appExit(0)`。
同时它会挂一个 `unref()` 的 8 秒 `process.exit(0)` 兜底，因为 dispose 成功后进程并不保证会退出。

在 profile 的 `cordis.patch.yml` 里可以覆盖以下配置：

| key | 默认 | 说明 |
| --- | --- | --- |
| `enabled` | `true` | 总开关 |
| `pollMs` | `1000` | 采样间隔 |
| `disconnectGraceMs` | `5000` | 断开多久才退出；能盖住刷新标签页、短暂睡眠。`0` = 一断就退 |
| `requireEverConnected` | `true` | 至少连上过一次 UI 才开始计时（`--no-open` 这类启动不会被误杀） |

```yaml
- id: auto-shutdown
  config:
    disconnectGraceMs: 30000
```

已知边界：

- 机器休眠、网络硬断时，要靠 mux 心跳（2 秒 ping，丢 2 次 pong）才能发现，会晚几秒。
- 计数单位是 `$events` 流，不是页面。事件源被注销或出错时，网关会一次清空所有流，这时页面还开着也会被判定为 0。
- 多个标签页时，任意一个还活着就不会退出。

## 说明

非 DeepSeek 官方项目。

## License

MIT
