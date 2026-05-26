#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#import <mach/mach.h>
#import <sys/resource.h>
#import <signal.h>
#import <unistd.h>

static NSString * const PacerLaunchAgentLabel = @"local.CompositorPacer.agent";
static NSString * const PacerLegacyLaunchAgentLabel = @"local.CompositorPacer";
static NSString * const PacerStatusFileName = @"status.plist";

static BOOL PacerUseChineseLanguage(void) {
    for (NSString *language in NSLocale.preferredLanguages) {
        if ([language.lowercaseString hasPrefix:@"zh"]) {
            return YES;
        }
    }
    NSString *localeLanguage = NSLocale.currentLocale.languageCode.lowercaseString ?: @"";
    return [localeLanguage hasPrefix:@"zh"];
}

static NSString *PacerText(NSString *key) {
    static NSDictionary<NSString *, NSString *> *english = nil;
    static NSDictionary<NSString *, NSString *> *chinese = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        english = @{
            @"app.title": @"Compositor Pacer",
            @"app.subtitle": @"Native compositor pacing for macOS 26",
            @"status.running": @"Running",
            @"status.stopped": @"Stopped",
            @"metric.cpu": @"CPU",
            @"metric.memory": @"Memory",
            @"metric.metal": @"Metal FPS",
            @"metric.miss": @"Drawable Miss",
            @"login.title": @"Launch at login",
            @"login.detail": @"Agent only",
            @"button.start": @"Start",
            @"button.close": @"Close",
            @"metric.idle": @"Idle",
            @"cpu.low": @"Low process overhead",
            @"cpu.moderate": @"Moderate overhead",
            @"cpu.high": @"High overhead",
            @"memory.stable": @"Stable",
            @"metal.refresh": @"On refresh",
            @"metal.below": @"Below target",
            @"metal.low": @"Too low",
            @"miss.clean": @"Clean",
            @"miss.occasional": @"Occasional miss",
            @"miss.pressure": @"Drawable pressure",
            @"ready.title": @"Ready to start.",
            @"ready.detail": @"Tiny pacer surface is always enabled.",
            @"stopped.detail": @"Background agent is stopped.",
            @"warn.cpu.title": @"CPU is higher than expected.",
            @"warn.cpu.detail": @"Check display refresh rate.",
            @"warn.miss.title": @"Drawable misses detected.",
            @"warn.miss.detail": @"Tiny pacer surface is always enabled.",
            @"warn.memory.title": @"Memory is rising.",
            @"warn.memory.detail": @"Watch for a few minutes.",
            @"healthy.title": @"Metal pacing looks healthy.",
            @"healthy.detail": @"CPU low, memory stable, Metal on refresh.",
            @"log.login.failed": @"launch at login update failed: %@",
            @"log.login": @"launch at login %@",
            @"log.enabled": @"enabled",
            @"log.disabled": @"disabled",
            @"log.starting": @"Starting compositor pacer agent...",
            @"log.start.failed": @"agent start failed: %@",
            @"log.start.requested": @"agent start requested.",
            @"log.stopping": @"Closing pacer...",
            @"log.stopped": @"Pacer closed.",
            @"error.start.agent": @"Unable to start agent"
        };
        chinese = @{
            @"app.title": @"Compositor Pacer",
            @"app.subtitle": @"macOS 26 原生合成节奏保持器",
            @"status.running": @"运行中",
            @"status.stopped": @"已停止",
            @"metric.cpu": @"CPU",
            @"metric.memory": @"内存",
            @"metric.metal": @"Metal FPS",
            @"metric.miss": @"Drawable Miss",
            @"login.title": @"开机启动",
            @"login.detail": @"仅后台 Agent",
            @"button.start": @"启动",
            @"button.close": @"关闭",
            @"metric.idle": @"空闲",
            @"cpu.low": @"进程开销较低",
            @"cpu.moderate": @"进程开销中等",
            @"cpu.high": @"进程开销较高",
            @"memory.stable": @"稳定",
            @"metal.refresh": @"跟随刷新",
            @"metal.below": @"低于目标",
            @"metal.low": @"过低",
            @"miss.clean": @"正常",
            @"miss.occasional": @"偶发 miss",
            @"miss.pressure": @"Drawable 压力",
            @"ready.title": @"准备启动。",
            @"ready.detail": @"微型 pacer surface 始终启用。",
            @"stopped.detail": @"后台 Agent 已停止。",
            @"warn.cpu.title": @"CPU 高于预期。",
            @"warn.cpu.detail": @"请检查显示器刷新率。",
            @"warn.miss.title": @"检测到 Drawable miss。",
            @"warn.miss.detail": @"微型 pacer surface 始终启用。",
            @"warn.memory.title": @"内存正在上升。",
            @"warn.memory.detail": @"建议观察几分钟。",
            @"healthy.title": @"Metal pacing 状态良好。",
            @"healthy.detail": @"CPU 低、内存稳定、Metal 跟随刷新。",
            @"log.login.failed": @"开机启动更新失败：%@",
            @"log.login": @"开机启动已%@",
            @"log.enabled": @"启用",
            @"log.disabled": @"停用",
            @"log.starting": @"正在启动 compositor pacer agent...",
            @"log.start.failed": @"agent 启动失败：%@",
            @"log.start.requested": @"已请求启动 agent。",
            @"log.stopping": @"正在关闭 pacer...",
            @"log.stopped": @"Pacer 已关闭。",
            @"error.start.agent": @"无法启动 agent"
        };
    });
    return (PacerUseChineseLanguage() ? chinese[key] : english[key]) ?: english[key] ?: key;
}

static NSURL *PacerApplicationSupportDirectory(void) {
    NSURL *directory = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                               inDomains:NSUserDomainMask].firstObject;
    return [directory URLByAppendingPathComponent:@"Compositor Pacer" isDirectory:YES];
}

static NSURL *PacerStatusURL(void) {
    return [PacerApplicationSupportDirectory() URLByAppendingPathComponent:PacerStatusFileName];
}

static double PacerProcessCPUTime(void) {
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) != 0) {
        return 0.0;
    }
    double user = (double)usage.ru_utime.tv_sec + (double)usage.ru_utime.tv_usec / 1000000.0;
    double system = (double)usage.ru_stime.tv_sec + (double)usage.ru_stime.tv_usec / 1000000.0;
    return user + system;
}

static NSUInteger PacerResidentMemoryBytes(void) {
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t result = task_info(mach_task_self(),
                                     MACH_TASK_BASIC_INFO,
                                     (task_info_t)&info,
                                     &count);
    if (result != KERN_SUCCESS) {
        return 0;
    }
    return (NSUInteger)info.resident_size;
}

@interface MetalPacerView : NSView
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property(nonatomic, strong) CAMetalLayer *metalLayer;
@property(nonatomic, assign) NSUInteger frameCounter;
@property(atomic, assign) unsigned long long presentedFrames;
@property(atomic, assign) unsigned long long drawableMisses;
@property(atomic, assign) BOOL displayLinkActive;
@property(nonatomic, assign) CVDisplayLinkRef displayLink;
- (void)startDisplayLink;
- (void)stopDisplayLink;
- (void)presentFrame;
- (void)presentFrameFromDisplayLink;
@end

@implementation MetalPacerView

