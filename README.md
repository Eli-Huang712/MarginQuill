# MarginQuill · 纸笺

MarginQuill is an AI-assisted notes workspace for macOS. Capture handwritten notes from an iPhone or local files, turn them into editable Markdown, and review uncertain passages in context. Confirm detected to-dos and appointments before sending them to Apple Reminders or Calendar.

The interface supports Simplified Chinese and English. It requires macOS 14 or later, [uv](https://docs.astral.sh/uv/) for image preprocessing, and your own OpenAI API key for transcription. Build with `./build.sh`, open `build/纸笺.app`, and enter the key in Settings → AI & Recognition. The key is stored in the macOS Keychain. Page images are sent to the OpenAI API when you start transcription.

## 使用

1. 点「纸稿」栏标题右侧的「导入纸稿」，可用 iPhone 或 iPad 拍照或扫描，也可多选本地文件。按 `⌘O` 可直接选文件。编号缩略图是识别和导出的顺序，可拖动或用左右箭头调整。多页 PDF 按原页序导入。
2. 应用在本地用 Apple Vision 和 OpenCV 检测纸边，边界不明确时会保留整张。点「调整角点」可试选纸边候选、重新检测、拖动四角、使用整张或轻调对比度。「查看原图」只切换预览。
3. 在齿轮设置里保存 OpenAI API 密钥，密钥存放在 Mac 钥匙串。在左下选择模型，点「识别 N 页」才会向 OpenAI Responses API 发送图像。程序按页调用，完成一页保存一次。
4. 中间默认渲染 Markdown 和 Mermaid，点「还原源码」编辑。疑点在相关文字或框图旁显示紫色编号。用「待核对」栏右上角的按钮收起栏，文档右上角的「待核对」按钮可重新展开并显示剩余数量。点文中的编号会自动展开右栏，定位到对应说明和纸稿。有坐标时会框出纸稿上的大致位置。核对后可标为已处理。导出只包含正文和 Mermaid 源码。
5. 标题栏左侧的时钟按钮可展开或收起历史栏，旁边依次是新建和 API 设置。点击记录会恢复原图、裁切设置、识别结果和处理过的疑点。重做完整识别会保存为新记录，不完整的记录可继续识别未完成的页面。可在每条记录的菜单里将它移到废纸篓。
6. 点正文旁的「待办」标记，对照原稿，确认标题、可选的截止日期和目标列表后点「加入提醒事项」。第一次读取列表时，macOS 会请求提醒事项访问权限。写入 iCloud 提醒列表后，可在启用了提醒事项同步的其他设备上查看。「周五前」或未写年份的日期保留为原文，供你选择具体日期。同一条已加入的待办会在纸笺中显示状态。
7. 宽窗口中侧栏停靠在正文两侧。窗口变窄时，侧栏改为从边缘滑出，收起后可浏览正文。侧栏动画遵循系统的「减少动态效果」设置。
8. 点「日历」标记，确认日程标题、日期和起止时间，或选择全天，再加入系统默认日历。纸笺只申请日历的写入权限。
9. 按 `⌘,` 打开设置。通用设置界面语言，外观设置显示模式与强调色，AI 与识别设置 API 密钥和默认模型，集成查看提醒事项和日历的授权状态。修改界面语言后重新打开应用。

历史记录保存在当前用户的 `Library/Application Support/PaperNotes/History`。预处理需要 [uv](https://docs.astral.sh/uv/)，首次运行可能下载 Python 3.12 和图像依赖。连续互通相机需在 Mac 和 iPhone 上使用同一个 Apple 账户，并开启 Wi-Fi 与蓝牙。[Apple 连续互通相机指南](https://support.apple.com/zh-cn/102332)

## 从源码构建

在安装 Xcode 或 macOS 命令行工具的 Mac 上运行：

```sh
./build.sh
```

应用生成在 `build/纸笺.app`，使用本机构建架构和临时签名，部署下限是 macOS 14。预览使用随源码打包的离线资源。若要修改预览的 JavaScript，可在源码目录运行：

```sh
npm --prefix Preview ci
npm --prefix Preview run build
./build.sh
```

## 单独运行预处理

```sh
uv run --python 3.12 --script Resources/prepare_paper_notes.py photo.heic page.png --report
```

`--report` 返回采用的角点和纸边候选，角点按左上、右上、右下、左下排列，坐标归一化。用 `--corners x1 y1 x2 y2 x3 y3 x4 y4` 指定角点，`--enhance` 轻调局部对比度，`--crop L T R B` 裁取裁正后图像的像素区域。

## Third-party notices

See [the bundled preview licenses](Resources/PreviewLicenses) for dependency license texts and attributions.
