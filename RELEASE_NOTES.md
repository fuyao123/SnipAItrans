# SnipAItrans 1.5.2

## 本次更新

- 在划词弹窗和主窗口查询单个英文单词时，显示美式音标。点击喇叭即可朗读，词典收录的多个读音可以分别播放。
- 音标词典随应用安装，发音使用 macOS 的离线美式语音。应用优先使用系统已安装的增强或高级语音，声音会因电脑上安装的语音而异。
- 菜单栏换上双层对话图标，适配浅色和深色外观。

## 安装

下载 `SnipAItrans-1.5.2-macOS.dmg` 后，将应用拖入 Applications。安装包适用于 Apple Silicon Mac，应用需要 macOS 13 或更新版本。划词翻译需要在系统设置的「辅助功能」权限中允许 SnipAItrans。安装包未经 Apple Developer ID 公证。

# SnipAItrans 1.5.1

## 本次更新

- 支持在访达快速预览的受支持文档中划词翻译，同时避免把文件列表中的文件名误认为选中文字。
- 多个 PDF 可在独立窗口中打开，各自保留阅读位置和翻译状态。
- 翻译结果窗口根据内容调整大小，改善较长译文被遮挡的问题。
- Ollama 划词译文在生成完成后一次显示。
- 移除不稳定的 Google 网页翻译源，并迁移相关旧设置；Gemini OAuth 翻译源继续保留。

## 安装

下载 `SnipAItrans-1.5.1-macOS.dmg`，打开后将应用拖入 Applications。安装包适用于 Apple Silicon Mac，应用需要 macOS 13 或更新版本；Apple 离线翻译需要 macOS 15 或更新版本，Ollama 需要 macOS 14 或更新版本。

安装包未使用 Apple Developer ID 公证；首次打开如遇系统提示，可在 Finder 中右键应用并选择“打开”。使用 OpenAI/ChatGPT OAuth 需要自行安装并登录 Codex CLI；使用 Gemini OAuth 需要自行安装并登录 Antigravity CLI。安装包不包含本地大模型或用户的登录信息。

# GPT 翻译助手 1.2.5

1.2.5 将 OpenAI/ChatGPT OAuth 翻译源的默认模型切换到 GPT-6 Luna。

## 本次更新

- OpenAI/ChatGPT OAuth 源默认使用 `gpt-6-luna`，继续复用本机 `codex login` 的登录会话。
- 已保存的默认模型或 `gpt-5.6-luna` 会自动迁移到 `gpt-6-luna`；其他自选模型保持原设置。
- 模型设置中可选择 GPT-6 Luna、Sol 和 Astra。

## 安装

下载 `GPT-Translator-1.2.5-macOS.dmg`，打开后将“GPT 翻译助手”拖入 Applications。

当前构建未经过 Apple Developer ID 公证。若 macOS 阻止首次打开，请在 Finder 中右键应用并选择“打开”。Apple 离线翻译需要 macOS 15 或更高版本；其他翻译源仍支持 macOS 13 或更高版本。

使用 OpenAI/ChatGPT OAuth 翻译源前，需要自行安装 Codex CLI 并完成 `codex login`；使用 Gemini/Google OAuth 翻译源前，需要自行安装 Antigravity CLI（`agy`）并完成 Google 登录。应用不会附带 CLI，也不会读取、复制或打包用户的 OAuth Token。

发布包不包含开发者或使用者的 OAuth 登录信息、API Key、钥匙串内容及本机配置。所有使用者需要自行登录或配置翻译服务。

# GPT 翻译助手 1.2.2

1.2.2 主要修复启用划词翻译后，其他应用菜单无法保持展开的问题。

## 产品构想

GPT 翻译助手希望成为一个简洁的翻译软件与截图软件的融合版：将划词翻译、快捷输入、截图标注、OCR 识别和截图翻译放进同一条轻量工作流，减少应用切换，不用在多个工具之间来回复制粘贴。

## 本次更新

- 修复启用划词翻译后，点击其他应用菜单栏时菜单显示后自动消失的问题。
- 菜单交互期间跳过划词翻译的全局鼠标监听和模拟 `⌘C`，不再干扰其他应用。

## 1.2.1 的截图修复

- 普通截图按 `⌘C` 后复制图片并关闭截图编辑窗口，即使鼠标已移出截图区域或焦点切换到其他应用也有效。
- 置顶截图按 `⌘C` 只复制图片，不关闭置顶截图，方便继续查看和重复复制。
- 置顶截图可从图面任意位置自由拖动，并修复拖动时画面抖动。
- 保留置顶截图的 `Esc` 和右上角关闭按钮；普通截图仍可通过 `Esc` 取消或关闭。

## 安装

下载 `GPT-Translator-1.2.2-macOS.dmg`，打开后将“GPT 翻译助手”拖入 Applications。

当前构建未经过 Apple Developer ID 公证。若 macOS 阻止首次打开，请在 Finder 中右键应用并选择“打开”。Apple 离线翻译需要 macOS 15 或更高版本；其他翻译源仍支持 macOS 13 或更高版本。

使用 OpenAI/ChatGPT OAuth 翻译源前，需要自行安装 Codex CLI 并完成 `codex login`；使用 Gemini/Google OAuth 翻译源前，需要自行安装 Antigravity CLI（`agy`）并完成 Google 登录。应用不会附带 CLI，也不会读取、复制或打包用户的 OAuth Token。

发布包不包含开发者或使用者的 OAuth 登录信息、API Key、钥匙串内容及本机配置。所有使用者需要自行登录或配置翻译服务。