static CVReturn MetalPacerDisplayLinkCallback(CVDisplayLinkRef displayLink,
                                              const CVTimeStamp *now,
                                              const CVTimeStamp *outputTime,
                                              CVOptionFlags flagsIn,
                                              CVOptionFlags *flagsOut,
                                              void *displayLinkContext) {
    (void)displayLink;
    (void)now;
    (void)outputTime;
    (void)flagsIn;
    (void)flagsOut;
    @autoreleasepool {
        MetalPacerView *view = (__bridge MetalPacerView *)displayLinkContext;
        [view presentFrameFromDisplayLink];
    }
    return kCVReturnSuccess;
}

+ (Class)layerClass {
    return [CAMetalLayer class];
}

- (CALayer *)makeBackingLayer {
    return [CAMetalLayer layer];
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.device = MTLCreateSystemDefaultDevice();
        self.commandQueue = [self.device newCommandQueue];
        self.wantsLayer = YES;
        if (![self.layer isKindOfClass:[CAMetalLayer class]]) {
            self.layer = [CAMetalLayer layer];
        }
        CAMetalLayer *metalLayer = (CAMetalLayer *)self.layer;
        self.metalLayer = metalLayer;
        metalLayer.device = self.device;
        metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        metalLayer.framebufferOnly = YES;
        metalLayer.opaque = YES;
        metalLayer.presentsWithTransaction = NO;
        metalLayer.contentsScale = NSScreen.mainScreen.backingScaleFactor ?: 1.0;
    }
    return self;
}

- (void)dealloc {
    [self stopDisplayLink];
}

- (BOOL)wantsUpdateLayer {
    return YES;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self resizeDrawable];
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self resizeDrawable];
}

- (void)resizeDrawable {
    if (![self.layer isKindOfClass:[CAMetalLayer class]]) {
        return;
    }
    CAMetalLayer *metalLayer = (CAMetalLayer *)self.layer;
    CGFloat scale = self.window.backingScaleFactor ?: NSScreen.mainScreen.backingScaleFactor ?: 1.0;
    metalLayer.contentsScale = scale;
    metalLayer.drawableSize = CGSizeMake(MAX(1.0, NSWidth(self.bounds) * scale),
                                         MAX(1.0, NSHeight(self.bounds) * scale));
}

- (void)startDisplayLink {
    if (self.displayLink || !self.device) {
        return;
    }
    self.presentedFrames = 0;
    self.drawableMisses = 0;
    CVDisplayLinkRef link = NULL;
    CVReturn result = CVDisplayLinkCreateWithActiveCGDisplays(&link);
    if (result != kCVReturnSuccess || !link) {
        return;
    }
    CVDisplayLinkSetOutputCallback(link, MetalPacerDisplayLinkCallback, (__bridge void *)self);
    self.displayLinkActive = YES;
    CVDisplayLinkStart(link);
    self.displayLink = link;
}

- (void)stopDisplayLink {
    if (!self.displayLink) {
        return;
    }
    self.displayLinkActive = NO;
    CVDisplayLinkStop(self.displayLink);
    CVDisplayLinkRelease(self.displayLink);
    self.displayLink = NULL;
}

- (void)presentFrame {
    if (!self.device || !self.commandQueue || self.hidden || self.alphaValue < 0.01) {
        return;
    }
    [self resizeDrawable];
    if (![self.layer isKindOfClass:[CAMetalLayer class]]) {
        return;
    }
    CAMetalLayer *metalLayer = (CAMetalLayer *)self.layer;
    id<CAMetalDrawable> drawable = [metalLayer nextDrawable];
    if (!drawable) {
        self.drawableMisses++;
        return;
    }

    self.frameCounter++;
    double phase = (double)(self.frameCounter % 360) / 360.0;
    MTLRenderPassDescriptor *descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    descriptor.colorAttachments[0].texture = drawable.texture;
    descriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.06 + 0.03 * sin(phase * 6.28318530718),
                                                                  0.10 + 0.05 * cos(phase * 6.28318530718),
                                                                  0.13 + 0.04 * sin((phase + 0.33) * 6.28318530718),
                                                                  1.0);

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:descriptor];
    [encoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
    self.presentedFrames++;
}

- (void)presentFrameFromDisplayLink {
    if (!self.displayLinkActive || !self.device || !self.commandQueue || !self.metalLayer) {
        return;
    }

    id<CAMetalDrawable> drawable = [self.metalLayer nextDrawable];
    if (!drawable) {
        self.drawableMisses++;
        return;
    }

    self.frameCounter++;
    double phase = (double)(self.frameCounter % 360) / 360.0;
    MTLRenderPassDescriptor *descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    descriptor.colorAttachments[0].texture = drawable.texture;
    descriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.06 + 0.03 * sin(phase * 6.28318530718),
                                                                  0.10 + 0.05 * cos(phase * 6.28318530718),
                                                                  0.13 + 0.04 * sin((phase + 0.33) * 6.28318530718),
                                                                  1.0);

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:descriptor];
    [encoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
    self.presentedFrames++;
}

@end

@interface AgentDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(nonatomic, strong) NSWindow *pacerWindow;
@property(nonatomic, strong) MetalPacerView *metalPacerView;
@property(nonatomic, strong) NSTimer *statusTimer;
@property(nonatomic, assign) CFTimeInterval lastStatusWallTime;
@property(nonatomic, assign) double lastStatusCPUTime;
@property(nonatomic, assign) unsigned long long lastStatusFrames;
@property(nonatomic, assign) unsigned long long lastStatusMisses;
@property(nonatomic, assign) double lastMemoryMB;
@end

@implementation AgentDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [self stopPreviousAgentInstanceIfNeeded];
    [self startPacerSurface];
    [self startStatusWriter];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return NO;
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    if (sender == self.pacerWindow) {
        [self.pacerWindow orderOut:nil];
        return NO;
    }
    return YES;
}

- (NSRect)pacerFrame {
    return NSMakeRect(8, 8, 36, 36);
}

- (void)stopPreviousAgentInstanceIfNeeded {
    NSDictionary *status = [NSDictionary dictionaryWithContentsOfURL:PacerStatusURL()];
    int pid = [status[@"pid"] intValue];
    if (pid > 0 && pid != (int)getpid() && kill((pid_t)pid, 0) == 0) {
        kill((pid_t)pid, SIGTERM);
        [NSThread sleepForTimeInterval:0.2];
    }
}

- (void)applyPacerWindowAppearance {
    self.pacerWindow.alphaValue = 0.0;
    self.pacerWindow.level = NSStatusWindowLevel;
    self.pacerWindow.ignoresMouseEvents = YES;
}

- (void)startPacerSurface {
    NSRect frame = [self pacerFrame];
    self.pacerWindow = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    self.pacerWindow.title = @"Compositor Pacer Surface";
    self.pacerWindow.delegate = self;
    self.pacerWindow.releasedWhenClosed = NO;
    self.pacerWindow.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorStationary;
    self.pacerWindow.backgroundColor = NSColor.blackColor;
    self.pacerWindow.opaque = NO;
    [self applyPacerWindowAppearance];

    self.metalPacerView = [[MetalPacerView alloc] initWithFrame:self.pacerWindow.contentView.bounds];
    self.metalPacerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.pacerWindow.contentView addSubview:self.metalPacerView];
    [self.pacerWindow orderFront:nil];
    [self.metalPacerView startDisplayLink];
}

- (void)startStatusWriter {
    self.lastStatusWallTime = CACurrentMediaTime();
    self.lastStatusCPUTime = PacerProcessCPUTime();
    self.lastStatusFrames = self.metalPacerView.presentedFrames;
    self.lastStatusMisses = self.metalPacerView.drawableMisses;
    self.statusTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                        target:self
                                                      selector:@selector(statusTick:)
                                                      userInfo:nil
                                                       repeats:YES];
    self.statusTimer.tolerance = 0.1;
    [[NSRunLoop mainRunLoop] addTimer:self.statusTimer forMode:NSRunLoopCommonModes];
    [self statusTick:nil];
}

