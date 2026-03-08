# macOS 触控板边缘续拖原型设计

## 目标

实现类似 Windows 触控板上的“边缘续拖”体验：

- 处于拖动状态时，手指滑到触控板物理边缘后，光标仍能沿原方向继续前进。
- 适用于拖拽文件、拖选文本、截图框选这类基于左键拖动的交互。
- 手指离开边缘、停止拖动或松开按钮后，辅助立即停止。

## macOS 上的正确形态

这类能力不是 Finder 插件，也没有官方系统扩展点。
合理形态是：

- 一个常驻菜单栏 App
- 或一个后台 Agent
- 通过 Event Tap 监听全局鼠标拖动状态
- 通过私有触控板框架获取原始触点
- 通过合成拖拽事件推进光标

当前实现已经补成标准 `.app` bundle 结构，方便直接双击运行，而不是只依赖终端里的 `swift run`。
当前仓库也提供了原生 Xcode 工程，构建产物固定输出到 `xcode-build/<Configuration>/EdgeClutch.app`，用于减少权限记录漂移。

## 核心技术栈

- `CGEvent.tapCreate`: 监听全局左键按下、拖拽、抬起。
- `CGEvent(mouseEventSource:mouseType:mouseCursorPosition:mouseButton:)`: 合成额外的拖拽事件。
- `MultitouchSupport.framework` 私有 API:
  - `MTDeviceCreateList`
  - `MTRegisterContactFrameCallback`
  - `MTDeviceStart`
  - `MTDeviceStop`
- `NSScreen.screens`: 计算当前桌面的全局边界，避免把光标推到屏幕之外。

## 权限

运行时需要：

- Accessibility
- Input Monitoring

否则无法稳定监听全局拖拽或发送合成事件。

## 当前原型的取舍

为了先验证核心能力，当前实现做了这些取舍：

- 只在“已经发生左键拖动”的会话中启用，不会改普通指针移动行为。
- 通过触点重心和速度推断方向，在边缘区间内维持一个短时间的方向记忆。
- 优先支持内建触控板，不额外区分复杂外设。
- 使用私有 API，因此不适合上架 App Store。

## 下一阶段建议

1. 增加参数页，让用户调整边缘区大小、推进速度和方向保持时间。
2. 增加设备过滤，只对内建 Force Touch 触控板启用。
3. 在菜单栏里显示实时诊断，便于校准触点坐标方向。
4. 增加图标、开机启动和正式签名/公证流程。
5. 研究能否在抬指重新落指时保持更自然的“离合”体验。
