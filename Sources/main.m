#import <Cocoa/Cocoa.h>

static NSString *const DSHServiceLabel = @"com.dsh.web";
static const NSInteger DSHServicePort = 3080;

typedef NS_ENUM(NSInteger, DSHServiceState) {
    DSHServiceStateRunning,
    DSHServiceStateLoaded,
    DSHServiceStateStopped,
    DSHServiceStateUnavailable,
};

@interface DSHCommandResult : NSObject
@property(nonatomic) int status;
@property(nonatomic, copy) NSString *output;
@property(nonatomic, copy) NSString *error;
@end

@implementation DSHCommandResult
@end

@interface DSHServiceController : NSObject
- (void)readState:(void (^)(DSHServiceState state, NSString *label))completion;
- (void)start:(void (^)(NSError *error))completion;
- (void)restart:(void (^)(NSError *error))completion;
- (void)stop:(void (^)(NSError *error))completion;
@end

@implementation DSHServiceController

- (NSString *)servicePlist {
    return [@"~/Library/LaunchAgents/com.dsh.web.plist" stringByExpandingTildeInPath];
}

- (NSString *)serviceTarget {
    return [NSString stringWithFormat:@"gui/%u/%@", getuid(), DSHServiceLabel];
}

- (void)readState:(void (^)(DSHServiceState, NSString *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL plistExists = [[NSFileManager defaultManager] fileExistsAtPath:self.servicePlist];
        BOOL loaded = [self run:@"/bin/launchctl" arguments:@[@"print", self.serviceTarget]].status == 0;
        if (!plistExists && !loaded) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(DSHServiceStateUnavailable, @"未安装 LaunchAgent"); });
            return;
        }

        BOOL healthy = loaded && [self healthCheck];
        DSHServiceState state;
        NSString *label;
        if (healthy) {
            state = DSHServiceStateRunning;
            label = @"运行中";
        } else if (loaded) {
            state = DSHServiceStateLoaded;
            label = @"已加载，服务未就绪";
        } else {
            state = DSHServiceStateStopped;
            label = @"已停止";
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(state, label); });
    });
}

- (void)start:(void (^)(NSError *))completion {
    [self runLaunchctl:@[@"bootstrap", [NSString stringWithFormat:@"gui/%u", getuid()], self.servicePlist] completion:completion];
}

- (void)restart:(void (^)(NSError *))completion {
    [self runLaunchctl:@[@"kickstart", @"-k", self.serviceTarget] completion:completion];
}

- (void)stop:(void (^)(NSError *))completion {
    [self runLaunchctl:@[@"bootout", self.serviceTarget] completion:completion];
}

- (void)runLaunchctl:(NSArray<NSString *> *)arguments completion:(void (^)(NSError *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        DSHCommandResult *result = [self run:@"/bin/launchctl" arguments:arguments];
        NSError *error = nil;
        if (result.status != 0) {
            NSString *message = result.error.length > 0 ? result.error : result.output;
            error = [NSError errorWithDomain:@"DeepSeekHarnessMenuBar"
                                         code:result.status
                                     userInfo:@{NSLocalizedDescriptionKey: message.length > 0 ? message : @"launchctl 操作失败"}];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}

- (BOOL)healthCheck {
    NSString *url = [NSString stringWithFormat:@"http://127.0.0.1:%ld/", (long)DSHServicePort];
    DSHCommandResult *result = [self run:@"/usr/bin/curl"
                               arguments:@[@"--noproxy", @"*", @"-fsS", @"-o", @"/dev/null", @"--max-time", @"2", url]];
    return result.status == 0;
}

- (DSHCommandResult *)run:(NSString *)executable arguments:(NSArray<NSString *> *)arguments {
    NSTask *task = [[NSTask alloc] init];
    NSPipe *stdoutPipe = [NSPipe pipe];
    NSPipe *stderrPipe = [NSPipe pipe];
    task.executableURL = [NSURL fileURLWithPath:executable];
    task.arguments = arguments;
    task.standardOutput = stdoutPipe;
    task.standardError = stderrPipe;

    DSHCommandResult *result = [[DSHCommandResult alloc] init];
    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        result.status = -1;
        result.output = @"";
        result.error = launchError.localizedDescription;
        return result;
    }

    [task waitUntilExit];
    NSData *stdoutData = [[stdoutPipe fileHandleForReading] readDataToEndOfFile];
    NSData *stderrData = [[stderrPipe fileHandleForReading] readDataToEndOfFile];
    result.status = task.terminationStatus;
    result.output = [[[NSString alloc] initWithData:stdoutData encoding:NSUTF8StringEncoding] ?: @""
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    result.error = [[[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding] ?: @""
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return result;
}

@end

@interface DSHAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSMenuItem *stateItem;
@property(nonatomic, strong) NSMenuItem *startItem;
@property(nonatomic, strong) NSMenuItem *restartItem;
@property(nonatomic, strong) NSMenuItem *stopItem;
@property(nonatomic, strong) DSHServiceController *service;
@property(nonatomic, strong) NSTimer *timer;
@end

@implementation DSHAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.service = [[DSHServiceController alloc] init];
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];

    NSString *menuIconPath = [[NSBundle mainBundle] pathForResource:@"MenuIcon" ofType:@"png"];
    NSImage *image = menuIconPath ? [[NSImage alloc] initWithContentsOfFile:menuIconPath] : nil;
    if (image) {
        image.size = NSMakeSize(19, 19);
        image.template = YES;
        self.statusItem.button.image = image;
    } else {
        self.statusItem.button.title = @"D";
    }

    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = self;
    menu.autoenablesItems = NO;
    self.stateItem = [[NSMenuItem alloc] initWithTitle:@"状态：检查中…" action:nil keyEquivalent:@""];
    self.stateItem.enabled = NO;
    [menu addItem:self.stateItem];
    [menu addItem:NSMenuItem.separatorItem];

    self.startItem = [self item:@"启动" selector:@selector(startService:)];
    self.restartItem = [self item:@"重启" selector:@selector(restartService:)];
    self.stopItem = [self item:@"停止" selector:@selector(stopService:)];
    [menu addItem:self.startItem];
    [menu addItem:self.restartItem];
    [menu addItem:self.stopItem];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self item:@"打开 DeepSeek Harness" selector:@selector(openWeb:)]];
    [menu addItem:[self item:@"打开日志目录" selector:@selector(openLogs:)]];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self item:@"退出菜单栏控制器" selector:@selector(quit:)]];
    self.statusItem.menu = menu;

    [self refresh];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:4 target:self selector:@selector(timerFired:) userInfo:nil repeats:YES];
}