- (void)statusTick:(NSTimer *)timer {
    (void)timer;
    CFTimeInterval now = CACurrentMediaTime();
    double cpuNow = PacerProcessCPUTime();
    CFTimeInterval elapsed = MAX(0.001, now - self.lastStatusWallTime);
    double cpuPercent = MAX(0.0, (cpuNow - self.lastStatusCPUTime) / elapsed * 100.0);
    unsigned long long frames = self.metalPacerView.presentedFrames;
    unsigned long long misses = self.metalPacerView.drawableMisses;
    double metalFPS = (double)(frames - self.lastStatusFrames) / elapsed;
    double missesPerSecond = (double)(misses - self.lastStatusMisses) / elapsed;
    double memoryMB = (double)PacerResidentMemoryBytes() / 1048576.0;
    double memoryTrend = self.lastMemoryMB > 0.0 ? (memoryMB - self.lastMemoryMB) / elapsed * 60.0 : 0.0;
    self.lastMemoryMB = memoryMB;

    NSDictionary *status = @{
        @"pid": @((int)getpid()),
        @"timestamp": @([[NSDate date] timeIntervalSince1970]),
        @"running": @YES,
        @"tinyWindow": @YES,
        @"alpha": @0.0,
        @"cpuPercent": @(cpuPercent),
        @"memoryMB": @(memoryMB),
        @"memoryTrendMBPerMinute": @(memoryTrend),
        @"metalFPS": @(metalFPS),
        @"missesPerSecond": @(missesPerSecond),
        @"presentedFrames": @(frames),
        @"drawableMisses": @(misses)
    };

    NSURL *directory = PacerApplicationSupportDirectory();
    [[NSFileManager defaultManager] createDirectoryAtURL:directory
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
    [status writeToURL:PacerStatusURL() atomically:YES];

    self.lastStatusWallTime = now;
    self.lastStatusCPUTime = cpuNow;
    self.lastStatusFrames = frames;
    self.lastStatusMisses = misses;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.statusTimer invalidate];
    [self.metalPacerView stopDisplayLink];
    [[NSFileManager defaultManager] removeItemAtURL:PacerStatusURL() error:nil];
}

@end

@interface CenteredTextFieldCell : NSTextFieldCell
@end

@implementation CenteredTextFieldCell

- (NSRect)drawingRectForBounds:(NSRect)rect {
    NSRect drawingRect = [super drawingRectForBounds:rect];
    NSSize textSize = [self cellSizeForBounds:rect];
    CGFloat offset = floor((NSHeight(rect) - textSize.height) / 2.0);
    if (offset > 0.0) {
        drawingRect.origin.y += offset;
        drawingRect.size.height -= offset;
    }
    return drawingRect;
}

@end

@class AppDelegate;

@interface AppearanceView : NSView
@property(nonatomic, weak) id appearanceDelegate;
@end

@implementation AppearanceView

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    if ([self.appearanceDelegate respondsToSelector:@selector(applyCurrentAppearance)]) {
        [self.appearanceDelegate performSelector:@selector(applyCurrentAppearance)];
    }
}

@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSButton *launchAtLoginCheck;
@property(nonatomic, strong) NSTextField *launchDetailLabel;
@property(nonatomic, strong) NSButton *startButton;
@property(nonatomic, strong) NSButton *closeButton;
@property(nonatomic, strong) NSTextField *detailLabel;
@property(nonatomic, strong) NSTextField *metricsLabel;
@property(nonatomic, strong) NSTextField *cpuValueLabel;
@property(nonatomic, strong) NSTextField *cpuStatusLabel;
@property(nonatomic, strong) NSTextField *memoryValueLabel;
@property(nonatomic, strong) NSTextField *memoryStatusLabel;
@property(nonatomic, strong) NSTextField *metalValueLabel;
@property(nonatomic, strong) NSTextField *metalStatusLabel;
@property(nonatomic, strong) NSTextField *missValueLabel;
@property(nonatomic, strong) NSTextField *missStatusLabel;
@property(nonatomic, strong) NSTextField *recommendationTitleLabel;
@property(nonatomic, strong) NSTextField *recommendationDetailLabel;
@property(nonatomic, strong) NSTextView *logView;
@property(nonatomic, strong) NSMutableArray<NSView *> *panelViews;
@property(nonatomic, strong) NSMutableArray<NSView *> *metricCardViews;
@property(nonatomic, strong) NSView *headerPanel;
@property(nonatomic, strong) NSView *headerDivider;
@property(nonatomic, strong) NSTimer *metricsTimer;
@property(nonatomic, assign) CFTimeInterval lastMetricsWallTime;
@property(nonatomic, assign) double lastMetricsCPUTime;
@property(nonatomic, assign) unsigned long long lastMetricsFrames;
@property(nonatomic, assign) unsigned long long lastMetricsMisses;
@property(nonatomic, assign) double lastMemoryMB;
@property(nonatomic, assign) double memoryTrendMBPerMinute;
@property(nonatomic, assign) BOOL pacerRunning;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [self buildWindow];
    [self startMetricsSampler];
    [self refreshStatus];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return NO;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    (void)sender;
    (void)flag;
    [self refreshStatus];
    [self.window deminiaturize:nil];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    return YES;
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    if (sender == self.window) {
        [self.window orderOut:nil];
        return NO;
    }
    return YES;
}

