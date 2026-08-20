#import <Cocoa/Cocoa.h>

static NSString *const DSHServiceLabel = @"com.dsh.web";
static const NSInteger DSHServicePort = 3080;
static NSString *const DSHGitHubLatestReleaseURL = @"https://api.github.com/repos/blackmady/deepseek-harness-menubar/releases/latest";

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

static DSHCommandResult *DSHRunCommand(NSString *executable, NSArray<NSString *> *arguments) {
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
@property(nonatomic, strong) DSHServiceController *service;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) NSURLSession *updateSession;
@property(nonatomic, copy) NSString *currentVersion;
@property(nonatomic, copy) NSString *latestVersion;
@property(nonatomic, strong) NSURL *latestDownloadURL;
@property(nonatomic, copy) NSString *latestReleaseURL;
@end

@implementation DSHAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.service = [[DSHServiceController alloc] init];
    self.currentVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"1.0.0";
    NSURLSessionConfiguration *sessionConfiguration = [NSURLSessionConfiguration defaultSessionConfiguration];
    sessionConfiguration.timeoutIntervalForRequest = 15;
    sessionConfiguration.timeoutIntervalForResource = 120;
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

- (BOOL)isVersion:(NSString *)candidate newerThan:(NSString *)current {
    NSArray<NSString *> *candidateParts = [[candidate stringByReplacingOccurrencesOfString:@"v" withString:@""] componentsSeparatedByString:@"."];
    NSArray<NSString *> *currentParts = [[current stringByReplacingOccurrencesOfString:@"v" withString:@""] componentsSeparatedByString:@"."];
    NSUInteger count = MAX(candidateParts.count, currentParts.count);
    for (NSUInteger index = 0; index < count; index++) {
        NSInteger candidateNumber = index < candidateParts.count ? [candidateParts[index] integerValue] : 0;
        NSInteger currentNumber = index < currentParts.count ? [currentParts[index] integerValue] : 0;
        if (candidateNumber != currentNumber) return candidateNumber > currentNumber;
    }
    return NO;
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
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
            return;
        }
        NSError *jsonError = nil;
        NSDictionary *release = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (![release isKindOfClass:[NSDictionary class]] || !release[@"tag_name"]) {
            NSError *formatError = [NSError errorWithDomain:@"DeepSeekHarnessMenuBar" code:1 userInfo:@{NSLocalizedDescriptionKey: jsonError.localizedDescription ?: @"GitHub Release 响应格式不正确"}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, formatError); });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(release, nil); });
    }];
    [task resume];
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
