# 大肥鱼 DSH 桌面宠物插件

这是安装到 DSH 的 Cordis 插件，包含 Host 入口、Web Client 模块与 Windows WPF 桌面绘制辅助进程。生命周期归 DSH 宿主管理：插件激活时创建 WPF 子进程，禁用、卸载或宿主退出时回收子进程。使用 Node 内置模块与 Windows 自带 WPF，不需要另装桌宠应用、额外 npm 或 Electron 运行时，也不启动模型任务。内部监听 `127.0.0.1` 的系统分配端口，默认发现文件为 `~/.dsh/fatfish-bridge.json`，宠物设置和日志保存于 `~/.dsh/fatfish-pet/`。

配置：`enabled`、`desktopPet`（默认 true）、`port`（默认 0）、`discoveryPath`、`profile`，以及开发时可选的 `nativeScript`、`assetsPath`。`allowedOrigins` 仅用于定制桌面壳；官方本地 Web Host 的确切 Origin 自动从 `ctx.webServer.port` 注册。任何任意 localhost Origin 均不会自动获准。

安装包声明 `dsh.bundle.patch`。可分发包通过 `npm pack ./plugin` 构建，安装操作见项目根目录说明。官方 Desktop carrier CLI 入口为安装目录下的 `resources/app.asar/dsh/node_modules/@deepseek-ai/dsh-desktop-host/lib/cli.js`；其 `plugin --profile desktop add <tgz>` 透传 pnpm 后，由官方 reconciliation 将新依赖中的有效 bundle 加入 `dsh.profile.bundles`，宿主监听该列表并热加载。本项目安装器核验依赖注册、bundle 启用和运行时健康；已存在的依赖不会自动重新启用或热更新，更新使用 `-Reinstall`，当前任务结束后退出并重新打开 DSH，以刷新模块缓存。健康端点可用本身不证明更新已加载。卸载可使用工作区的 `tools/uninstall-plugin.ps1` 或 DSH 插件管理页。