- (void)buildWindow {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 360, 420)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = PacerText(@"app.title");
    self.window.delegate = self;
    self.window.releasedWhenClosed = NO;
    self.window.movable = YES;
    self.window.movableByWindowBackground = NO;
    self.window.minSize = NSMakeSize(360, 420);
    self.window.maxSize = NSMakeSize(360, 420);
    self.window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces;
    [self.window center];
    [self.window standardWindowButton:NSWindowZoomButton].enabled = NO;

    AppearanceView *content = [[AppearanceView alloc] initWithFrame:self.window.contentView.bounds];
    content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    content.appearanceDelegate = self;
    self.window.contentView = content;
    self.panelViews = [NSMutableArray array];
    self.metricCardViews = [NSMutableArray array];
    content.wantsLayer = YES;
    content.layer.backgroundColor = [self resolvedColor:NSColor.windowBackgroundColor].CGColor;

    self.headerPanel = [[NSView alloc] initWithFrame:NSMakeRect(0, 318, 360, 102)];
    self.headerPanel.wantsLayer = YES;
    [content addSubview:self.headerPanel];
    [self addHeaderPatternToView:self.headerPanel];

    self.headerDivider = [[NSView alloc] initWithFrame:NSMakeRect(0, 317, 360, 1)];
    self.headerDivider.wantsLayer = YES;
    [content addSubview:self.headerDivider];

    NSImageView *appIcon = [[NSImageView alloc] initWithFrame:NSMakeRect(22, 344, 44, 44)];
    appIcon.image = NSApp.applicationIconImage;
    appIcon.imageScaling = NSImageScaleProportionallyUpOrDown;
    appIcon.wantsLayer = YES;
    appIcon.layer.cornerRadius = 10.0;
    appIcon.layer.masksToBounds = YES;
    [content addSubview:appIcon];

    NSTextField *title = [self labelWithString:PacerText(@"app.title") frame:NSMakeRect(80, 364, 188, 25) fontSize:20 bold:YES];
    [content addSubview:title];

    NSTextField *subtitle = [self labelWithString:PacerText(@"app.subtitle") frame:NSMakeRect(80, 343, 188, 18) fontSize:12 bold:NO];
    subtitle.textColor = NSColor.secondaryLabelColor;
    [content addSubview:subtitle];

    self.statusLabel = [self labelWithString:PacerText(@"status.stopped") frame:NSMakeRect(272, 356, 66, 30) fontSize:13 bold:YES];
    self.statusLabel.alignment = NSTextAlignmentCenter;
    self.statusLabel.lineBreakMode = NSLineBreakByClipping;
    self.statusLabel.wantsLayer = YES;
    self.statusLabel.layer.cornerRadius = 14.0;
    self.statusLabel.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.92 alpha:1.0].CGColor;
    [content addSubview:self.statusLabel];

    [self addMetricCardWithTitle:PacerText(@"metric.cpu")
                           frame:NSMakeRect(22, 226, 151, 76)
                            icon:@"cpu"
                      valueLabel:&_cpuValueLabel
                     statusLabel:&_cpuStatusLabel];
    [self addMetricCardWithTitle:PacerText(@"metric.memory")
                           frame:NSMakeRect(187, 226, 151, 76)
                            icon:@"memory"
                      valueLabel:&_memoryValueLabel
                     statusLabel:&_memoryStatusLabel];
    [self addMetricCardWithTitle:PacerText(@"metric.metal")
                           frame:NSMakeRect(22, 134, 151, 76)
                            icon:@"fps"
                      valueLabel:&_metalValueLabel
                     statusLabel:&_metalStatusLabel];
    [self addMetricCardWithTitle:PacerText(@"metric.miss")
                           frame:NSMakeRect(187, 134, 151, 76)
                            icon:@"miss"
                      valueLabel:&_missValueLabel
                     statusLabel:&_missStatusLabel];

    NSView *launchPanel = [self panelWithFrame:NSMakeRect(22, 68, 316, 50)];
    [content addSubview:launchPanel];

    self.launchAtLoginCheck = [[NSButton alloc] initWithFrame:NSMakeRect(12, 12, 150, 26)];
    self.launchAtLoginCheck.buttonType = NSButtonTypeSwitch;
    self.launchAtLoginCheck.title = PacerText(@"login.title");
    self.launchAtLoginCheck.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    self.launchAtLoginCheck.state = [self launchAtLoginEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    self.launchAtLoginCheck.target = self;
    self.launchAtLoginCheck.action = @selector(launchAtLoginAction:);
    [launchPanel addSubview:self.launchAtLoginCheck];

    self.launchDetailLabel = [self labelWithString:PacerText(@"login.detail") frame:NSMakeRect(174, 15, 126, 20) fontSize:11 bold:NO];
    self.launchDetailLabel.textColor = NSColor.secondaryLabelColor;
    self.launchDetailLabel.alignment = NSTextAlignmentRight;
    [launchPanel addSubview:self.launchDetailLabel];

    self.recommendationTitleLabel = [self labelWithString:PacerText(@"ready.title") frame:NSMakeRect(24, -80, 160, 22) fontSize:12 bold:YES];
    self.recommendationTitleLabel.hidden = YES;
    self.recommendationDetailLabel = [self labelWithString:PacerText(@"ready.detail") frame:NSMakeRect(176, -80, 180, 22) fontSize:11 bold:NO];
    self.recommendationDetailLabel.hidden = YES;

    self.startButton = [[NSButton alloc] initWithFrame:NSMakeRect(22, 8, 151, 44)];
    self.startButton.bezelStyle = NSBezelStyleRegularSquare;
    self.startButton.bordered = NO;
    self.startButton.wantsLayer = YES;
    self.startButton.layer.cornerRadius = 11.0;
    self.startButton.layer.backgroundColor = [self primaryActionColor].CGColor;
    [self setPrimaryButtonTitle:PacerText(@"button.start")];
    self.startButton.keyEquivalent = @"\r";
    self.startButton.target = self;
    self.startButton.action = @selector(startPacer:);
    [content addSubview:self.startButton];

    self.closeButton = [[NSButton alloc] initWithFrame:NSMakeRect(187, 8, 151, 44)];
    self.closeButton.bezelStyle = NSBezelStyleRegularSquare;
    self.closeButton.bordered = NO;
    self.closeButton.wantsLayer = YES;
    self.closeButton.layer.cornerRadius = 11.0;
    self.closeButton.layer.borderWidth = 1.0;
    self.closeButton.layer.borderColor = [[self stopActionColor] colorWithAlphaComponent:0.22].CGColor;
    self.closeButton.layer.backgroundColor = [self stopButtonBackgroundColor].CGColor;
    [self setButton:self.closeButton title:PacerText(@"button.close") color:[self stopActionColor] fontSize:13];
    self.closeButton.target = self;
    self.closeButton.action = @selector(closePacer:);
    [content addSubview:self.closeButton];

    NSTextField *activityLabel = [self labelWithString:@"" frame:NSMakeRect(24, 6, 100, 18) fontSize:12 bold:YES];
    activityLabel.textColor = NSColor.secondaryLabelColor;
    activityLabel.hidden = YES;
    self.detailLabel = activityLabel;

    self.metricsLabel = [self labelWithString:@"" frame:NSZeroRect fontSize:12 bold:NO];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(22, -118, 316, 0)];
    scroll.hidden = YES;
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    self.logView = [[NSTextView alloc] initWithFrame:scroll.contentView.bounds];
    self.logView.editable = NO;
    if (@available(macOS 10.15, *)) {
        self.logView.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    } else {
        self.logView.font = [NSFont fontWithName:@"Menlo" size:12] ?: [NSFont systemFontOfSize:12];
    }
    scroll.documentView = self.logView;
    [content addSubview:scroll];

    [self applyCurrentAppearance];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (NSTextField *)labelWithString:(NSString *)string frame:(NSRect)frame fontSize:(CGFloat)fontSize bold:(BOOL)bold {
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    CenteredTextFieldCell *cell = [[CenteredTextFieldCell alloc] initTextCell:string ?: @""];
    label.cell = cell;
    label.stringValue = string;
    label.editable = NO;
    label.selectable = NO;
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.font = bold ? [NSFont boldSystemFontOfSize:fontSize] : [NSFont systemFontOfSize:fontSize];
    return label;
}

- (NSView *)panelWithFrame:(NSRect)frame {
    NSView *panel = [[NSView alloc] initWithFrame:frame];
    panel.wantsLayer = YES;
    panel.layer.cornerRadius = 12.0;
    panel.layer.borderWidth = 1.0;
    [self.panelViews addObject:panel];
    return panel;
}

- (BOOL)darkAppearance {
    NSAppearance *appearance = self.window.effectiveAppearance ?: NSApp.effectiveAppearance;
    NSAppearanceName best = [appearance bestMatchFromAppearancesWithNames:@[
        NSAppearanceNameAqua,
        NSAppearanceNameDarkAqua
    ]];
    return [best isEqualToString:NSAppearanceNameDarkAqua];
}

- (NSColor *)resolvedColor:(NSColor *)color {
    if (!color) {
        return NSColor.clearColor;
    }
    NSAppearance *appearance = self.window.effectiveAppearance ?: NSApp.effectiveAppearance;
    if (!appearance) {
        return color;
    }
    __block NSColor *resolved = color;
    [appearance performAsCurrentDrawingAppearance:^{
        resolved = [color colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace] ?: color;
    }];
    return resolved;
}

