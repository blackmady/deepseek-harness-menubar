#import <Cocoa/Cocoa.h>
#import <CFNetwork/CFNetwork.h>

static NSString *const DSHServiceLabel = @"com.dsh.web";
static const NSInteger DSHServicePort = 3080;
static NSString *const DSHGitHubLatestReleaseURL = @"https://api.github.com/repos/blackmady/deepseek-harness-menubar/releases/latest";
static NSString *const DSHHarnessPackage = @"@deepseek-ai/dsh";
static NSString *const DSHHarnessRuntimeDirectory = @"~/.dsh/runtime";

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

static DSHCommandResult *DSHRunCommandWithEnvironment(NSString *executable, NSArray<NSString *> *arguments, NSDictionary<NSString *, NSString *> *extraEnvironment);

static DSHCommandResult *DSHRunCommand(NSString *executable, NSArray<NSString *> *arguments) {
    return DSHRunCommandWithEnvironment(executable, arguments, nil);
}

static DSHCommandResult *DSHRunCommandWithEnvironment(NSString *executable, NSArray<NSString *> *arguments, NSDictionary<NSString *, NSString *> *extraEnvironment) {
    NSTask *task = [[NSTask alloc] init];
    NSPipe *stdoutPipe = [NSPipe pipe];
    NSPipe *stderrPipe = [NSPipe pipe];
    task.executableURL = [NSURL fileURLWithPath:executable];
    task.arguments = arguments;
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    [environment addEntriesFromDictionary:extraEnvironment ?: @{}];
    task.environment = environment;
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
    return DSHRunCommand(executable, arguments);
}

@end

@interface DSHAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSMenuItem *stateItem;
@property(nonatomic, strong) NSMenuItem *startItem;
@property(nonatomic, strong) NSMenuItem *restartItem;
@property(nonatomic, strong) NSMenuItem *stopItem;
@property(nonatomic, strong) NSMenuItem *checkUpdateItem;
@property(nonatomic, strong) NSMenuItem *updateItem;
@property(nonatomic, strong) NSMenuItem *checkHarnessUpdateItem;
@property(nonatomic, strong) NSMenuItem *updateHarnessItem;
@property(nonatomic, strong) DSHServiceController *service;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) NSURLSession *updateSession;
@property(nonatomic, copy) NSString *currentVersion;
@property(nonatomic, copy) NSString *latestVersion;
@property(nonatomic, strong) NSURL *latestDownloadURL;
@property(nonatomic, copy) NSString *latestReleaseURL;
@property(nonatomic, copy) NSString *proxyDescription;
@property(nonatomic, copy) NSString *harnessCurrentVersion;
@property(nonatomic, copy) NSString *harnessLatestVersion;
@end

@implementation DSHAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.service = [[DSHServiceController alloc] init];
    self.currentVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"1.0.0";
    self.harnessCurrentVersion = [self installedHarnessVersion] ?: @"未安装";
    NSURLSessionConfiguration *sessionConfiguration = [NSURLSessionConfiguration defaultSessionConfiguration];
    sessionConfiguration.timeoutIntervalForRequest = 15;
    sessionConfiguration.timeoutIntervalForResource = 120;
    NSString *proxyDescription = nil;
    NSDictionary *proxyConfiguration = [self systemProxyConfigurationForURL:[NSURL URLWithString:DSHGitHubLatestReleaseURL] description:&proxyDescription];
    self.proxyDescription = proxyDescription;
    if (proxyConfiguration.count > 0) {
        sessionConfiguration.connectionProxyDictionary = proxyConfiguration;
    }
    self.updateSession = [NSURLSession sessionWithConfiguration:sessionConfiguration];
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
    self.checkUpdateItem = [self item:[NSString stringWithFormat:@"检查更新（当前 v%@）", self.currentVersion] selector:@selector(checkForUpdates:)];
    self.updateItem = [self item:@"更新（请先检查）" selector:@selector(updateApplication:)];
    self.updateItem.enabled = NO;
    [menu addItem:self.checkUpdateItem];
    [menu addItem:self.updateItem];
    self.checkHarnessUpdateItem = [self item:[NSString stringWithFormat:@"检查 Harness 更新（当前 %@）", self.harnessCurrentVersion] selector:@selector(checkHarnessForUpdates:)];
    self.updateHarnessItem = [self item:@"更新 DeepSeek Harness（请先检查）" selector:@selector(updateHarness:)];
    self.updateHarnessItem.enabled = NO;
    [menu addItem:self.checkHarnessUpdateItem];
    [menu addItem:self.updateHarnessItem];
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

