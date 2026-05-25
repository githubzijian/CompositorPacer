<p align="center">
  <img src="Resources/Assets/CompositorPacerIcon-1024.png" width="128" height="128" alt="Compositor Pacer 图标">
</p>

<h1 align="center">Compositor Pacer</h1>

Compositor Pacer 是一个很小的 macOS 工具。它的目标不是优化某个 App，也不是修改系统参数，而是在 macOS 26 上创建一个真实存在、但肉眼看不见的小 Metal 窗口。这个窗口每次屏幕刷新时都会向 WindowServer 提交一帧很小的 Metal 画面，从而让系统合成路径保持活跃。对部分机器来说，这可以改善桌面动画、窗口切换、网页滚动/切换时的周期性掉帧感。

这个项目来自一次调试观察：在某些 macOS 26 环境里，只要系统中存在一个持续更新的真实窗口，桌面和网页动画就会更稳定。后续测试表明，关键不是某个具体 App，而是系统里有一个真实参与 WindowServer 合成、并持续提交新画面的窗口。

当前版本不依赖任何终端 App，也不依赖 PTY、脚本循环或滚动模拟。

## 核心实现

整个程序只有一个 Objective-C 源文件：`Sources/CompositorPacerManager.m`。它用同一个可执行文件实现了两种运行模式：

- 普通启动：进入 `AppDelegate`，显示控制窗口。
- 带 `--agent` 参数启动：进入 `AgentDelegate`，不显示控制 UI，只创建后台小 Metal 窗口。

入口逻辑在 `main()`：

```text
main()
  -> 如果参数里有 --agent：使用 AgentDelegate
  -> 否则：使用 AppDelegate
  -> [NSApp run]
```

点击 `Start` 时，控制窗口不会自己做刷新工作，而是通过 `NSTask` 再启动一份当前 app 的可执行文件，并传入 `--agent`。因此真正负责持续刷新的是独立 agent 进程。关闭控制窗口不会停止 agent；点击 `Close` 才会读取状态文件里的 pid，并向 agent 发送终止信号。

## 这里的“小 Metal 窗口”是什么

文档里说的“小 Metal 窗口”，不是一个普通用户会看到的窗口，也不是一张离屏图片。它在代码里由这几层组成：

```text
NSWindow                 一个真实 macOS 窗口，大小 36x36，透明，不接收鼠标事件
  -> MetalPacerView      放在窗口里的 NSView
  -> CAMetalLayer        这个 view 背后的 Metal layer
  -> CAMetalDrawable     每一帧要提交给系统合成器的小画面
```

可以把它理解成：屏幕角落里有一块 36x36 的透明小画布。用户看不见它，也点不到它，但 WindowServer 知道它是一个真实窗口。Compositor Pacer 每次屏幕刷新时都会在这块小画布上画一帧很轻量的 Metal 内容，然后把这帧提交给系统合成器。

很多图形文档会把这种“能被窗口系统合成、可以提交画面的区域”叫做 surface。为了避免概念混乱，下面主要称它为“小 Metal 窗口”。

## Agent 创建了什么

agent 启动后会执行三件事：

```text
AgentDelegate applicationDidFinishLaunching
  -> stopPreviousAgentInstanceIfNeeded
  -> startPacerSurface
  -> startStatusWriter
```

`startPacerSurface` 创建一个真实的 `NSWindow`：

- frame 固定为 `(8, 8, 36, 36)`，也就是屏幕左下附近一个 36x36 的小窗口。
- `styleMask` 是 `NSWindowStyleMaskBorderless`，没有标题栏和边框。
- `level` 是 `NSStatusWindowLevel`，让它属于比较高的窗口层级。
- `ignoresMouseEvents = YES`，不会挡住鼠标点击。
- `collectionBehavior` 包含 `CanJoinAllSpaces`、`FullScreenAuxiliary`、`Stationary`，让它尽量跟随所有 Space 和全屏场景。
- `alphaValue = 0.0`，肉眼不可见。
- content view 里放入一个 `MetalPacerView`。

这里最关键的点是：它不是离屏 texture，也不是后台 timer，而是一个真实挂在 `NSWindow` 上的 `CAMetalLayer`。即使窗口 alpha 是 0，它仍然走的是“真实窗口 + Metal layer + drawable + present”的路径，而不是纯后台计算。

`MetalPacerView` 初始化时会创建 Metal 环境：