- (NSMenuItem *)item:(NSString *)title selector:(SEL)selector {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:selector keyEquivalent:@""];
    item.target = self;
    return item;
}

- (void)menuWillOpen:(NSMenu *)menu {
    [self refresh];
}

- (void)timerFired:(NSTimer *)timer {
    [self refresh];
}

- (void)refresh {
    __weak typeof(self) weakSelf = self;
    [self.service readState:^(DSHServiceState state, NSString *label) {
        DSHAppDelegate *selfRef = weakSelf;
        if (!selfRef) return;
        selfRef.stateItem.title = [@"状态：" stringByAppendingString:label];
        BOOL plistExists = [[NSFileManager defaultManager] fileExistsAtPath:[@"~/Library/LaunchAgents/com.dsh.web.plist" stringByExpandingTildeInPath]];
        selfRef.startItem.enabled = plistExists && state != DSHServiceStateRunning && state != DSHServiceStateLoaded;
        selfRef.restartItem.enabled = state == DSHServiceStateRunning || state == DSHServiceStateLoaded;
        selfRef.stopItem.enabled = state == DSHServiceStateRunning || state == DSHServiceStateLoaded;
        selfRef.statusItem.button.toolTip = [@"DeepSeek Harness：" stringByAppendingString:label];
    }];
}

- (void)setBusy:(NSString *)action {
    self.stateItem.title = [NSString stringWithFormat:@"状态：正在%@…", action];
    self.startItem.enabled = NO;
    self.restartItem.enabled = NO;
    self.stopItem.enabled = NO;
}

- (void)finishOperation:(NSString *)action error:(NSError *)error {
    if (error) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleWarning;
        alert.messageText = [action stringByAppendingString:@"失败"];
        alert.informativeText = error.localizedDescription;
        [alert addButtonWithTitle:@"好"];
        [alert runModal];
    }
    [self refresh];
}

- (void)startService:(id)sender {
    [self setBusy:@"启动"];
    __weak typeof(self) weakSelf = self;
    [self.service start:^(NSError *error) { [weakSelf finishOperation:@"启动" error:error]; }];
}

- (void)restartService:(id)sender {
    [self setBusy:@"重启"];
    __weak typeof(self) weakSelf = self;
    [self.service restart:^(NSError *error) { [weakSelf finishOperation:@"重启" error:error]; }];
}

- (void)stopService:(id)sender {
    [self setBusy:@"停止"];
    __weak typeof(self) weakSelf = self;
    [self.service stop:^(NSError *error) { [weakSelf finishOperation:@"停止" error:error]; }];
}

- (void)openWeb:(id)sender {
    NSString *url = [NSString stringWithFormat:@"http://127.0.0.1:%ld", (long)DSHServicePort];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:url]];
}

- (void)openLogs:(id)sender {
    NSString *path = [@"~/Library/Logs/dsh" stringByExpandingTildeInPath];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:path isDirectory:YES]];
}

- (void)quit:(id)sender {
    [NSApp terminate:nil];
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        DSHAppDelegate *delegate = [[DSHAppDelegate alloc] init];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
