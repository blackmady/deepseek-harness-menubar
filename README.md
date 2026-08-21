# DeepSeek Harness 菜单栏控制器

这是一个使用 Objective-C/AppKit 编写的原生 macOS 菜单栏应用，控制现有的 `com.dsh.web` LaunchAgent。它不显示 Dock 图标，点击顶部 DeepSeek 风格鲸鱼图标即可使用：

- 启动：`launchctl bootstrap gui/<uid> ~/Library/LaunchAgents/com.dsh.web.plist`
- 重启：`launchctl kickstart -k gui/<uid>/com.dsh.web`
- 停止：`launchctl bootout gui/<uid>/com.dsh.web`
- 状态：同时检查 LaunchAgent 和 `http://127.0.0.1:3080/`
- 打开 Web 页面、日志目录、退出控制器

## 构建和运行

```bash
cd deepseek-harness-menubar
bash build-app.sh
open DeepSeekHarnessMenuBar.app
```

或安装到 `~/Applications`：

```bash
bash install.sh
```

## 检查更新和安装更新

菜单栏中的“检查更新”会读取 GitHub Releases，并使用 macOS 当前的系统代理/PAC 设置访问 GitHub。若系统没有代理，会自动直连。

```text
https://github.com/blackmady/deepseek-harness-menubar/releases
```

发布新版本时，请把构建出的 ZIP 作为 Release Asset 上传。推荐命名为：

```bash
bash package-release.sh 1.1.0
```

将生成的 `DeepSeekHarnessMenuBar-v1.1.0.zip` 上传到 `v1.1.0` Release 的 Assets 区域。

应用会优先寻找名称中包含 `DeepSeekHarnessMenuBar` 的 ZIP，下载后校验 Bundle ID、版本号、可执行文件和代码签名，再替换当前应用并自动重新打开。服务本身和 `com.dsh.web` LaunchAgent 不会被修改。

## 检查和升级 DeepSeek Harness

菜单中另有一组独立的 Harness 更新操作。它们更新的是本机 `@deepseek-ai/dsh`，不是菜单栏控制器本身：

1. 点击“检查 Harness 更新”
2. 应用读取 `~/.dsh/runtime/node_modules/@deepseek-ai/dsh/package.json` 的当前版本
3. 使用 npm 查询 `@deepseek-ai/dsh` 最新版本
4. 点击“更新 DeepSeek Harness 到 vX.Y.Z”并确认
5. 临时卸载 `com.dsh.web`
6. 执行 npm 安装并重新加载 LaunchAgent

升级使用当前用户的 npm 配置，因此会沿用 `npm config get registry` 设置的镜像。应用也会读取 macOS 系统代理/PAC 设置，并将解析出的 HTTP/SOCKS 代理传给 npm。升级过程中建议先关闭正在进行的 Harness 任务。

前提是已经运行过 deepseek-harness 仓库里的 `install-dsh-service.sh`，生成 `~/Library/LaunchAgents/com.dsh.web.plist`。如果尚未安装，菜单仍会显示“未安装 LaunchAgent”，不会执行危险的猜测命令。

<img width="193" height="251" alt="deepseek-harness-menubar" src="https://github.com/user-attachments/assets/3a4d36f0-97c0-44cd-b822-0088d2d95eb8" />