- (NSString *)installedHarnessVersion {
    NSString *packagePath = [[DSHHarnessRuntimeDirectory stringByExpandingTildeInPath] stringByAppendingPathComponent:@"node_modules/@deepseek-ai/dsh/package.json"];
    NSData *data = [NSData dataWithContentsOfFile:packagePath];
    NSDictionary *package = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [package isKindOfClass:[NSDictionary class]] ? package[@"version"] : nil;
}

- (NSComparisonResult)compareVersion:(NSString *)left to:(NSString *)right {
    NSString *(^normalize)(NSString *) = ^NSString *(NSString *value) {
        return [value hasPrefix:@"v"] ? [value substringFromIndex:1] : value;
    };
    NSArray<NSString *> *(^parts)(NSString *) = ^NSArray *(NSString *value) {
        return [normalize(value) componentsSeparatedByString:@"-"];
    };
    NSArray<NSString *> *leftParts = parts(left);
    NSArray<NSString *> *rightParts = parts(right);
    NSArray<NSString *> *leftCore = [leftParts.firstObject componentsSeparatedByString:@"."];
    NSArray<NSString *> *rightCore = [rightParts.firstObject componentsSeparatedByString:@"."];
    for (NSUInteger index = 0; index < MAX(leftCore.count, rightCore.count); index++) {
        NSInteger leftNumber = index < leftCore.count ? [leftCore[index] integerValue] : 0;
        NSInteger rightNumber = index < rightCore.count ? [rightCore[index] integerValue] : 0;
        if (leftNumber != rightNumber) return leftNumber < rightNumber ? NSOrderedAscending : NSOrderedDescending;
    }
    NSString *leftPre = leftParts.count > 1 ? leftParts[1] : nil;
    NSString *rightPre = rightParts.count > 1 ? rightParts[1] : nil;
    if (!leftPre && !rightPre) return NSOrderedSame;
    if (!leftPre) return NSOrderedDescending;
    if (!rightPre) return NSOrderedAscending;
    NSArray<NSString *> *leftIdentifiers = [leftPre componentsSeparatedByString:@"."];
    NSArray<NSString *> *rightIdentifiers = [rightPre componentsSeparatedByString:@"."];
    for (NSUInteger index = 0; index < MAX(leftIdentifiers.count, rightIdentifiers.count); index++) {
        if (index >= leftIdentifiers.count) return NSOrderedAscending;
        if (index >= rightIdentifiers.count) return NSOrderedDescending;
        NSString *leftIdentifier = leftIdentifiers[index];
        NSString *rightIdentifier = rightIdentifiers[index];
        BOOL leftNumeric = leftIdentifier.integerValue == leftIdentifier.doubleValue && leftIdentifier.length > 0;
        BOOL rightNumeric = rightIdentifier.integerValue == rightIdentifier.doubleValue && rightIdentifier.length > 0;
        if (leftNumeric && rightNumeric && leftIdentifier.integerValue != rightIdentifier.integerValue) return leftIdentifier.integerValue < rightIdentifier.integerValue ? NSOrderedAscending : NSOrderedDescending;
        if (leftNumeric != rightNumeric) return leftNumeric ? NSOrderedAscending : NSOrderedDescending;
        NSComparisonResult result = [leftIdentifier compare:rightIdentifier options:NSCaseInsensitiveSearch];
        if (result != NSOrderedSame) return result;
    }
    return NSOrderedSame;
}

- (BOOL)isVersion:(NSString *)candidate newerThan:(NSString *)current {
    return [self compareVersion:candidate to:current] == NSOrderedDescending;
}

