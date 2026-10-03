# XMac — X.com 的 macOS 原生外壳

> ## ⚠️ 免责声明 / Disclaimer
>
> - 本项目是 **非官方** 应用，**仅是把 x.com 网页用 `WKWebView` 套壳** 的浏览器外壳。
> - 与 **X Corp.**（原 Twitter）**没有任何关联**，未获其授权、认可或赞助。
> - 所有内容、账号、商标（“X”及其 Logo）均归 X Corp. 所有；本项目不提供任何 X 的服务。
> - 仅用于个人学习/自用，请遵守 X 的服务条款。作者不对使用后果负责。

把 [x.com](https://x.com) 包装成一个原生 macOS 应用：基于 Swift + `WKWebView`，
无 Electron、无第三方依赖，体积小、启动快，登录状态与 Cookie 会本地持久化。


- 目标系统：**macOS 12.7（Monterey）及以上**（`LSMinimumSystemVersion = 12.0`）
- 架构：**Mac Intel (x86_64)**，也可编译 **Apple Silicon (arm64)** 或 **通用 (universal)**
- 仅需 Xcode **Command Line Tools**（无需完整 Xcode）

## 功能

- 加载 x.com，Safari 风格 User-Agent，兼容性更好
- 顶部标题固定显示 **X**
- 顶部工具栏：后退 / 前进 / 刷新 / 查找 / 主页 / 登录
- **浏览器登录**：X 新版登录页在 `WKWebView` 中无法启动（且 Google 禁止嵌入式登录），
  改为在默认浏览器登录后把会话 Cookie 导入应用。见下方「登录」。
- **页内查找**：`⌘F` 打开查找栏，`⌘G` / `⇧⌘G` 下一个 / 上一个，`Esc` 关闭
- **菜单栏图标**：显示 / 隐藏窗口、刷新、主页、退出
- **Dock 未读角标**：自动解析标题中的 `(N)` 显示未读数，并在后台时请求注意
- **站外链接**在默认浏览器打开（`显示` 菜单可切换）
- **强制刷新**：`⇧⌘R` 忽略缓存重新加载
- 关闭窗口不退出，点 Dock 图标或菜单栏图标可重新打开
- 菜单快捷键：`⌘R` 刷新、`⌘L` 打开位置、`⌘[`/`⌘]` 前进后退、`⌘⇧H` 主页、`⌘+/-/0` 缩放
- **时间线图片修复**：X 用 `aspect-ratio` 排布长图时，WebKit 会把图片压成 ~1px 的竖条；
  应用会在 DOM 就绪后为这类容器补 `min-width`，恢复正常显示。
- 视频 / 直播（Spaces）自动播放，支持全屏与画中画
- 缩放级别会记忆并在下次启动 / 翻页时恢复
- 文件下载保存到「下载」文件夹并在访达中定位
- 站外自定义协议（`mailto:` 等）自动交给系统 App

## 登录

X 现在的登录流程是一个新客户端（`/i/jf/onboarding/web`），它在 `WKWebView` 里会一直卡在
加载动画；同时 Google 也禁止在嵌入式 WebView 中登录。因此使用浏览器登录 + 导入会话：

1. 点工具栏的**登录**按钮（或菜单 **X → 在浏览器中登录…**），会用默认浏览器打开 X 登录页。
2. 在浏览器里完成登录（Google / Apple / 手机号 / 密码均可）。
3. 回到应用，点菜单 **X → 从浏览器导入登录会话**（登录流程里的弹窗也可直接点「导入会话」）。

应用会从 **Safari** 的 Cookie 文件中读取 `auth_token` / `ct0` 等会话并写入应用，随后刷新生效。
若使用的是 Safari 以外的浏览器，会弹出对话框让你手动粘贴 `auth_token` 与 `ct0`。

> 说明：读取 Safari Cookie 需要应用对 `~/Library/Containers/com.apple.Safari/.../Cookies.binarycookies`
> 有读取权限；本机同一用户下通常可直接读取。会话 Cookie 只保存在本机，不会外发。


## 构建

```sh
cd XMac
./build_macos.sh                 # Mac Intel (x86_64) —— 默认
./build_macos.sh ARCH=arm64      # Apple Silicon
./build_macos.sh ARCH=universal  # 通用二进制
```

产物：`XMac/build/XMac.app`。

可选：打包成 DMG

```sh
./make_dmg.sh                    # -> build/X-macOS12-Intel.dmg
ARCH=universal ./make_dmg.sh     # -> build/X-macOS12-Universal.dmg
```

## 安装

```sh
cp -R XMac/build/XMac.app /Applications/
open /Applications/XMac.app
```

若应用是从网络下载的，首次打开可能被 Gatekeeper 拦截（本应用默认 **ad-hoc 签名**）。
移除隔离属性即可：

```sh
xattr -cr /Applications/XMac.app
```

想用开发者证书签名：

```sh
SIGN_IDENTITY="Apple Development: 你的名字 (TEAMID)" ./build_macos.sh
```

## 目录结构

```
XMac/
├── XMac/main.swift          # AppKit + WKWebView 外壳源码
├── Resources/
│   ├── Info.plist           # 应用元数据（版本由构建脚本注入）
│   ├── XMac.entitlements    # 摄像头/麦克风（Spaces）权限
│   └── make_icon.swift      # 构建时绘制 App 图标
├── build_macos.sh           # 编译 + 组装 .app + 图标 + 签名
└── make_dmg.sh              # 打包 DMG
```

## 说明

- 这是对网页版的封装，账号体系、内容与官方页面完全一致。
- 数据保存在 `~/Library/WebKit/com.local.xmac/`，删除该目录即可退出所有登录。
- 修改 Bundle ID、应用名或版本：见 `build_macos.sh` 顶部变量与 `Resources/Info.plist`。