- (NSColor *)panelBackgroundColor {
    return [self darkAppearance]
        ? [NSColor colorWithCalibratedRed:0.105 green:0.120 blue:0.145 alpha:1.0]
        : [NSColor colorWithCalibratedRed:0.972 green:0.980 blue:0.990 alpha:1.0];
}

- (NSColor *)cardBackgroundColor {
    return [self darkAppearance]
        ? [NSColor colorWithCalibratedRed:0.125 green:0.140 blue:0.165 alpha:1.0]
        : [NSColor colorWithCalibratedRed:0.985 green:0.990 blue:0.995 alpha:1.0];
}

- (NSColor *)borderColor {
    return [self darkAppearance]
        ? [NSColor colorWithCalibratedRed:0.245 green:0.270 blue:0.310 alpha:1.0]
        : [NSColor colorWithCalibratedRed:0.86 green:0.885 blue:0.915 alpha:1.0];
}

- (NSColor *)headerBackgroundColor {
    return [self darkAppearance]
        ? [NSColor colorWithCalibratedRed:0.085 green:0.095 blue:0.115 alpha:1.0]
        : [NSColor colorWithCalibratedRed:0.985 green:0.990 blue:0.995 alpha:1.0];
}

- (NSColor *)headerDividerColor {
    return [self darkAppearance]
        ? [NSColor colorWithCalibratedRed:0.190 green:0.205 blue:0.235 alpha:1.0]
        : [NSColor colorWithCalibratedWhite:0.90 alpha:1.0];
}

- (NSColor *)primaryActionColor {
    return [self darkAppearance]
        ? [NSColor colorWithCalibratedRed:0.24 green:0.56 blue:0.43 alpha:1.0]
        : [NSColor colorWithCalibratedRed:0.18 green:0.49 blue:0.36 alpha:1.0];
}

- (NSColor *)disabledButtonBackgroundColor {
    return [self darkAppearance]
        ? [NSColor colorWithCalibratedRed:0.145 green:0.155 blue:0.175 alpha:1.0]
        : [NSColor colorWithCalibratedRed:0.925 green:0.935 blue:0.950 alpha:1.0];
}

- (NSColor *)stopButtonBackgroundColor {
    return [self darkAppearance]
        ? [NSColor colorWithCalibratedRed:0.155 green:0.130 blue:0.125 alpha:1.0]
        : [NSColor colorWithCalibratedRed:0.985 green:0.970 blue:0.960 alpha:1.0];
}

- (NSColor *)stopActionColor {
    return [self darkAppearance]
        ? [NSColor colorWithCalibratedRed:0.86 green:0.48 blue:0.42 alpha:1.0]
        : [NSColor colorWithCalibratedRed:0.58 green:0.22 blue:0.18 alpha:1.0];
}

- (NSColor *)runningPillBackgroundColor {
    return [self darkAppearance]
        ? [NSColor colorWithCalibratedRed:0.080 green:0.220 blue:0.140 alpha:1.0]
        : [NSColor colorWithCalibratedRed:0.90 green:0.97 blue:0.93 alpha:1.0];
}

- (NSColor *)stoppedPillBackgroundColor {
    return [self darkAppearance]
        ? [NSColor colorWithCalibratedRed:0.165 green:0.175 blue:0.195 alpha:1.0]
        : [NSColor colorWithCalibratedWhite:0.92 alpha:1.0];
}

- (void)applyCurrentAppearance {
    if (!self.window.contentView) {
        return;
    }
    self.window.contentView.layer.backgroundColor = [self resolvedColor:NSColor.windowBackgroundColor].CGColor;
    self.headerPanel.layer.backgroundColor = [self headerBackgroundColor].CGColor;
    self.headerDivider.layer.backgroundColor = [self headerDividerColor].CGColor;
    for (NSView *panel in self.panelViews) {
        panel.layer.backgroundColor = [self panelBackgroundColor].CGColor;
        panel.layer.borderColor = [self borderColor].CGColor;
    }
    for (NSView *card in self.metricCardViews) {
        card.layer.backgroundColor = [self cardBackgroundColor].CGColor;
        card.layer.borderColor = [self borderColor].CGColor;
    }
    [self updateButtonAppearance];
    [self updateStatusPillAppearance];
}

- (void)addHeaderPatternToView:(NSView *)view {
    NSArray<NSValue *> *waves = @[
        [NSValue valueWithRect:NSMakeRect(248, 70, 86, 24)],
        [NSValue valueWithRect:NSMakeRect(238, 42, 86, 24)]
    ];
    NSArray<NSColor *> *colors = @[
        [NSColor colorWithCalibratedRed:0.56 green:0.72 blue:0.93 alpha:1.0],
        [NSColor colorWithCalibratedRed:0.55 green:0.78 blue:0.68 alpha:1.0]
    ];
    for (NSUInteger i = 0; i < waves.count; i++) {
        NSBezierPath *path = [NSBezierPath bezierPath];
        NSRect rect = waves[i].rectValue;
        [path moveToPoint:NSMakePoint(NSMinX(rect), NSMidY(rect))];
        [path curveToPoint:NSMakePoint(NSMidX(rect), NSMidY(rect))
             controlPoint1:NSMakePoint(NSMinX(rect) + 24, NSMaxY(rect))
             controlPoint2:NSMakePoint(NSMidX(rect) - 24, NSMinY(rect))];
        [path curveToPoint:NSMakePoint(NSMaxX(rect), NSMidY(rect))
             controlPoint1:NSMakePoint(NSMidX(rect) + 24, NSMaxY(rect))
             controlPoint2:NSMakePoint(NSMaxX(rect) - 24, NSMinY(rect))];
        CAShapeLayer *layer = [CAShapeLayer layer];
        layer.path = path.CGPath;
        layer.strokeColor = colors[i].CGColor;
        layer.opacity = [self darkAppearance] ? 0.28 : 0.38;
        layer.fillColor = NSColor.clearColor.CGColor;
        layer.lineWidth = 8.0;
        layer.lineCap = kCALineCapRound;
        [view.layer addSublayer:layer];
    }

    CAShapeLayer *ring = [CAShapeLayer layer];
    NSBezierPath *ringPath = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(294, 44, 54, 54)];
    ring.path = ringPath.CGPath;
    ring.strokeColor = ([self darkAppearance]
        ? [NSColor colorWithCalibratedRed:0.22 green:0.28 blue:0.36 alpha:1.0]
        : [NSColor colorWithCalibratedRed:0.93 green:0.95 blue:0.98 alpha:1.0]).CGColor;
    ring.fillColor = NSColor.clearColor.CGColor;
    ring.lineWidth = 8.0;
    [view.layer addSublayer:ring];
}