- (void)checkForUpdates:(id)sender {
    self.checkUpdateItem.enabled = NO;
    self.checkUpdateItem.title = @"正在检查更新…";
    [self fetchLatestRelease:^(NSDictionary *release, NSError *error) {
        self.checkUpdateItem.enabled = YES;
        self.checkUpdateItem.title = [NSString stringWithFormat:@"检查更新（当前 v%@）", self.currentVersion];
        if (error) {
            [self showAlert:@"检查更新失败" message:error.localizedDescription style:NSAlertStyleWarning];
            return;
        }

        NSString *tag = release[@"tag_name"];
        self.latestVersion = [tag hasPrefix:@"v"] ? [tag substringFromIndex:1] : tag;
        self.latestReleaseURL = release[@"html_url"];
        if ([self isVersion:self.latestVersion newerThan:self.currentVersion]) {
            NSArray *assets = release[@"assets"];
            NSDictionary *selectedAsset = nil;
            for (NSDictionary *asset in assets) {
                NSString *name = asset[@"name"];
                if ([name.pathExtension.lowercaseString isEqualToString:@"zip"] && [name.lowercaseString containsString:@"deepseekharnessmenubar"]) {
                    selectedAsset = asset;
                    break;
                }
            }
            if (!selectedAsset) {
                for (NSDictionary *asset in assets) {
                    NSString *assetName = asset[@"name"];
                    if ([assetName.pathExtension.lowercaseString isEqualToString:@"zip"]) {
                        selectedAsset = asset;
                        break;
                    }
                }
            }
            self.latestDownloadURL = [NSURL URLWithString:selectedAsset[@"browser_download_url"]];
            self.updateItem.title = self.latestDownloadURL ? [NSString stringWithFormat:@"更新到 v%@", self.latestVersion] : @"打开 Release 页面下载更新";
            self.updateItem.enabled = YES;
            NSString *message = self.latestDownloadURL
                ? [NSString stringWithFormat:@"发现新版本 v%@，点击“更新到 v%@”即可下载并安装。", self.latestVersion, self.latestVersion]
                : [NSString stringWithFormat:@"发现新版本 v%@，但 Release 没有可下载的 ZIP 文件。", self.latestVersion];
            [self showAlert:@"发现新版本" message:message style:NSAlertStyleInformational];
        } else {
            self.latestDownloadURL = nil;
            self.updateItem.title = @"已是最新版本";
            self.updateItem.enabled = NO;
            [self showAlert:@"已是最新版本" message:[NSString stringWithFormat:@"当前版本 v%@ 已经是最新版本。", self.currentVersion] style:NSAlertStyleInformational];
        }
    }];
}

- (NSString *)npmExecutable {
    NSMutableArray<NSString *> *candidates = [NSMutableArray arrayWithArray:@[
        @"/opt/homebrew/bin/npm",
        @"/usr/local/bin/npm",
        @"~/.volta/bin/npm",
        @"~/.asdf/shims/npm"
    ]];
    NSString *nvmDirectory = [@"~/.nvm/versions/node" stringByExpandingTildeInPath];
    NSArray<NSString *> *nodeVersions = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:nvmDirectory error:nil];
    for (NSString *version in nodeVersions) {
        [candidates addObject:[nvmDirectory stringByAppendingPathComponent:[version stringByAppendingPathComponent:@"bin/npm"]]];
    }
    for (NSString *candidate in candidates) {
        NSString *expanded = [candidate stringByExpandingTildeInPath];
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:expanded]) return expanded;
    }
    return nil;
}

