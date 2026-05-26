<p align="center">
  <img src="Resources/Assets/CompositorPacerIcon-1024.png" width="128" height="128" alt="Compositor Pacer 图标">
</p>

<h1 align="center">Compositor Pacer</h1>

Compositor Pacer 是一个很小的 macOS 工具。它尝试解决一种特定的桌面流畅度问题：在部分 macOS 26 环境里，系统桌面、窗口切换、Space 切换、浏览器滚动或页面切换会出现周期性掉帧感；但当系统里存在一个持续更新的真实窗口时，这种掉帧感会明显减轻。

这个项目的做法不是修改系统参数，不是注入其他 App，也不是制造 CPU 负载。它只做一件事：

```text
创建一个肉眼不可见、不可点击、很小的真实 NSWindow
  -> 在窗口里挂一个 CAMetalLayer
  -> 用 CVDisplayLink 跟随屏幕刷新
  -> 每次刷新提交一帧极小的 Metal drawable
  -> 让 WindowServer 持续看到一个活跃的窗口合成输入
```

换句话说，它给 macOS 的窗口合成路径提供一个很轻的“节拍源”。如果你的机器正好遇到的是 WindowServer/compositor 在空闲或半空闲状态下调度不够积极的问题，它可能让后续桌面动画更稳定。

这不是 Apple 官方机制，也不是通用性能优化器。它是基于实际观察和当前代码路径的工程性尝试。

## 适用场景

你可能会需要它，如果你观察到：

- 桌面和窗口动画不是一直慢，而是偶发性、周期性地卡一下。
- 浏览器页面滚动、标签页切换、窗口移动在某些时刻 pacing 不稳定。
- 打开一个持续刷新画面的普通窗口后，系统动画反而变顺。
- CPU/GPU 本身并没有明显满载，但视觉上仍有掉帧感。

它不适合这些问题：

- 某个具体 App 自己渲染慢。
- GPU 或 CPU 已经持续满载。
- 显示器、线缆、刷新率设置、VRR/HDR 配置本身有问题。
- 你需要提升游戏或渲染程序的帧率上限。

Compositor Pacer 改善的目标是 compositor/display pipeline 的 pacing 稳定性，不是应用渲染能力。

## 代码结构

整个程序几乎都在一个文件里：

```text
Sources/CompositorPacerManager.m
```

它用同一个可执行文件实现两种模式：

```text
普通模式
  main()
    -> 没有 --agent 参数
    -> 使用 AppDelegate
    -> 显示控制窗口

Agent 模式
  main()
    -> 有 --agent 参数
    -> 使用 AgentDelegate
    -> 不显示控制 UI
    -> 创建透明 Metal pacer 窗口
```

入口逻辑很短：

```text
main()
  -> 检查 NSProcessInfo.processInfo.arguments 是否包含 --agent
  -> 创建 NSApplication
  -> agent 模式设置 NSApplicationActivationPolicyAccessory
  -> 挂 AppDelegate 或 AgentDelegate
  -> [app run]
```

`Resources/Info.plist` 里还设置了：

```xml
<key>LSUIElement</key>
<true/>
```

这让 app 从启动第一刻起就是无 Dock 图标的 UIElement。这样用户点击 Start 启动后台 agent，或者登录时 LaunchAgent 自动启动 agent，都不会让 Dock 栏出现短暂变化。

## 为什么要分成控制窗口和 agent

控制窗口和真正做 pacing 的 agent 是两个进程。

点击 `Start / 启动` 时，`AppDelegate` 不会自己创建 Metal 刷新窗口，而是调用 `startAgent:`：

```text
startAgent:
  -> 如果状态文件显示 agent 已运行，直接返回
  -> 删除旧 status.plist
  -> NSTask 启动当前 bundle 的 executable
  -> 参数传入 --agent
```

也就是：

```text
Compositor Pacer.app/Contents/MacOS/Compositor Pacer --agent
```

这样设计有几个原因：

- 控制窗口可以关闭，后台 pacing 仍然继续。
- 控制 UI 的刷新和真正的 Metal present 分离，互不影响。
- agent 可以由 LaunchAgent 在用户登录时直接启动，不需要弹出主窗口。
- 如果 agent 退出，控制窗口可以通过状态文件发现，而不是依赖窗口对象还在不在。