- (void)addMetricIcon:(NSString *)icon toCard:(NSView *)card frame:(NSRect)frame {
    CAShapeLayer *layer = [CAShapeLayer layer];
    NSBezierPath *path = [NSBezierPath bezierPath];
    if ([icon isEqualToString:@"cpu"]) {
        [path moveToPoint:NSMakePoint(NSMinX(frame), NSMidY(frame))];
        [path curveToPoint:NSMakePoint(NSMaxX(frame), NSMidY(frame))
             controlPoint1:NSMakePoint(NSMinX(frame) + 8, NSMaxY(frame))
             controlPoint2:NSMakePoint(NSMaxX(frame) - 8, NSMinY(frame))];
        layer.strokeColor = [NSColor colorWithCalibratedRed:0.56 green:0.72 blue:0.93 alpha:1.0].CGColor;
    } else if ([icon isEqualToString:@"memory"]) {
        [path moveToPoint:NSMakePoint(NSMinX(frame), NSMidY(frame))];
        [path lineToPoint:NSMakePoint(NSMinX(frame) + 8, NSMaxY(frame))];
        [path lineToPoint:NSMakePoint(NSMinX(frame) + 17, NSMinY(frame))];
        [path lineToPoint:NSMakePoint(NSMaxX(frame), NSMaxY(frame) - 2)];
        layer.strokeColor = [NSColor colorWithCalibratedRed:0.55 green:0.78 blue:0.68 alpha:1.0].CGColor;
    } else if ([icon isEqualToString:@"fps"]) {
        [path moveToPoint:NSMakePoint(NSMinX(frame), NSMaxY(frame) - 3)];
        [path lineToPoint:NSMakePoint(NSMaxX(frame), NSMaxY(frame) - 3)];
        [path moveToPoint:NSMakePoint(NSMinX(frame), NSMinY(frame) + 4)];
        [path lineToPoint:NSMakePoint(NSMinX(frame) + 17, NSMinY(frame) + 4)];
        layer.strokeColor = [NSColor colorWithCalibratedRed:0.60 green:0.65 blue:1.0 alpha:1.0].CGColor;
    } else {
        [path appendBezierPathWithOvalInRect:frame];
        [path moveToPoint:NSMakePoint(NSMinX(frame) + 6, NSMidY(frame))];
        [path lineToPoint:NSMakePoint(NSMaxX(frame) - 6, NSMidY(frame))];
        layer.strokeColor = [NSColor colorWithCalibratedRed:0.76 green:0.80 blue:0.86 alpha:1.0].CGColor;
    }
    layer.path = path.CGPath;
    layer.fillColor = NSColor.clearColor.CGColor;
    layer.lineWidth = 3.0;
    layer.lineCap = kCALineCapRound;
    layer.lineJoin = kCALineJoinRound;
    [card.layer addSublayer:layer];
}

- (void)addMetricCardWithTitle:(NSString *)title frame:(NSRect)frame icon:(NSString *)icon valueLabel:(NSTextField * __strong *)valueLabel statusLabel:(NSTextField * __strong *)statusLabel {
    NSView *card = [self panelWithFrame:frame];
    [self.metricCardViews addObject:card];
    [self.window.contentView addSubview:card];

    NSTextField *titleLabel = [self labelWithString:title frame:NSMakeRect(12, frame.size.height - 20, frame.size.width - 24, 14) fontSize:10 bold:YES];
    titleLabel.textColor = NSColor.secondaryLabelColor;
    [card addSubview:titleLabel];

    [self addMetricIcon:icon toCard:card frame:NSMakeRect(frame.size.width - 48, frame.size.height - 30, 32, 22)];

    NSTextField *value = [self labelWithString:@"--" frame:NSMakeRect(12, 27, frame.size.width - 24, 24) fontSize:20 bold:YES];
    [card addSubview:value];

    NSTextField *status = [self labelWithString:PacerText(@"metric.idle") frame:NSMakeRect(12, 8, frame.size.width - 24, 14) fontSize:10 bold:YES];
    status.textColor = NSColor.secondaryLabelColor;
    [card addSubview:status];

    if (valueLabel) {
        *valueLabel = value;
    }
    if (statusLabel) {
        *statusLabel = status;
    }
}

- (void)setPrimaryButtonTitle:(NSString *)title {
    NSDictionary *attributes = @{
        NSForegroundColorAttributeName: NSColor.whiteColor,
        NSFontAttributeName: [NSFont boldSystemFontOfSize:15.0]
    };
    self.startButton.attributedTitle = [[NSAttributedString alloc] initWithString:title ?: @""
                                                                           attributes:attributes];
}

- (void)setButton:(NSButton *)button title:(NSString *)title color:(NSColor *)color fontSize:(CGFloat)fontSize {
    NSDictionary *attributes = @{
        NSForegroundColorAttributeName: color ?: NSColor.labelColor,
        NSFontAttributeName: [NSFont boldSystemFontOfSize:fontSize]
    };
    button.attributedTitle = [[NSAttributedString alloc] initWithString:title ?: @""
                                                              attributes:attributes];
}

- (NSURL *)launchAgentURL {
    NSURL *agentsDirectory = [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents"] isDirectory:YES];
    return [agentsDirectory URLByAppendingPathComponent:[PacerLaunchAgentLabel stringByAppendingString:@".plist"]];
}

- (NSURL *)legacyLaunchAgentURL {
    NSURL *agentsDirectory = [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents"] isDirectory:YES];
    return [agentsDirectory URLByAppendingPathComponent:[PacerLegacyLaunchAgentLabel stringByAppendingString:@".plist"]];
}

- (BOOL)launchAtLoginEnabled {
    return [[NSFileManager defaultManager] fileExistsAtPath:self.launchAgentURL.path];
}

- (void)launchAtLoginAction:(NSButton *)sender {
    BOOL enable = sender.state == NSControlStateValueOn;
    sender.enabled = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL ok = enable ? [self installLaunchAgent:&error] : [self uninstallLaunchAgent:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            sender.enabled = YES;
            sender.state = [self launchAtLoginEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
            if (!ok) {
                [self appendLog:[NSString stringWithFormat:PacerText(@"log.login.failed"), error.localizedDescription ?: @"unknown error"]];
            } else {
                [self appendLog:[NSString stringWithFormat:PacerText(@"log.login"), enable ? PacerText(@"log.enabled") : PacerText(@"log.disabled")]];
            }
        });
    });
}

- (BOOL)installLaunchAgent:(NSError **)error {
    [self removeLegacyLaunchAgent];
    NSURL *agentURL = [self launchAgentURL];
    NSURL *agentDirectory = [agentURL URLByDeletingLastPathComponent];
    if (![[NSFileManager defaultManager] createDirectoryAtURL:agentDirectory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:error]) {
        return NO;
    }

    NSString *executablePath = NSBundle.mainBundle.executablePath ?: NSProcessInfo.processInfo.arguments.firstObject;
    NSDictionary *plist = @{
        @"Label": PacerLaunchAgentLabel,
        @"ProgramArguments": @[ executablePath ?: @"", @"--agent" ],
        @"RunAtLoad": @YES,
        @"KeepAlive": @NO
    };
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:error];
    if (!data || ![data writeToURL:agentURL options:NSDataWritingAtomic error:error]) {
        return NO;
    }

    [self runLaunchctlWithArguments:@[ @"bootout", [self guiDomain], agentURL.path ] error:nil];
    if (![self runLaunchctlWithArguments:@[ @"bootstrap", [self guiDomain], agentURL.path ] error:error]) {
        [[NSFileManager defaultManager] removeItemAtURL:agentURL error:nil];
        return NO;
    }
    return YES;
}

- (BOOL)uninstallLaunchAgent:(NSError **)error {
    NSURL *agentURL = [self launchAgentURL];
    [self runLaunchctlWithArguments:@[ @"bootout", [self guiDomain], agentURL.path ] error:nil];
    [self removeLegacyLaunchAgent];
    if (![[NSFileManager defaultManager] fileExistsAtPath:agentURL.path]) {
        return YES;
    }
    return [[NSFileManager defaultManager] removeItemAtURL:agentURL error:error];
}