- (NSDictionary<NSString *, NSString *> *)npmEnvironment {
    NSString *npm = [self npmExecutable];
    if (!npm) return @{};
    NSString *npmDirectory = [npm stringByDeletingLastPathComponent];
    NSMutableDictionary *environment = [NSMutableDictionary dictionary];
    NSString *path = NSProcessInfo.processInfo.environment[@"PATH"] ?: @"/usr/bin:/bin";
    environment[@"PATH"] = [NSString stringWithFormat:@"%@:%@", npmDirectory, path];
    environment[@"NPM_CONFIG_AUDIT"] = @"false";
    environment[@"NPM_CONFIG_FUND"] = @"false";

    NSString *proxyDescription = nil;
    NSDictionary *proxy = [self systemProxyConfigurationForURL:[NSURL URLWithString:@"https://registry.npmjs.org/"] description:&proxyDescription];
    self.proxyDescription = proxyDescription;
    NSString *proxyHost = proxy[(__bridge NSString *)kCFNetworkProxiesHTTPProxy];
    NSNumber *proxyPort = proxy[(__bridge NSString *)kCFNetworkProxiesHTTPPort];
    if (proxyHost.length > 0 && proxyPort.integerValue > 0) {
        NSString *proxyURL = [NSString stringWithFormat:@"http://%@:%@", proxyHost, proxyPort];
        environment[@"HTTP_PROXY"] = proxyURL;
        environment[@"HTTPS_PROXY"] = proxyURL;
        environment[@"http_proxy"] = proxyURL;
        environment[@"https_proxy"] = proxyURL;
        environment[@"NPM_CONFIG_PROXY"] = proxyURL;
        environment[@"NPM_CONFIG_HTTPS_PROXY"] = proxyURL;
    }
    return environment;
}

- (void)checkHarnessForUpdates:(id)sender {
    NSString *npm = [self npmExecutable];
    if (!npm) {
        [self showAlert:@"无法检查 Harness 更新" message:@"没有找到 npm。请确认 Node.js/npm 已安装，并且当前用户的 npm 可执行文件在标准路径中。" style:NSAlertStyleWarning];
        return;
    }
    self.checkHarnessUpdateItem.enabled = NO;
    self.checkHarnessUpdateItem.title = @"正在检查 Harness 更新…";
    NSDictionary *environment = [self npmEnvironment];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        DSHCommandResult *result = DSHRunCommandWithEnvironment(npm, @[@"view", DSHHarnessPackage, @"version", @"--json", @"--silent"], environment);
        NSString *latest = [result.output stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([latest hasPrefix:@"\""] && [latest hasSuffix:@"\""] && latest.length >= 2) latest = [latest substringWithRange:NSMakeRange(1, latest.length - 2)];
        NSError *error = nil;
        if (result.status != 0 || latest.length == 0 || [latest containsString:@"{"]) {
            NSString *message = result.error.length > 0 ? result.error : (result.output.length > 0 ? result.output : @"npm 没有返回版本号");
            error = [NSError errorWithDomain:@"DeepSeekHarnessMenuBar" code:result.status userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"npm 检查更新失败：%@\n使用网络：%@", message, self.proxyDescription ?: @"系统默认网络设置"]}];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.checkHarnessUpdateItem.enabled = YES;
            self.checkHarnessUpdateItem.title = [NSString stringWithFormat:@"检查 Harness 更新（当前 %@）", self.harnessCurrentVersion];
            if (error) {
                [self showAlert:@"检查 Harness 更新失败" message:error.localizedDescription style:NSAlertStyleWarning];
            } else if ([self isVersion:latest newerThan:self.harnessCurrentVersion]) {
                self.harnessLatestVersion = latest;
                self.updateHarnessItem.title = [NSString stringWithFormat:@"更新 DeepSeek Harness 到 v%@", latest];
                self.updateHarnessItem.enabled = YES;
                [self showAlert:@"发现 Harness 新版本" message:[NSString stringWithFormat:@"当前版本：%@\n最新版本：%@\n\n点击菜单中的“更新 DeepSeek Harness”开始升级。", self.harnessCurrentVersion, latest] style:NSAlertStyleInformational];
            } else {
                self.harnessLatestVersion = nil;
                self.updateHarnessItem.title = @"Harness 已是最新版本";
                self.updateHarnessItem.enabled = NO;
                [self showAlert:@"Harness 已是最新版本" message:[NSString stringWithFormat:@"当前版本 %@ 已是 npm registry 返回的最新版本。", self.harnessCurrentVersion] style:NSAlertStyleInformational];
            }
        });
    });
}

