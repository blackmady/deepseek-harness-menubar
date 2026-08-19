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

前提是已经运行过 deepseek-harness 仓库里的 `install-dsh-service.sh`，生成 `~/Library/LaunchAgents/com.dsh.web.plist`。如果尚未安装，菜单仍会显示“未安装 LaunchAgent”，不会执行危险的猜测命令。

<img width="193" height="251" alt="deepseek-harness-menubar" src="https://github.com/user-attachments/assets/3a4d36f0-97c0-44cd-b822-0088d2d95eb8" />