- (void)removeLegacyLaunchAgent {
    NSURL *legacyURL = [self legacyLaunchAgentURL];
    if ([[NSFileManager defaultManager] fileExistsAtPath:legacyURL.path]) {
        [self runLaunchctlWithArguments:@[ @"bootout", [self guiDomain], legacyURL.path ] error:nil];
        [[NSFileManager defaultManager] removeItemAtURL:legacyURL error:nil];
    }
}

- (NSString *)guiDomain {
    return [NSString stringWithFormat:@"gui/%u", getuid()];
}

- (BOOL)runLaunchctlWithArguments:(NSArray<NSString *> *)arguments error:(NSError **)error {
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/bin/launchctl";
    task.arguments = arguments;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"CompositorPacer"
                                         code:1
                                     userInfo:@{ NSLocalizedDescriptionKey: exception.reason ?: @"launchctl failed" }];
        }
        return NO;
    }
    if (task.terminationStatus == 0) {
        return YES;
    }
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSString *message = [output stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (error) {
        *error = [NSError errorWithDomain:@"CompositorPacer"
                                     code:task.terminationStatus
                                 userInfo:@{ NSLocalizedDescriptionKey: message.length ? message : @"launchctl failed" }];
    }
    return NO;
}

- (NSColor *)healthyColor {
    return [NSColor colorWithCalibratedRed:0.10 green:0.50 blue:0.30 alpha:1.0];
}

- (NSColor *)warningColor {
    return [NSColor colorWithCalibratedRed:0.72 green:0.46 blue:0.08 alpha:1.0];
}

- (NSColor *)dangerColor {
    return [NSColor colorWithCalibratedRed:0.72 green:0.12 blue:0.12 alpha:1.0];
}

- (void)setStatusLabel:(NSTextField *)label text:(NSString *)text color:(NSColor *)color {
    label.stringValue = text;
    label.textColor = color ?: NSColor.secondaryLabelColor;
}

- (void)updateStatusPillAppearance {
    if (!self.statusLabel) {
        return;
    }
    self.statusLabel.textColor = self.pacerRunning ? [self healthyColor] : NSColor.secondaryLabelColor;
    self.statusLabel.layer.backgroundColor = (self.pacerRunning ? [self runningPillBackgroundColor] : [self stoppedPillBackgroundColor]).CGColor;
}

- (void)updateButtonAppearance {
    if (!self.startButton || !self.closeButton) {
        return;
    }
    self.startButton.layer.backgroundColor = (self.startButton.enabled ? [self primaryActionColor] : [self disabledButtonBackgroundColor]).CGColor;
    [self setButton:self.startButton
              title:PacerText(@"button.start")
              color:self.startButton.enabled ? NSColor.whiteColor : NSColor.disabledControlTextColor
           fontSize:15.0];

    self.closeButton.layer.backgroundColor = (self.closeButton.enabled ? [self stopButtonBackgroundColor] : [self disabledButtonBackgroundColor]).CGColor;
    self.closeButton.layer.borderColor = [[self stopActionColor] colorWithAlphaComponent:(self.closeButton.enabled ? 0.26 : 0.12)].CGColor;
    [self setButton:self.closeButton
              title:PacerText(@"button.close")
              color:self.closeButton.enabled ? [self stopActionColor] : NSColor.disabledControlTextColor
           fontSize:13.0];
}

- (BOOL)nativePacerRunning {
    NSDictionary *status = [self agentStatus];
    if (!status) {
        return NO;
    }
    NSTimeInterval timestamp = [status[@"timestamp"] doubleValue];
    int pid = [status[@"pid"] intValue];
    BOOL recent = fabs([[NSDate date] timeIntervalSince1970] - timestamp) < 3.0;
    BOOL alive = pid > 0 && kill((pid_t)pid, 0) == 0;
    return recent && alive;
}

- (void)applyPacerWindowAppearance {
    NSDictionary *status = [self agentStatus];
    if (!status) {
        return;
    }
    int pid = [status[@"pid"] intValue];
    if (pid <= 0 || kill((pid_t)pid, 0) != 0) {
        return;
    }
    NSMutableDictionary *updatedStatus = [status mutableCopy];
    updatedStatus[@"alpha"] = @0.0;
    [updatedStatus writeToURL:PacerStatusURL() atomically:YES];
}

- (NSDictionary *)agentStatus {
    NSDictionary *status = [NSDictionary dictionaryWithContentsOfURL:PacerStatusURL()];
    return [status isKindOfClass:NSDictionary.class] ? status : nil;
}

- (BOOL)startAgent:(NSError **)error {
    if ([self nativePacerRunning]) {
        return YES;
    }
    [[NSFileManager defaultManager] removeItemAtURL:PacerStatusURL() error:nil];
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = NSBundle.mainBundle.executablePath ?: NSProcessInfo.processInfo.arguments.firstObject;
    task.arguments = @[ @"--agent" ];
    @try {
        [task launch];
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"CompositorPacer"
                                         code:1
                                     userInfo:@{ NSLocalizedDescriptionKey: exception.reason ?: PacerText(@"error.start.agent") }];
        }
        return NO;
    }
    return YES;
}

- (void)stopAgentIfRunning {
    NSDictionary *status = [self agentStatus];
    int pid = [status[@"pid"] intValue];
    if (pid > 0) {
        kill((pid_t)pid, SIGTERM);
        for (NSUInteger i = 0; i < 20; i++) {
            if (kill((pid_t)pid, 0) != 0) {
                break;
            }
            [NSThread sleepForTimeInterval:0.05];
        }
        if (kill((pid_t)pid, 0) == 0) {
            kill((pid_t)pid, SIGKILL);
        }
    }
    [[NSFileManager defaultManager] removeItemAtURL:PacerStatusURL() error:nil];
}

- (void)refreshStatus {
    self.pacerRunning = [self nativePacerRunning];
    self.statusLabel.stringValue = self.pacerRunning ? PacerText(@"status.running") : PacerText(@"status.stopped");
    [self updateStatusPillAppearance];
    self.startButton.enabled = !self.pacerRunning;
    self.closeButton.enabled = self.pacerRunning;
    [self updateButtonAppearance];
    [self applyPacerWindowAppearance];
    if (!self.pacerRunning) {
        self.metricsLabel.stringValue = [NSString stringWithFormat:@"%@: --   %@: --   Metal: -- fps   Miss: --/s", PacerText(@"metric.cpu"), PacerText(@"metric.memory")];
        self.cpuValueLabel.stringValue = @"--";
        self.memoryValueLabel.stringValue = @"--";
        self.metalValueLabel.stringValue = @"--";
        self.missValueLabel.stringValue = @"--";
        [self setStatusLabel:self.cpuStatusLabel text:PacerText(@"metric.idle") color:NSColor.secondaryLabelColor];
        [self setStatusLabel:self.memoryStatusLabel text:PacerText(@"metric.idle") color:NSColor.secondaryLabelColor];
        [self setStatusLabel:self.metalStatusLabel text:PacerText(@"metric.idle") color:NSColor.secondaryLabelColor];
        [self setStatusLabel:self.missStatusLabel text:PacerText(@"metric.idle") color:NSColor.secondaryLabelColor];
        self.recommendationTitleLabel.stringValue = PacerText(@"ready.title");
        self.recommendationDetailLabel.stringValue = PacerText(@"ready.detail");
    }
}

- (void)appendLog:(NSString *)text {
    NSString *line = [NSString stringWithFormat:@"%@\n", text ?: @""];
    self.logView.string = [self.logView.string stringByAppendingString:line];
    [self.logView scrollRangeToVisible:NSMakeRange(self.logView.string.length, 0)];
}

