# MarginQuill · 纸笺

MarginQuill is an AI-assisted notes workspace for macOS. Capture handwritten notes from an iPhone or local files, turn them into editable Markdown, and review uncertain passages in context. Confirm detected to-dos and appointments before sending them to Apple Reminders or Calendar.

The interface supports Simplified Chinese and English. It requires macOS 14 or later, [uv](https://docs.astral.sh/uv/) for image preprocessing, and your own OpenAI API key for transcription. Build with `./build.sh`, open `build/纸笺.app`, and enter the key in Settings → AI & Recognition. The key is stored as plaintext in `~/Library/Application Support/PaperNotes/.env` with owner-only file permissions. Page images are sent to the OpenAI API when you start transcription.

## 使用

1. 点「导入纸稿 → 从 iPhone 或 iPad 导入 → 扫描文稿」，在手机上连续扫完几页，再点一次「存储」。返回的 PDF 会按页序拆开，并整理进同一份笔记。也可按 `⌘O` 多选本地照片或 PDF。编号缩略图是识别和导出的顺序，可拖动或用左右箭头调整。
2. 应用在本地用 OpenCV 寻找纸边并校正透视。裁正后的照片和 PDF 扫描页会检查外围留白，只裁明显、连续的空白边并为笔迹留余量。照片边界不明确时保留整张，可在「调整角点」中选候选、拖动四角或关闭留白裁剪。「查看原图」和「使用整张」可查看和恢复完整画面。状态栏显示读取、预处理进度和本机导入用时。多页共用一个预处理进程。
3. 在「设置 → AI 与识别」保存 OpenAI API 密钥，纸笺会把密钥保存在当前账户的本地 `.env` 中。可以点「从钥匙串迁移…」复制旧版密钥，macOS 此时可能要求验证一次。点「识别 N 页」才会向 OpenAI Responses API 发送图像。正文随识别结果逐步显示，状态栏显示当前阶段和已完成页数。每页完整返回后，根据最终结果保存正文、批注和用量。
4. 中间默认渲染 Markdown 和 Mermaid，点「还原源码」打开带行号的编辑器。疑点在相关文字或框图旁显示紫色编号。用「待核对」栏右上角的按钮收起栏，文档右上角的「待核对」按钮可重新展开并显示剩余数量。点文中的编号会自动展开右栏，定位到对应说明和纸稿。有坐标时会框出纸稿上的大致位置。核对后可标为已处理。导出只包含正文和 Mermaid 源码。
5. 标题栏左侧的时钟按钮可展开或收起历史栏，旁边依次是新建和 API 设置。点击记录会恢复原图、裁切设置、识别结果和处理过的疑点。重做完整识别会保存为新记录，不完整的记录可继续识别未完成的页面。可在每条记录的菜单里将它移到废纸篓。
6. 点正文旁的「待办」标记，对照原稿，确认标题、可选的截止日期和目标列表后点「加入提醒事项」。第一次读取列表时，macOS 会请求提醒事项访问权限。写入 iCloud 提醒列表后，可在启用了提醒事项同步的其他设备上查看。「周五前」或未写年份的日期保留为原文，供你选择具体日期。同一条已加入的待办会在纸笺中显示状态。
7. 宽窗口中侧栏停靠在正文两侧。窗口变窄时，侧栏改为从边缘滑出，收起后可浏览正文。侧栏动画遵循系统的「减少动态效果」设置。
8. 点「日历」标记，确认日程标题、日期和起止时间，或选择全天，再加入系统默认日历。纸笺只申请日历的写入权限。
9. 按 `⌘,` 打开设置。通用设置界面语言，外观设置显示模式与强调色，AI 与识别设置 API 密钥、默认模型和右下角的 Token 用量开关，集成查看提醒事项和日历的授权状态。修改界面语言后重新打开应用。

历史记录保存在当前用户的 `Library/Application Support/PaperNotes/History`。预处理需要 [uv](https://docs.astral.sh/uv/)，首次运行可能下载 Python 3.12 和图像依赖。连续互通相机需在 Mac 和 iPhone 上使用同一个 Apple 账户，并开启 Wi-Fi 与蓝牙。[Apple 连续互通相机指南](https://support.apple.com/zh-cn/102332)

## 从源码构建

开发测试期间，`main` 按提交更新。版本标签在正式发布时创建。

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

`--report` 返回采用的角点、纸边候选和实际应用的留白裁剪范围。角点按左上、右上、右下、左下排列，坐标归一化。用 `--corners x1 y1 x2 y2 x3 y3 x4 y4` 指定角点，`--trim` 裁外围留白，`--enhance` 轻调局部对比度，`--crop L T R B` 裁取处理后图像的像素区域。

## Third-party notices

See [the bundled preview licenses](Resources/PreviewLicenses) for dependency license texts and attributions.