`native/assets/` 中是参照用户提供的[贴吧大肥鱼形象](https://tieba.baidu.com/p/10941228631)生成的透明 PNG 状态贴图。角色为蓝发、鲸鳍、鲸尾的 Q 版女仆：`fatfish-idle.png` 用于待机，`fatfish-hover.png` 用于悬停挥手，`fatfish-drag.png` 用于拖动时的惊讶表情与张开双手，`fatfish-blink.png` 用于闭眼眨眼；`fatfish.png` 是待机默认图。WPF 辅助进程负责状态切换与动作，不需要美术生成工具或浏览器预览。工作区 `design/art-prompts.md` 保存参考来源和提示词摘要，早期设计稿不进入运行依赖。

唯一桌面设置入口为右键宠物后选择“宠物设置”。气泡、右键菜单和设置界面自动跟随 Windows 应用浅色／深色模式及系统强调色（accent），每秒检查配色变化并更新 WPF 主题资源。光感由 WPF 柔和渐变、细边缘与悬停高光呈现；标题／动作描述与状态／高光颜色分开处理，以保持文字可读。高对比度模式使用 Windows 系统配色；角色 PNG 保持原有配色。

客户端包由 `dsh.client` 与 `./client` 导出被官方模块加载器发现。可信 DSH 页面通过 Host `Connection.fetch` 的 `GET /api/fatfish/client-config` 获取当前端口和本次启动随机 token；该端点处于 DSH 既有的 Host/Origin 校验与浏览器会话认证之后，Desktop 私有 API 载体代为提供 Host cookie，响应禁止缓存。客户端遇到桥重启或鉴权失败会重新读取，热安装不依赖重启宿主。`webserver/index-inject` 同时发布兼容的结构化 `window.__DSH_FATFISH__`；Desktop 只在初始 IPC 中缓存它，所以客户端不会把该缓存用作失效凭据的回退。普通 HTML 的 `tapIndex` 无法覆盖 Desktop 静态入口。内部桥没有公开 token bootstrap 端点。

API 使用 `Authorization: Bearer <token>`（兼容 query token），所有响应 `no-store`。`GET /v1/health`、`GET /v1/state`、`GET /v1/client/poll`；`POST /v1/action` 接收 `{type:"open-session",sessionId}`，只允许已见过的真实 Session。`ok:true` 代表已排队；返回的 `commandId` 在 `state.lastAction` 里有最终客户端确认。`POST /v1/client/ack` 为 `{id,ok,reason?}`；`POST /v1/client/state` 为 `{activeSessionId,focused,visible}`。请求体最多 16 KiB。只有确切可信 Origin 可以跨域调用，Node 消费端无需 Origin。

快照兼容 `v:1` 的 Pet Bridge，含 `host`、`pet`、`tasks`、`recent`、`activeSessionId`。任务仅按 Agent 建立一次，不因 subagent 描述重复建泡。每个任务新增独立的单行 `action` 字段，最多 100 字符，根据公开执行状态、工具名称或工具参数中的简短说明生成；原生气泡使用它显示当前正在做的事情。`reasoning` 和 `output` 分开保留最近 8000 字符，供内部采集兼容使用，不作为卡片内容；`activityKind` 标明旧活动缓冲的来源。

折叠气泡为紧凑的中性灰胶囊。折叠和悬停展开后的聊天卡片统一为 63px 固定高度，保留一行标题；第二行仅显示当前动作、工具名称或公开工具参数中的 `description`，超出宽度时显示省略号，没有动作描述时显示一条状态。多个聊天使用轻微三层堆叠，悬停后展开多个固定尺寸卡片，无滚动、无翻页；单击气泡到 DSH 查看对应聊天正文。

插件监听 `agent/status`、`agent/assistant-stream`、`agent/created`、`agent/disposed` 与 `session/event`，每秒以 live agents/jobs 名册对账。流的 `revision` 每帧递增，使用 `attemptId` 区分尝试、递增 revision/index 去重；`block-end` 的完整正文替换对应分片缓冲。中途启用时只读 `sessionController.follow()` 的公开初始快照，恢复本轮已有正文和进行中的压缩流，按公开游标合并较新的通知，随后及时释放读取。一个 Assistant attempt 开始时清空该 attempt 的两个文本缓冲；真正结束由 turn/end 或 Agent idle 判断。未由 DSH 模型提供的思考内容不会被生成或猜测。后台 job 显示注册表的真实 label/detail，并区分停止中、已取消和失败；无 owner 的全局 job 不会伪造可跳转的 Session。活跃任务不按数量截断，原生界面按会话合并气泡。轮询之间已开始且结束的极短 job 可能不会显示。

当前适配目标：官方 DSH Desktop `0.2.0-rc.2`，build `04f392c9ddd144fa426da2045178797da6db6c11`，对应的 `dsh-agent`、`dsh-session`、`dsh-client-ui-workspace`、`dsh-host-webserver` 模块。代码与本项目生成素材采用随包附带的 MIT 许可证，素材出处与第三方权利范围见 `ASSETS.md`。

官方依据：

- [Agent 观察事件](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/core/agent/README.md)：`ctx.agents`、状态、流式 start/chunk/end。
- [Agent payload 定义](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/core/agent/src/runtime-types.ts)：`{agent,status}` 与 `{agent,frame}`。
- [客户端模块协议](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/subsystems/client-modules.md)：`dsh.client`、`./client`、模块加载器。
- [Workspace 客户端](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/client/ui-workspace/README.md)：`uiWorkspace.openSession()` 同步切换主视图引用，历史异步加载。
- [Host 服务器](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/host/webserver/src/index.ts)：结构化 index injection 与端口。
- [Connection 传输](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/host/connection)：受认证 API 载体与精确 Fetch 路由。

`npm test --prefix plugin` 运行收集器状态、重试分片去重、任务开始/结束、启动对账、鉴权、Host 路由生命周期、热安装凭据刷新、超时取消与会话跳转命令确认测试。官方仍在开发预览期，未来升级应重新核对这些公开接口。