- (void)updateHarness:(id)sender {
    if (!self.harnessLatestVersion.length) {
        [self checkHarnessForUpdates:nil];
        return;
    }
    NSAlert *confirmation = [[NSAlert alloc] init];
    confirmation.alertStyle = NSAlertStyleInformational;
    confirmation.messageText = [NSString stringWithFormat:@"升级 DeepSeek Harness 到 v%@？", self.harnessLatestVersion];
    confirmation.informativeText = @"升级会暂时停止 com.dsh.web，使用 npm 更新 ~/.dsh/runtime，然后重新加载服务。建议先关闭正在进行的任务。";
    [confirmation addButtonWithTitle:@"升级"];
    [confirmation addButtonWithTitle:@"取消"];
    if ([confirmation runModal] != NSAlertFirstButtonReturn) return;

    NSString *npm = [self npmExecutable];
    if (!npm) {
        [self showAlert:@"无法升级 Harness" message:@"没有找到 npm。" style:NSAlertStyleWarning];
        return;
    }
    self.checkHarnessUpdateItem.enabled = NO;
    self.updateHarnessItem.enabled = NO;
    self.updateHarnessItem.title = @"正在升级 DeepSeek Harness…";
    NSString *runtime = [DSHHarnessRuntimeDirectory stringByExpandingTildeInPath];
    NSString *target = [NSString stringWithFormat:@"%@@latest", DSHHarnessPackage];
    NSDictionary *environment = [self npmEnvironment];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        DSHCommandResult *bootout = DSHRunCommand(@"/bin/launchctl", @[@"bootout", [NSString stringWithFormat:@"gui/%u/%@", getuid(), DSHServiceLabel]]);
        (void)bootout;
        DSHCommandResult *install = DSHRunCommandWithEnvironment(npm, @[@"install", @"--prefix", runtime, target, @"--no-audit", @"--no-fund", @"--update-notifier=false"], environment);
        NSError *error = nil;
        if (install.status != 0) {
            NSString *message = install.error.length > 0 ? install.error : install.output;
            error = [NSError errorWithDomain:@"DeepSeekHarnessMenuBar" code:install.status userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"npm 升级失败：%@", message ?: @"未知错误"]}];
        }
        if (!error) {
            NSString *plist = [@"~/Library/LaunchAgents/com.dsh.web.plist" stringByExpandingTildeInPath];
            DSHCommandResult *bootstrap = DSHRunCommand(@"/bin/launchctl", @[@"bootstrap", [NSString stringWithFormat:@"gui/%u", getuid()], plist]);
            if (bootstrap.status != 0) {
                error = [NSError errorWithDomain:@"DeepSeekHarnessMenuBar" code:bootstrap.status userInfo:@{NSLocalizedDescriptionKey: bootstrap.error.length > 0 ? bootstrap.error : @"Harness 更新后无法重新加载 launchd 服务"}];
            }
        } else {
            NSString *plist = [@"~/Library/LaunchAgents/com.dsh.web.plist" stringByExpandingTildeInPath];
            DSHRunCommand(@"/bin/launchctl", @[@"bootstrap", [NSString stringWithFormat:@"gui/%u", getuid()], plist]);
        }
        NSString *installedVersion = [self installedHarnessVersion] ?: @"未知";
        dispatch_async(dispatch_get_main_queue(), ^{
            self.checkHarnessUpdateItem.enabled = YES;
            if (error) {
                self.updateHarnessItem.title = [NSString stringWithFormat:@"更新 DeepSeek Harness 到 v%@", self.harnessLatestVersion];
                self.updateHarnessItem.enabled = YES;
                [self showAlert:@"Harness 更新失败" message:error.localizedDescription style:NSAlertStyleWarning];
            } else {
                self.harnessCurrentVersion = installedVersion;
                self.harnessLatestVersion = nil;
                self.checkHarnessUpdateItem.title = [NSString stringWithFormat:@"检查 Harness 更新（当前 %@）", installedVersion];
                self.updateHarnessItem.title = @"Harness 已是最新版本";
                self.updateHarnessItem.enabled = NO;
                [self showAlert:@"Harness 更新完成" message:[NSString stringWithFormat:@"DeepSeek Harness 已更新到 %@，服务正在重新启动。", installedVersion] style:NSAlertStyleInformational];
                [self refresh];
            }
        });
    });
}