```text
MTLCreateSystemDefaultDevice()
  -> newCommandQueue
  -> CAMetalLayer
  -> pixelFormat = BGRA8Unorm
  -> framebufferOnly = YES
  -> presentsWithTransaction = NO
  -> drawableSize = window size * backingScaleFactor
```

`presentsWithTransaction = NO` 很重要：present 不等待 Core Animation transaction 批处理，而是让 Metal command buffer 的 present 更直接地进入显示提交路径。

## 它是怎么刷新的

agent 会在 `MetalPacerView startDisplayLink` 里创建 `CVDisplayLink`：

```text
CVDisplayLinkCreateWithActiveCGDisplays
  -> CVDisplayLinkSetOutputCallback
  -> CVDisplayLinkStart
```

`CVDisplayLink` 的回调跟随活动显示器刷新节奏触发。每次回调会调用 `presentFrameFromDisplayLink`，直接提交一帧极轻量的 Metal 渲染：

```text
CVDisplayLink callback
  -> MetalPacerView presentFrameFromDisplayLink
  -> CAMetalLayer nextDrawable
  -> 创建 MTLRenderPassDescriptor
  -> loadAction = clear
  -> clearColor 轻微变化
  -> commandQueue commandBuffer
  -> renderCommandEncoderWithDescriptor
  -> endEncoding
  -> presentDrawable
  -> commit
  -> WindowServer compositor
```

每帧实际做的事情非常少：它没有绘制复杂几何，没有 shader 管线，没有纹理上传，只是 clear 一块 36x36 的 drawable，然后 `presentDrawable`。clear color 会随 frameCounter 轻微变化，目的是确保每次提交都是真实的新帧，而不是一个完全静止、可能被系统优化掉的表面。

换成更短的说法就是：

```text
每个显示刷新周期：
  拿一个 CAMetalLayer drawable
  清空成一帧很小的颜色 buffer
  把 drawable present 给系统合成器
```

如果 `nextDrawable` 返回 nil，说明当前 layer 没拿到可提交的 drawable，程序会增加 `drawableMisses`。这就是界面里 `Drawable Miss` 指标的来源。

## 为什么它可能让动画更流畅

macOS 的桌面动画、窗口移动、Mission Control、浏览器页面显示，最终都要经过 WindowServer 和系统合成器。系统会根据窗口状态、显示器刷新率、负载、电源策略等因素调度合成工作。正常情况下这套调度应该足够好，但在某些 macOS 26 环境里，实际表现像是合成路径在空闲或半空闲状态下不够积极，随后用户触发动画时会出现周期性掉帧。

Compositor Pacer 的做法是让 WindowServer 持续看到一个真实窗口正在按刷新节奏提交新 Metal 画面：

```text
NSWindow
  -> CAMetalLayer
  -> CVDisplayLink tick
  -> Metal command buffer
  -> presentDrawable
  -> WindowServer compositor
```

这可能带来几个效果：

- WindowServer 看到一个稳定更新的真实窗口，而不是完全空闲。
- Metal drawable 按显示刷新节奏持续进入 present 路径。
- 系统合成器更不容易进入某种低活跃度或间歇性调度状态。
- 用户随后触发窗口动画、Space 切换、网页滚动时，合成路径已经处在更活跃的状态。

所以它不是“加速 GPU”，也不是“提升帧率上限”。它更像是给系统合成器一个极轻量的节拍源，让合成/display pipeline 不要在问题环境里过度松弛。它改善的是响应稳定性和帧 pacing，而不是渲染能力本身。

这个解释是基于当前测试现象和 macOS 图形管线行为做出的工程判断，并不是 Apple 官方公开文档承诺的机制。所以：

- 在你的机器上有效，不代表所有 macOS 26 机器都一定有效。
- 它改善的是特定系统状态下的流畅度问题，不是通用性能优化器。
- 如果系统后续更新修复了 WindowServer 行为，这个工具可能就不再必要。

## 我的测试环境

目前这个工具主要是在下面这台机器和系统版本上观察、验证的：

- macOS：`26.5`，build `25F71`
- CPU：Intel Core i7-13700K
- 内存：`32 GB`
- GPU：AMD Radeon RX 5700 XT，`8 GB` VRAM，Metal supported

上面的信息只用于说明已验证环境。不同硬件、显示器配置或 macOS 版本下，实际效果可能不同。

## 为什么不是后台循环

早期线索来自一个持续刷新的普通窗口：当它存在时，桌面和网页切换会更顺。但后续测试说明，具体 App 不是关键，关键是“有一个真实参与屏幕合成的窗口持续提交新画面”。