点击 `Close / 关闭` 时，控制窗口会读取状态文件里的 `pid`，向 agent 发送 `SIGTERM`。如果短时间内还没退出，再发送 `SIGKILL`。关闭控制窗口本身不会停止 agent。

## Agent 启动后做什么

`AgentDelegate applicationDidFinishLaunching:` 只做三件事：

```text
AgentDelegate applicationDidFinishLaunching
  -> stopPreviousAgentInstanceIfNeeded
  -> startPacerSurface
  -> startStatusWriter
```

### 1. 停掉旧 agent

`stopPreviousAgentInstanceIfNeeded` 会读取：

```text
~/Library/Application Support/Compositor Pacer/status.plist
```

如果里面有旧 pid，并且这个 pid 仍然存活，就先发 `SIGTERM`。这样可以避免用户重复点击 Start、或者登录项和手动启动叠加时出现多个 pacer agent 同时 present。

### 2. 创建真实窗口

`startPacerSurface` 创建一个 `NSWindow`：

```text
frame:              (8, 8, 36, 36)
styleMask:          NSWindowStyleMaskBorderless
level:              NSStatusWindowLevel
opaque:             NO
alphaValue:         0.0
ignoresMouseEvents: YES
collectionBehavior: CanJoinAllSpaces | FullScreenAuxiliary | Stationary
```

这些设置分别对应下面的目的：

- `36x36`：面积很小，降低内存带宽和合成成本。
- `NSWindowStyleMaskBorderless`：没有标题栏、边框和普通窗口装饰。
- `alphaValue = 0.0`：肉眼不可见。
- `ignoresMouseEvents = YES`：不会挡住鼠标点击。
- `NSStatusWindowLevel`：让它作为系统级小窗口存在，不依赖普通文档窗口层级。
- `CanJoinAllSpaces` 和 `FullScreenAuxiliary`：尽量让它在多 Space、全屏场景中仍然存在。
- `Stationary`：避免它参与普通窗口移动语义。

最重要的是：它仍然是一个真实 `NSWindow`。这不是离屏 texture，也不是纯后台 timer。WindowServer 能看见这个窗口，Core Animation 能管理它，窗口里的 `CAMetalLayer` 能拿到 drawable 并 present。

### 3. 写状态文件

agent 每秒写一次状态文件：

```text
~/Library/Application Support/Compositor Pacer/status.plist
```

里面包括：

```text
pid
timestamp
running
tinyWindow
alpha
cpuPercent
memoryMB
memoryTrendMBPerMinute
metalFPS
missesPerSecond
presentedFrames
drawableMisses
```

控制窗口每秒读取这个文件。它用 `pid + timestamp` 判断 agent 是否真的还活着：

```text
timestamp 距离当前时间小于 3 秒
并且 kill(pid, 0) 返回进程存在
  -> 认为 agent 正在运行
```

这样 UI 不需要和 agent 建立 IPC，也不需要共享对象。一个 plist 文件就足够表达状态。

## 小 Metal 窗口到底是什么

agent 创建的窗口结构是：

```text
NSWindow
  -> contentView
    -> MetalPacerView : NSView
      -> CAMetalLayer
        -> CAMetalDrawable
```

`MetalPacerView` 初始化时做了这些事：

```text
MTLCreateSystemDefaultDevice()
  -> newCommandQueue
  -> wantsLayer = YES
  -> layer = CAMetalLayer
  -> pixelFormat = MTLPixelFormatBGRA8Unorm
  -> framebufferOnly = YES
  -> opaque = YES
  -> presentsWithTransaction = NO
  -> drawableSize = view size * backingScaleFactor
```

几个关键点：

- `CAMetalLayer` 是窗口系统能消费的 Metal layer。
- `framebufferOnly = YES` 表示这个 drawable 只用于渲染输出，不做纹理采样等额外用途。
- `presentsWithTransaction = NO` 让 Metal command buffer 的 present 不等待 Core Animation transaction 批处理。
- `drawableSize` 会按 backing scale 调整，避免 Retina 屏幕下 layer 尺寸不匹配。