- (void)updateApplication:(id)sender {
    if (!self.latestDownloadURL) {
        if (self.latestReleaseURL.length > 0) {
            [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:self.latestReleaseURL]];
        } else {
            [self checkForUpdates:nil];
        }
        return;
    }

    NSAlert *confirmation = [[NSAlert alloc] init];
    confirmation.alertStyle = NSAlertStyleInformational;
    confirmation.messageText = [NSString stringWithFormat:@"更新到 v%@？", self.latestVersion];
    confirmation.informativeText = @"应用会下载 GitHub Release，替换当前版本并自动重新打开。服务本身不会被修改。";
    [confirmation addButtonWithTitle:@"更新"];
    [confirmation addButtonWithTitle:@"取消"];
    if ([confirmation runModal] != NSAlertFirstButtonReturn) return;

    self.checkUpdateItem.enabled = NO;
    self.updateItem.enabled = NO;
    self.updateItem.title = @"正在下载更新…";
    [self downloadAndInstallUpdate:self.latestDownloadURL];
}

- (void)fetchLatestRelease:(void (^)(NSDictionary *release, NSError *error))completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:DSHGitHubLatestReleaseURL]];
    [request setValue:@"DeepSeekHarnessMenuBar/1.0" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    NSURLSessionDataTask *task = [self.updateSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            NSString *message = [NSString stringWithFormat:@"网络请求失败：%@\n使用网络：%@", error.localizedDescription, self.proxyDescription ?: @"系统默认网络设置"];
            NSError *networkError = [NSError errorWithDomain:@"DeepSeekHarnessMenuBar" code:error.code userInfo:@{NSLocalizedDescriptionKey: message}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, networkError); });
            return;
        }
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSInteger statusCode = httpResponse.statusCode;
        NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        if (statusCode < 200 || statusCode >= 300) {
            NSDictionary *errorJSON = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString *githubMessage = [errorJSON isKindOfClass:[NSDictionary class]] ? errorJSON[@"message"] : nil;
            NSString *detail = githubMessage.length > 0 ? githubMessage : (body.length > 500 ? [body substringToIndex:500] : body);
            NSString *hint = statusCode == 404
                ? @"请确认仓库存在，并且至少有一个已发布的 Release（不能只有 Draft）。"
                : statusCode == 403
                    ? @"可能是 GitHub API 限流或访问权限问题。"
                    : @"";
            NSString *message = [NSString stringWithFormat:@"GitHub 返回 HTTP %ld。%@ %@\n使用网络：%@", (long)statusCode, detail.length > 0 ? [NSString stringWithFormat:@"服务器信息：%@。", detail] : @"", hint, self.proxyDescription ?: @"系统默认网络设置"];
            NSError *httpError = [NSError errorWithDomain:@"DeepSeekHarnessMenuBar" code:statusCode userInfo:@{NSLocalizedDescriptionKey: message}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, httpError); });
            return;
        }
        NSError *jsonError = nil;
        NSDictionary *release = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (![release isKindOfClass:[NSDictionary class]] || !release[@"tag_name"]) {
            NSString *detail = body.length > 500 ? [body substringToIndex:500] : body;
            NSString *message = [NSString stringWithFormat:@"GitHub Release 响应格式不正确：%@\n返回内容：%@\n使用网络：%@", jsonError.localizedDescription ?: @"缺少 tag_name", detail, self.proxyDescription ?: @"系统默认网络设置"];
            NSError *formatError = [NSError errorWithDomain:@"DeepSeekHarnessMenuBar" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, formatError); });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(release, nil); });
    }];
    [task resume];
}

