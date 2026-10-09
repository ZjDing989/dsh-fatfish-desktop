# 大肥鱼 · DeepSeek Harness 桌面宠物插件

一个面向 Windows 的开源 DSH 桌面宠物插件。大肥鱼陪在桌面上，用紧凑气泡显示 AI 当前正在做的动作，单击即可回到对应聊天。

这是社区项目，与 DeepSeek 官方没有隶属关系。

<p align="center"><img src="plugin/native/assets/fatfish.png" width="180" alt="大肥鱼桌面宠物角色" /></p>

## 环境要求

| 项目 | 要求 |
|---|---|
| 系统 | Windows 10 / 11，Windows PowerShell 5.1 与 WPF |
| 宿主 | DeepSeek Harness Desktop，当前适配目标为 `0.2.0-rc.2` |
| 开发与打包 | Node.js 22 或更新版本，附带 npm |

DSH 的预览版接口仍可能变化，升级宿主后需重新核对兼容性。安装脚本默认查找当前用户目录下的 `AppData\Local\Programs\DeepSeek Harness`；使用其他安装位置时，调整 [tools/desktop-cli.ps1](tools/desktop-cli.ps1) 中的宿主路径。

## 功能

| 操作 | 行为 |
|---|---|
| 单击宠物 | 显示并置前 DSH 主窗口 |
| 按住宠物拖动 | 移动并保存位置，拖动与松手时有互动动作 |
| AI 会话正在运行 | 头顶气泡显示当前动作或工具活动 |
| 悬停气泡堆 | 展开多个固定尺寸聊天卡片，无滚动、无翻页 |
| 单击气泡 | 跳转对应会话，并显示 DSH |
| 右键宠物 → 宠物设置 | 调整尺寸、透明度和动画 |
| 在 DSH 中停用插件 | 关闭宠物窗口并回收内部服务 |

折叠和展开后的卡片均为 326 × 63 的 WPF 逻辑像素：标题保留一行，第二行仅显示当前动作、工具名称或公开工具参数中的 `description`，过长时以省略号截断。气泡不展示 CoT 或回答正文，完整聊天可单击气泡到 DSH 查看。多个任务属于同一聊天时合并为一个气泡；聊天较多时使用多列排列。

气泡、右键菜单和设置自动跟随 Windows 应用浅色／深色模式与系统强调色。界面的光感由 WPF 柔和渐变、细边缘与悬停高光呈现；高对比度模式使用系统配色。

角色包含待机、悬停打招呼、拖动惊讶和眨眼四套透明 PNG，搭配呼吸、摆动与松手回弹动作。

## 从源码安装

下载或克隆仓库，先启动 DSH 桌面端，再在项目根目录双击 `install-plugin.cmd`，或运行：

```powershell
.\install-plugin.cmd
```

安装器先对本地 `plugin/` 源码执行 `npm pack`，生成 `dist/dsh-plugin-fatfish-desktop-<版本>.tgz`，再通过 DSH Desktop 自带的正式插件管理入口安装到 `desktop` profile。它会备份原 profile 配置到 `.data/backups/`，并检查插件依赖、bundle 启用和运行时健康状态。

首次安装由宿主正常加载插件。若宠物没有出现，检查 DSH 插件页的启用状态；必要时在当前任务结束后重新打开 DSH。

只生成可分发插件包：

```powershell
npm run pack:plugin
```

### 更新与卸载

更新源码后重新打包并安装：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\install-plugin.ps1 -Reinstall
```

随后在当前任务结束后退出并重新打开 DSH，使宿主载入新模块。更新会保留宠物设置；仅看到健康端点在线并不代表新版模块已经加载。

卸载：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\uninstall-plugin.ps1
```

也可通过 DSH 插件管理页停用或卸载。

## 架构与源码

插件安装在 DSH 宿主内，由宿主控制生命周期。Host 入口监听公开的 Agent／Session 事件并采集动作，Web Client 使用 `uiWorkspace.openSession` 跳转聊天。Windows 透明窗口由插件启动的 WPF 辅助子进程绘制；停用、卸载或宿主退出时回收子进程。

Host 与 WPF 之间使用仅监听本机回环地址、带随机 token 的内部通信。插件使用 DSH 自带运行时和 Windows WPF，无需另装独立桌宠应用，也不复制 Electron 运行时。

| 路径 | 用途 |
|---|---|
| [plugin/index.js](plugin/index.js) | 插件入口、事件订阅与子进程生命周期 |
| [plugin/state.js](plugin/state.js) | 运行任务聚合与当前动作描述 |
| [plugin/server.js](plugin/server.js) | 内部通信、鉴权与导航命令 |
| [plugin/client.js](plugin/client.js) | DSH 客户端连接与会话跳转 |
| [plugin/native/](plugin/native/) | WPF 宠物、主题、设置和状态贴图 |
| [plugin/test/](plugin/test/) | JavaScript 回归测试 |
| [tools/](tools/) | 打包、安装、卸载与原生检查 |

插件协议与接口说明见 [plugin/README.md](plugin/README.md)。安装器使用的官方 Desktop carrier CLI 位于宿主安装目录中的 `resources/app.asar/dsh/node_modules/@deepseek-ai/dsh-desktop-host/lib/cli.js`。

## 开发与测试

在项目根目录运行：

```powershell
npm test
npm run test:native
```

JavaScript 测试覆盖公开事件采集、动作描述、任务状态、鉴权与客户端导航。原生检查使用 Windows PowerShell 5.1 的 STA 模式构建 WPF 控件，验证固定尺寸、单行动作、主题和设置行为，并在 `.data/` 输出布局预览。

原生预览使用明确标注的模拟任务，不会为测试启动模型任务。`.data/` 是本地生成目录，不属于发布源码。

## 许可与美术来源

代码采用 [MIT 许可证](LICENSE)。本项目生成的透明 PNG 也按 MIT 发布，素材范围、出处与第三方权利说明见 [ASSETS.md](ASSETS.md)，美术要素与提示词摘要见 [design/art-prompts.md](design/art-prompts.md)。

角色参考[贴吧大肥鱼形象](https://tieba.baidu.com/p/10941228631)，项目发布中不包含第三方贴吧参考原图。角色、品牌等第三方权利不由本项目授权；项目不宣称是官方产品。