这个 view 不画复杂内容。每一帧只是 clear 一个很小的 drawable，然后 present。

## 每一帧发生什么

agent 使用 `CVDisplayLink` 跟随显示刷新：

```text
startDisplayLink
  -> CVDisplayLinkCreateWithActiveCGDisplays
  -> CVDisplayLinkSetOutputCallback
  -> CVDisplayLinkStart
```

每次 display link 回调会调用：

```text
presentFrameFromDisplayLink
```

这一帧的完整路径是：

```text
CVDisplayLink callback
  -> CAMetalLayer nextDrawable
  -> 创建 MTLRenderPassDescriptor
  -> loadAction = clear
  -> clearColor 按 frameCounter 轻微变化
  -> commandQueue commandBuffer
  -> renderCommandEncoderWithDescriptor
  -> endEncoding
  -> presentDrawable
  -> commit
  -> WindowServer/compositor 接收这个窗口的新 frame
```

它没有 shader 管线，没有纹理上传，没有几何绘制。它只是让一个 36x36 的 layer 每个刷新周期都提交一个真实的新 drawable。

clear color 会轻微变化，这是有意的。如果每一帧内容完全一样，系统或驱动层有机会把它当作静态内容处理。轻微变化可以让每次 present 更明确地成为“新帧”。

如果 `nextDrawable` 返回 nil，代码会增加 `drawableMisses`。这通常表示 `CAMetalLayer` 当前没有可用 drawable，可能是窗口/layer 状态、系统压力或 present 节奏导致。UI 里的 `Drawable Miss` 就来自这里。

## 为什么不是别的方案

这个项目有意避开了一些看似简单、但对目标无效或不稳定的做法。

### 纯 CPU 循环

CPU 循环可以制造负载，但它不会向 WindowServer 提交窗口内容。它可能让系统更忙，却不一定让 compositor 的窗口合成输入更活跃。

### 后台 timer

普通 timer 只能唤醒进程。它不等于显示刷新，也不等于向屏幕合成路径提交 drawable。

### 离屏 Metal texture

离屏 Metal 工作能让 GPU 忙起来，但如果结果没有挂到一个真实窗口的 layer 上，WindowServer 不一定把它当作桌面合成输入。

### 完全透明但没有真实 present 的窗口

只有窗口还不够。关键是这个窗口背后的 `CAMetalLayer` 持续拿 drawable 并 `presentDrawable`。这个 present 才是让系统合成路径持续收到新内容的动作。

当前代码保留的是这条路径：

```text
真实 NSWindow
  -> CAMetalLayer
  -> CVDisplayLink
  -> Metal command buffer
  -> presentDrawable
  -> WindowServer/compositor
```

## 为什么它可能有效

macOS 桌面最终由 WindowServer 和系统 compositor 统一合成。窗口移动、Mission Control、Space 切换、浏览器窗口内容，最终都会经过这个系统级显示路径。

在理想情况下，系统应该自己用合适的节奏调度合成工作。但在某些 macOS 26 环境里，实际现象像是：

```text
桌面没有持续活跃的窗口更新
  -> compositor/display pipeline 进入较松弛的调度状态
  -> 用户突然触发动画或滚动
  -> 前几帧或某些周期的 pacing 不稳定
```

Compositor Pacer 的假设是：

```text
持续存在一个极小、真实、按刷新节奏 present 的窗口
  -> WindowServer 持续收到轻量合成输入
  -> compositor/display pipeline 更不容易完全松弛
  -> 用户触发其他动画时，显示路径已经处在活跃节奏中
```

这也是为什么它不追求高 GPU 使用率。理想状态下，CPU 和内存都应该很低，Metal FPS 接近显示器刷新率，Drawable Miss 接近 0。

## 开机启动

勾选 `Launch at login / 开机启动` 后，程序会写入用户级 LaunchAgent：

```text
~/Library/LaunchAgents/local.CompositorPacer.agent.plist
```

plist 里的核心内容是：

```text
Label: local.CompositorPacer.agent
ProgramArguments:
  - 当前 app bundle 里的 executable
  - --agent
RunAtLoad: true
KeepAlive: false
```