- (NSDictionary *)systemProxyConfigurationForURL:(NSURL *)url description:(NSString **)description {
    NSDictionary *settings = CFBridgingRelease(CFNetworkCopySystemProxySettings());
    NSArray *proxies = CFBridgingRelease(CFNetworkCopyProxiesForURL((__bridge CFURLRef)url, (__bridge CFDictionaryRef)settings));
    NSMutableDictionary *configuration = [NSMutableDictionary dictionary];
    NSString *selectedDescription = @"系统直连（未发现显式 HTTP/SOCKS 代理）";

    for (NSDictionary *proxy in proxies) {
        NSString *type = proxy[(__bridge NSString *)kCFProxyTypeKey];
        if ([type isEqualToString:(__bridge NSString *)kCFProxyTypeNone]) {
            selectedDescription = @"系统直连";
            break;
        }
        NSString *host = proxy[(__bridge NSString *)kCFProxyHostNameKey];
        NSNumber *port = proxy[(__bridge NSString *)kCFProxyPortNumberKey];
        if (host.length == 0 || port.integerValue <= 0) continue;

        if ([type isEqualToString:(__bridge NSString *)kCFProxyTypeHTTP] || [type isEqualToString:(__bridge NSString *)kCFProxyTypeHTTPS]) {
            configuration[(__bridge NSString *)kCFNetworkProxiesHTTPEnable] = @YES;
            configuration[(__bridge NSString *)kCFNetworkProxiesHTTPProxy] = host;
            configuration[(__bridge NSString *)kCFNetworkProxiesHTTPPort] = port;
            configuration[(__bridge NSString *)kCFNetworkProxiesHTTPSEnable] = @YES;
            configuration[(__bridge NSString *)kCFNetworkProxiesHTTPSProxy] = host;
            configuration[(__bridge NSString *)kCFNetworkProxiesHTTPSPort] = port;
            selectedDescription = [NSString stringWithFormat:@"系统代理 %@:%@", host, port];
            break;
        }
        if ([type isEqualToString:(__bridge NSString *)kCFProxyTypeSOCKS]) {
            configuration[(__bridge NSString *)kCFNetworkProxiesSOCKSEnable] = @YES;
            configuration[(__bridge NSString *)kCFNetworkProxiesSOCKSProxy] = host;
            configuration[(__bridge NSString *)kCFNetworkProxiesSOCKSPort] = port;
            selectedDescription = [NSString stringWithFormat:@"系统 SOCKS 代理 %@:%@", host, port];
            break;
        }
    }

    if (description) *description = selectedDescription;
    return configuration;
}