- (void)startPacer:(id)sender {
    (void)sender;
    if ([self nativePacerRunning]) {
        [self refreshStatus];
        return;
    }
    self.startButton.enabled = NO;
    self.closeButton.enabled = NO;
    [self updateButtonAppearance];
    [self appendLog:PacerText(@"log.starting")];
    NSError *error = nil;
    if (![self startAgent:&error]) {
        [self appendLog:[NSString stringWithFormat:PacerText(@"log.start.failed"), error.localizedDescription ?: @"unknown error"]];
    } else {
        [self appendLog:PacerText(@"log.start.requested")];
    }
    [NSThread sleepForTimeInterval:0.25];
    [self refreshStatus];
}

- (void)closePacer:(id)sender {
    (void)sender;
    self.startButton.enabled = NO;
    self.closeButton.enabled = NO;
    [self updateButtonAppearance];
    [self appendLog:PacerText(@"log.stopping")];
    [self stopAgentIfRunning];
    [self appendLog:PacerText(@"log.stopped")];
    [self refreshStatus];
}

- (void)startMetricsSampler {
    [self stopMetricsSampler];
    self.metricsTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                         target:self
                                                       selector:@selector(metricsTick:)
                                                       userInfo:nil
                                                        repeats:YES];
    self.metricsTimer.tolerance = 0.1;
    [[NSRunLoop mainRunLoop] addTimer:self.metricsTimer forMode:NSRunLoopCommonModes];
    [self metricsTick:nil];
}

- (void)stopMetricsSampler {
    [self.metricsTimer invalidate];
    self.metricsTimer = nil;
}

- (void)metricsTick:(NSTimer *)timer {
    (void)timer;
    NSDictionary *status = [self agentStatus];
    BOOL running = [self nativePacerRunning];
    self.pacerRunning = running;
    self.statusLabel.stringValue = running ? PacerText(@"status.running") : PacerText(@"status.stopped");
    [self updateStatusPillAppearance];
    self.startButton.enabled = !running;
    self.closeButton.enabled = running;
    [self updateButtonAppearance];
    if (!running || !status) {
        self.cpuValueLabel.stringValue = @"--";
        self.memoryValueLabel.stringValue = @"--";
        self.metalValueLabel.stringValue = @"--";
        self.missValueLabel.stringValue = @"--";
        [self setStatusLabel:self.cpuStatusLabel text:PacerText(@"metric.idle") color:NSColor.secondaryLabelColor];
        [self setStatusLabel:self.memoryStatusLabel text:PacerText(@"metric.idle") color:NSColor.secondaryLabelColor];
        [self setStatusLabel:self.metalStatusLabel text:PacerText(@"metric.idle") color:NSColor.secondaryLabelColor];
        [self setStatusLabel:self.missStatusLabel text:PacerText(@"metric.idle") color:NSColor.secondaryLabelColor];
        self.recommendationTitleLabel.stringValue = PacerText(@"ready.title");
        self.recommendationDetailLabel.stringValue = PacerText(@"stopped.detail");
        return;
    }

    double cpuPercent = [status[@"cpuPercent"] doubleValue];
    double metalFPS = [status[@"metalFPS"] doubleValue];
    double missesPerSecond = [status[@"missesPerSecond"] doubleValue];
    double memoryMB = [status[@"memoryMB"] doubleValue];
    self.memoryTrendMBPerMinute = [status[@"memoryTrendMBPerMinute"] doubleValue];

    self.metricsLabel.stringValue = [NSString stringWithFormat:@"%@: %.1f%%   %@: %.1f MB   Metal: %.0f fps   Miss: %.1f/s",
                                     PacerText(@"metric.cpu"),
                                     cpuPercent,
                                     PacerText(@"metric.memory"),
                                     memoryMB,
                                     metalFPS,
                                     missesPerSecond];

    self.cpuValueLabel.stringValue = [NSString stringWithFormat:@"%.1f%%", cpuPercent];
    self.memoryValueLabel.stringValue = [NSString stringWithFormat:@"%.0f MB", memoryMB];
    self.metalValueLabel.stringValue = [NSString stringWithFormat:@"%.0f fps", metalFPS];
    self.missValueLabel.stringValue = [NSString stringWithFormat:@"%.1f/s", missesPerSecond];

    NSColor *cpuColor = cpuPercent < 3.0 ? [self healthyColor] : (cpuPercent < 8.0 ? [self warningColor] : [self dangerColor]);
    [self setStatusLabel:self.cpuStatusLabel text:(cpuPercent < 3.0 ? PacerText(@"cpu.low") : (cpuPercent < 8.0 ? PacerText(@"cpu.moderate") : PacerText(@"cpu.high"))) color:cpuColor];

    NSColor *memoryColor = fabs(self.memoryTrendMBPerMinute) < 1.0 ? [self healthyColor] : (self.memoryTrendMBPerMinute < 5.0 ? [self warningColor] : [self dangerColor]);
    NSString *memoryText = fabs(self.memoryTrendMBPerMinute) < 1.0 ? PacerText(@"memory.stable") : [NSString stringWithFormat:@"%+.1f MB/min", self.memoryTrendMBPerMinute];
    [self setStatusLabel:self.memoryStatusLabel text:memoryText color:memoryColor];

    NSColor *metalColor = metalFPS >= 50.0 ? [self healthyColor] : (metalFPS >= 30.0 ? [self warningColor] : [self dangerColor]);
    [self setStatusLabel:self.metalStatusLabel text:(metalFPS >= 50.0 ? PacerText(@"metal.refresh") : (metalFPS >= 30.0 ? PacerText(@"metal.below") : PacerText(@"metal.low"))) color:metalColor];

    NSColor *missColor = missesPerSecond < 0.1 ? [self healthyColor] : (missesPerSecond < 1.0 ? [self warningColor] : [self dangerColor]);
    [self setStatusLabel:self.missStatusLabel text:(missesPerSecond < 0.1 ? PacerText(@"miss.clean") : (missesPerSecond < 1.0 ? PacerText(@"miss.occasional") : PacerText(@"miss.pressure"))) color:missColor];

    if (cpuPercent >= 8.0) {
        self.recommendationTitleLabel.stringValue = PacerText(@"warn.cpu.title");
        self.recommendationDetailLabel.stringValue = PacerText(@"warn.cpu.detail");
    } else if (missesPerSecond >= 1.0) {
        self.recommendationTitleLabel.stringValue = PacerText(@"warn.miss.title");
        self.recommendationDetailLabel.stringValue = PacerText(@"warn.miss.detail");
    } else if (self.memoryTrendMBPerMinute >= 5.0) {
        self.recommendationTitleLabel.stringValue = PacerText(@"warn.memory.title");
        self.recommendationDetailLabel.stringValue = PacerText(@"warn.memory.detail");
    } else {
        self.recommendationTitleLabel.stringValue = PacerText(@"healthy.title");
        self.recommendationDetailLabel.stringValue = PacerText(@"healthy.detail");
    }
}

@end

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        BOOL agentMode = [NSProcessInfo.processInfo.arguments containsObject:@"--agent"];
        NSApplication *app = NSApplication.sharedApplication;
        if (agentMode) {
            [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
            AgentDelegate *delegate = [[AgentDelegate alloc] init];
            app.delegate = delegate;
        } else {
            AppDelegate *delegate = [[AppDelegate alloc] init];
            app.delegate = delegate;
        }
        [app run];
    }
    return 0;
}