这也是为什么当前实现没有使用这些方案：

- 纯 CPU while loop：会制造负载，但不会成为 WindowServer 的窗口合成输入。
- 普通后台 timer：只能唤醒进程，不等于提交显示 drawable。
- 离屏 Metal texture：GPU 可能在工作，但没有被窗口系统消费。
- 没有 NSWindow 的 IOSurface / CAMetalLayer：不一定进入同一条 WindowServer 合成路径。

当前验证有效的路径是：

```text
真实 NSWindow
  -> CAMetalLayer
  -> CVDisplayLink
  -> Metal presentDrawable
  -> WindowServer compositor
```

所以这个项目保留了一个 36x36 的透明小窗口。它可以透明、无边框、不接收鼠标事件，但它仍然是 WindowServer 可以管理和合成的真实窗口。

## 主程序和后台 agent

当前架构分成两个模式：

- 普通打开 `.app`：显示控制面板。
- 使用 `--agent` 启动：只创建负责持续刷新的小 Metal 窗口，不显示主界面。

点击 `Start` 后，控制面板会启动后台 agent。关闭主窗口不会停止 agent。只有点击 `Close` 时，才会主动结束后台 agent。

agent 会每秒写一次状态文件：

```text
~/Library/Application Support/Compositor Pacer/status.plist
```

控制窗口每秒读取这个文件，并用其中的 `pid`、`timestamp` 判断 agent 是否还活着。这样 UI 和真正的 pacing 工作是解耦的：UI 可以关闭，agent 仍然继续 present；agent 崩溃或退出，UI 也能在几秒内发现。

## 界面指标说明

主窗口里显示的指标来自后台 agent 写出的状态文件：

- `CPU`：agent 进程在采样周期内的 CPU 时间占比。
- `内存 / Memory`：agent 进程的 resident memory。
- `Metal FPS`：agent 每秒成功 present 的 Metal frame 数。
- `Drawable Miss`：`CAMetalLayer` 没有返回 drawable 的频率。

状态文件里还会记录：

- `presentedFrames`：agent 启动以来成功提交的总帧数。
- `drawableMisses`：agent 启动以来 `nextDrawable` 失败的总次数。
- `tinyWindow`：当前实现固定为 true，用来表明 agent 创建了这个 36x36 的透明小窗口。
- `alpha`：当前小窗口的透明度，默认是 0。

macOS 没有稳定公开的“单进程 GPU 占用百分比”API，所以这里没有显示传统意义上的 GPU 百分比。对这个程序来说，更关键的是 Metal present rate 和 drawable miss，它们更能反映这个小 Metal 窗口是否稳定参与系统合成。

## 开机启动

勾选 `Launch at login / 开机启动` 后，程序会写入一个用户级 LaunchAgent：

```text
~/Library/LaunchAgents/local.CompositorPacer.agent.plist
```

这个 LaunchAgent 只启动后台 agent，不会弹出主控制窗口。

## 运行依赖

运行打包好的 `.app` 不需要安装额外依赖。它只使用 macOS 自带框架：

- Cocoa
- QuartzCore
- Metal
- CoreVideo

不需要：

- 任何终端 App
- Python
- Node.js
- Homebrew
- Xcode

只有从源码编译时才需要 Xcode Command Line Tools 或 Xcode。

## 构建

在项目目录执行：

```zsh
./build.sh
```

构建产物会生成在：

```text
release/CompositorPacer/Compositor Pacer.app
```

## Xcode 打开

```zsh
open CompositorPacer.xcodeproj
```

项目主要文件：

```text
CompositorPacerSource/
  CompositorPacer.xcodeproj
  Sources/
    CompositorPacerManager.m
  Resources/
    Info.plist
    Assets.xcassets/
  build.sh
  release/
```

## 注意事项

- `CVDisplayLink` 在新 SDK 中被标记为 deprecated，但当前测试里这条路径是有效路径，所以暂时保留。
- 如果将来重构，关键点是不要把 Metal present 全部调度回主线程，否则可能失去当前效果，或者让 UI 本身变卡。
- 如果程序能运行但不再改善流畅度，优先检查后台 agent 是否还活着，以及 `Metal FPS` 是否接近显示器刷新率。
- 如果给别人分发，未签名/未公证的 `.app` 可能会被 Gatekeeper 拦截，需要右键打开，或者后续做签名和 notarization。