- (void)downloadAndInstallUpdate:(NSURL *)downloadURL {
    NSURLSessionDownloadTask *task = [self.updateSession downloadTaskWithURL:downloadURL completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.updateItem.title = [NSString stringWithFormat:@"更新到 v%@", self.latestVersion];
                self.updateItem.enabled = YES;
                self.checkUpdateItem.enabled = YES;
                [self showAlert:@"下载更新失败" message:error.localizedDescription style:NSAlertStyleWarning];
            });
            return;
        }

        NSString *tempRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"dsh-update-%@", NSUUID.UUID.UUIDString]];
        NSString *zipPath = [tempRoot stringByAppendingPathComponent:@"update.zip"];
        NSString *extractPath = [tempRoot stringByAppendingPathComponent:@"extracted"];
        NSError *fileError = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:extractPath withIntermediateDirectories:YES attributes:nil error:&fileError];
        [[NSFileManager defaultManager] copyItemAtURL:location toURL:[NSURL fileURLWithPath:zipPath] error:&fileError];
        DSHCommandResult *extractResult = fileError ? nil : DSHRunCommand(@"/usr/bin/ditto", @[@"-x", @"-k", zipPath, extractPath]);
        NSString *newAppPath = nil;
        if (!fileError && extractResult.status == 0) {
            NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtPath:extractPath];
            for (NSString *relativePath in enumerator) {
                if ([relativePath.pathExtension.lowercaseString isEqualToString:@"app"]) {
                    newAppPath = [extractPath stringByAppendingPathComponent:relativePath];
                    break;
                }
            }
        }

        NSError *updateError = fileError;
        if (!newAppPath) {
            NSString *reason = extractResult.error.length > 0 ? extractResult.error : @"ZIP 中没有找到 .app 文件";
            updateError = [NSError errorWithDomain:@"DeepSeekHarnessMenuBar" code:2 userInfo:@{NSLocalizedDescriptionKey: reason}];
        }
        if (!updateError) {
            NSBundle *newBundle = [NSBundle bundleWithPath:newAppPath];
            NSString *bundleIdentifier = [newBundle objectForInfoDictionaryKey:@"CFBundleIdentifier"];
            NSString *bundleVersion = [newBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
            NSString *executablePath = newBundle.executablePath;
            DSHCommandResult *signatureResult = DSHRunCommand(@"/usr/bin/codesign", @[@"--verify", @"--deep", @"--strict", newAppPath]);
            if (![bundleIdentifier isEqualToString:@"com.blackmady.deepseek-harness-menubar"] ||
                ![bundleVersion isEqualToString:self.latestVersion] ||
                ![[NSFileManager defaultManager] isExecutableFileAtPath:executablePath] ||
                signatureResult.status != 0) {
                updateError = [NSError errorWithDomain:@"DeepSeekHarnessMenuBar" code:5 userInfo:@{NSLocalizedDescriptionKey: @"下载的应用包身份、版本或代码签名校验失败"}];
            }
        }
        if (!updateError) {
            updateError = [self scheduleApplicationReplacement:newAppPath];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (updateError) {
                self.updateItem.title = [NSString stringWithFormat:@"更新到 v%@", self.latestVersion];
                self.updateItem.enabled = YES;
                self.checkUpdateItem.enabled = YES;
                [self showAlert:@"安装更新失败" message:updateError.localizedDescription style:NSAlertStyleWarning];
            } else {
                [NSApp terminate:nil];
            }
        });
    }];
    [task resume];
}

- (NSError *)scheduleApplicationReplacement:(NSString *)newAppPath {
    NSString *currentAppPath = [NSBundle mainBundle].bundlePath;
    NSString *parentPath = [currentAppPath stringByDeletingLastPathComponent];
    if (![[NSFileManager defaultManager] isWritableFileAtPath:parentPath]) {
        return [NSError errorWithDomain:@"DeepSeekHarnessMenuBar" code:3 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"没有权限写入应用目录：%@", parentPath]}];
    }

    NSString *backupPath = [parentPath stringByAppendingPathComponent:[NSString stringWithFormat:@".DeepSeekHarnessMenuBar.old.%@", NSUUID.UUID.UUIDString]];
    NSString *scriptPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"dsh-update-%@.sh", NSUUID.UUID.UUIDString]];
    NSString *(^quote)(NSString *) = ^NSString *(NSString *value) {
        return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
    };
    NSString *script = [NSString stringWithFormat:@"#!/bin/sh\nsleep 2\n/bin/mv %@ %@ || exit 1\n/bin/mv %@ %@ || { /bin/mv %@ %@; exit 1; }\n/usr/bin/open %@\n/bin/rm -rf %@\n/bin/rm -f %@\n", quote(currentAppPath), quote(backupPath), quote(newAppPath), quote(currentAppPath), quote(backupPath), quote(currentAppPath), quote(currentAppPath), quote(backupPath), quote(scriptPath)];
    NSError *writeError = nil;
    if (![script writeToFile:scriptPath atomically:YES encoding:NSUTF8StringEncoding error:&writeError]) return writeError;
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0755} ofItemAtPath:scriptPath error:&writeError];
    if (writeError) return writeError;
    NSTask *installer = [[NSTask alloc] init];
    installer.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    installer.arguments = @[scriptPath];
    installer.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    installer.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *launchError = nil;
    if (![installer launchAndReturnError:&launchError]) return launchError;
    return nil;
}

- (void)showAlert:(NSString *)title message:(NSString *)message style:(NSAlertStyle)style {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = style;
    alert.messageText = title;
    alert.informativeText = message;
    [alert addButtonWithTitle:@"好"];
    [alert runModal];
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