所以它的语义是：用户登录后自动启动后台 agent，不弹出控制窗口。

默认情况下，开机启动没有勾选。控制窗口只是检查上面的 plist 是否存在：

```text
plist 存在   -> 复选框显示已勾选
plist 不存在 -> 复选框显示未勾选
```

`KeepAlive = false` 表示 launchd 只在登录时启动一次。如果 agent 后续崩溃，launchd 不会自动重启它。这是当前版本的保守选择，避免异常情况下反复拉起。

## Dock 行为

这个 app 在 `Info.plist` 中设置了 `LSUIElement = true`。因此：

- 主控制窗口不会常驻 Dock 图标。
- 点击 Start 启动 `--agent` 时，Dock 不应闪动。
- 登录项启动 agent 时，Dock 不应出现临时图标。

代码里 agent 模式还会调用：

```text
[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory]
```

这是运行时的补充设置。真正防止启动瞬间 Dock 变化的关键是 `LSUIElement`，因为它在进程注册为 app 之前就生效。

## 指标怎么看

控制窗口显示的指标来自 agent 写出的状态文件。

### CPU

代码用 `getrusage(RUSAGE_SELF)` 计算 agent 进程的 user time + system time，再除以采样间隔。它反映的是 agent 自身 CPU 开销。

### Memory

代码用 `task_info(mach_task_self(), MACH_TASK_BASIC_INFO, ...)` 读取 resident memory。UI 显示的是 MB。

### Metal FPS

agent 记录 `presentedFrames`。每秒状态刷新时，用这一秒新增的 frame 数除以经过时间，得到 Metal FPS。它应该接近当前显示器刷新率。

### Drawable Miss

每当 `CAMetalLayer nextDrawable` 返回 nil，`drawableMisses` 加 1。UI 显示每秒 miss 数。正常情况下它应该接近 0。

### 为什么没有 GPU 百分比

macOS 没有稳定公开的单进程 GPU 百分比 API。对这个工具来说，更重要的不是 GPU 占用，而是：

```text
Metal FPS 是否稳定
Drawable Miss 是否很低
CPU/Memory 是否足够小
```

## 当前测试环境

目前主要观察和验证环境：

- macOS: `26.5`, build `25F71`
- CPU: Intel Core i7-13700K
- Memory: `32 GB`
- GPU: AMD Radeon RX 5700 XT, `8 GB` VRAM, Metal supported

这只表示已验证环境，不表示所有 macOS 26 设备都会有同样效果。

## 运行依赖

运行打包好的 `.app` 不需要安装额外依赖。它只使用 macOS 自带框架：

- Cocoa
- QuartzCore
- Metal
- CoreVideo

不需要：

- Terminal 或其他终端 App
- Python
- Node.js
- Homebrew
- Xcode

只有从源码构建时才需要 Xcode Command Line Tools 或 Xcode。

## 构建

在项目目录执行：

```zsh
./build.sh
```

构建产物：

```text
release/CompositorPacer/Compositor Pacer.app
```

GitHub Release 可以上传 zip 版本，例如：

```text
release/CompositorPacer/CompositorPacer-0.1.0-macos.zip
```

## Xcode 打开

```zsh
open CompositorPacer.xcodeproj
```

项目结构：

```text
CompositorPacer/
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

- `CVDisplayLink` 在新 SDK 中被标记为 deprecated，但当前版本保留它，因为它直接表达了“跟随显示刷新触发 present”的目标。
- 如果将来迁移到新的 display link API，关键是保留“真实窗口 + CAMetalLayer + 每刷新周期 presentDrawable”的路径。
- 不建议把所有 Metal present 调度回主线程。当前代码让 display link 回调直接提交极小的 command buffer，是为了减少 UI 线程参与。
- 未签名/未公证的 `.app` 可能被 Gatekeeper 拦截。分发给其他用户时，首次打开可能需要右键选择 Open，或者后续做 Developer ID 签名和 notarization。
- 如果程序能运行但没有改善，先检查 agent 是否运行、`Metal FPS` 是否接近刷新率、`Drawable Miss` 是否接近 0。
