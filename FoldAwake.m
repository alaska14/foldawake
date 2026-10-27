#import <Cocoa/Cocoa.h>
#import <IOKit/IOKitLib.h>
#import <unistd.h>
#import <signal.h>

extern int DisplayServicesGetBrightness(CGDirectDisplayID display, float *brightness);
extern int DisplayServicesSetBrightness(CGDirectDisplayID display, float brightness);

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong, nonatomic) NSStatusItem *statusItem;
@property (strong, nonatomic) NSTimer *timer;
@property (strong, nonatomic) NSTimer *watchdogTimer;
@property (strong, nonatomic) NSTimer *clamshellTimer;
@property (assign, nonatomic) BOOL isAwake;
@property (assign, nonatomic) BOOL wasDimmedForClamshell;
@property (assign, nonatomic) float savedDisplayBrightness;
@property (assign, nonatomic) float savedKeyboardBrightness;
@property (strong, nonatomic) id keyboardClient;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self checkAuthorizationOnLaunch];

    // Load CoreBrightness framework for keyboard illumination control
    [[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/CoreBrightness.framework"] load];

    self.savedDisplayBrightness = [self currentDisplayBrightness];
    if (self.savedDisplayBrightness <= 0.05f) self.savedDisplayBrightness = 0.8f;

    self.savedKeyboardBrightness = [self currentKeyboardBrightness];
    if (self.savedKeyboardBrightness <= 0.01f) self.savedKeyboardBrightness = 0.5f;

    self.wasDimmedForClamshell = NO;

    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(statusItemClicked:);
    [self.statusItem.button sendActionOn:(NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp)];

    [self updateStateFromSystem];

    self.timer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self selector:@selector(updateStateFromSystem) userInfo:nil repeats:YES];
    self.watchdogTimer = [NSTimer scheduledTimerWithTimeInterval:120.0 target:self selector:@selector(reapRunawayZombies) userInfo:nil repeats:YES];
    self.clamshellTimer = [NSTimer scheduledTimerWithTimeInterval:0.4 target:self selector:@selector(checkClamshellAndBacklights) userInfo:nil repeats:YES];
    
    [self reapRunawayZombies];
}

#pragma mark - Permissions / Authorization

- (BOOL)hasSudoPermission {
    int status = system("/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null >/dev/null");
    return (status == 0);
}

- (void)checkAuthorizationOnLaunch {
    if ([self hasSudoPermission]) {
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Welcome to FoldAwake";
    alert.informativeText = @"FoldAwake requires one-time permission to control lid sleep without interrupting you with password prompts.\n\nClick 'Authorize' to configure this securely.";
    [alert addButtonWithTitle:@"Authorize"];
    [alert addButtonWithTitle:@"Quit"];
    alert.alertStyle = NSAlertStyleInformational;

    [NSApp activateIgnoringOtherApps:YES];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        NSString *script = @"do shell script \"echo '%admin ALL=(ALL) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0' > /etc/sudoers.d/foldawake_powerprotect && chmod 0440 /etc/sudoers.d/foldawake_powerprotect\" with administrator privileges";
        NSAppleScript *appleScript = [[NSAppleScript alloc] initWithSource:script];
        NSDictionary *errorInfo = nil;
        [appleScript executeAndReturnError:&errorInfo];

        if (![self hasSudoPermission]) {
            NSAlert *failAlert = [[NSAlert alloc] init];
            failAlert.messageText = @"Authorization Required";
            failAlert.informativeText = @"FoldAwake could not acquire the required permissions. You can grant permission manually or relaunch FoldAwake.";
            failAlert.alertStyle = NSAlertStyleWarning;
            [failAlert runModal];
        }
    } else {
        [NSApp terminate:nil];
    }
}

#pragma mark - State Management

- (BOOL)checkSleepDisabled {
    FILE *fp = popen("/usr/bin/pmset -g", "r");
    if (!fp) return NO;
    char buffer[512];
    BOOL disabled = NO;
    while (fgets(buffer, sizeof(buffer), fp)) {
        if (strstr(buffer, "SleepDisabled") && strstr(buffer, "1")) {
            disabled = YES;
            break;
        }
    }
    pclose(fp);
    return disabled;
}

- (void)updateStateFromSystem {
    BOOL current = [self checkSleepDisabled];
    if (current != self.isAwake || self.statusItem.button.image == nil) {
        self.isAwake = current;
        NSImage *icon = [self drawClamshellIconActive:self.isAwake];
        [icon setTemplate:YES];
        self.statusItem.button.image = icon;
        self.statusItem.button.toolTip = self.isAwake ? @"FoldAwake: Active (Mac stays awake with lid closed)" : @"FoldAwake: Inactive (Normal sleep)";
    }
}

#pragma mark - Smart Clamshell Display & Keyboard Auto-Dimming

- (id)getKeyboardClient {
    if (!self.keyboardClient) {
        [[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/CoreBrightness.framework"] load];
        Class kbc = NSClassFromString(@"KeyboardBrightnessClient");
        if (kbc) {
            self.keyboardClient = [[kbc alloc] init];
        }
    }
    return self.keyboardClient;
}

- (float)currentKeyboardBrightness {
    id client = [self getKeyboardClient];
    if (client) {
        SEL selCopy = @selector(copyKeyboardBacklightIDs);
        SEL selGet = @selector(brightnessForKeyboard:);
        if ([client respondsToSelector:selCopy] && [client respondsToSelector:selGet]) {
            NSArray *ids = ((id (*)(id, SEL))[client methodForSelector:selCopy])(client, selCopy);
            if (ids && ids.count > 0) {
                unsigned long kid = [ids[0] unsignedLongValue];
                return ((float (*)(id, SEL, unsigned long))[client methodForSelector:selGet])(client, selGet, kid);
            }
        }
        if ([client respondsToSelector:selGet]) {
            return ((float (*)(id, SEL, unsigned long))[client methodForSelector:selGet])(client, selGet, 1);
        }
    }
    return 0.0f;
}

- (void)setKeyboardBrightness:(float)val {
    id client = [self getKeyboardClient];
    if (client) {
        SEL selCopy = @selector(copyKeyboardBacklightIDs);
        SEL selSet = @selector(setBrightness:forKeyboard:);
        SEL selSetAuto = @selector(enableAutoBrightness:forKeyboard:);

        NSArray *ids = nil;
        if ([client respondsToSelector:selCopy]) {
            ids = ((id (*)(id, SEL))[client methodForSelector:selCopy])(client, selCopy);
        }

        if (ids && ids.count > 0) {
            for (NSNumber *nid in ids) {
                unsigned long kid = [nid unsignedLongValue];
                if ([client respondsToSelector:selSetAuto]) {
                    ((BOOL (*)(id, SEL, BOOL, unsigned long))[client methodForSelector:selSetAuto])(client, selSetAuto, NO, kid);
                }
                if ([client respondsToSelector:selSet]) {
                    ((void (*)(id, SEL, float, unsigned long))[client methodForSelector:selSet])(client, selSet, val, kid);
                }
            }
        } else {
            if ([client respondsToSelector:selSetAuto]) {
                ((BOOL (*)(id, SEL, BOOL, unsigned long))[client methodForSelector:selSetAuto])(client, selSetAuto, NO, 1);
            }
            if ([client respondsToSelector:selSet]) {
                ((void (*)(id, SEL, float, unsigned long))[client methodForSelector:selSet])(client, selSet, val, 1);
            }
        }
    }
}

- (float)currentDisplayBrightness {
    float b = 1.0f;
    CGDirectDisplayID mainDisplay = CGMainDisplayID();
    if (DisplayServicesGetBrightness(mainDisplay, &b) == 0) {
        return b;
    }
    return 1.0f;
}

- (void)setDisplayBrightness:(float)val {
    CGDirectDisplayID mainDisplay = CGMainDisplayID();
    DisplayServicesSetBrightness(mainDisplay, val);
}

- (BOOL)isLidClosed {
    io_service_t rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    if (!rootDomain) return NO;
    CFBooleanRef clamshell = (CFBooleanRef)IORegistryEntryCreateCFProperty(rootDomain, CFSTR("AppleClamshellState"), kCFAllocatorDefault, 0);
    BOOL isClosed = NO;
    if (clamshell) {
        isClosed = CFBooleanGetValue(clamshell);
        CFRelease(clamshell);
    }
    IOObjectRelease(rootDomain);
    return isClosed;
}

- (void)checkClamshellAndBacklights {
    BOOL closed = [self isLidClosed];

    if (!closed) {
        if (self.wasDimmedForClamshell) {
            // Lid reopened after being dimmed!
            [self restoreBrightness];
        } else {
            // While lid is open and active, continuously track user's real brightness levels
            float curD = [self currentDisplayBrightness];
            float curK = [self currentKeyboardBrightness];
            if (curD > 0.05f) {
                self.savedDisplayBrightness = curD;
            }
            if (curK > 0.01f) {
                self.savedKeyboardBrightness = curK;
            }
        }
        return;
    }

    // If lid is closed and FoldAwake is active:
    if (self.isAwake && !self.wasDimmedForClamshell) {
        // Clamshell closed! Dim display and keyboard to 0%
        [self setDisplayBrightness:0.0f];
        [self setKeyboardBrightness:0.0f];
        self.wasDimmedForClamshell = YES;
    }
}

- (void)restoreBrightness {
    if (self.wasDimmedForClamshell) {
        float targetD = (self.savedDisplayBrightness > 0.05f) ? self.savedDisplayBrightness : 0.8f;
        float targetK = (self.savedKeyboardBrightness > 0.01f) ? self.savedKeyboardBrightness : 0.5f;

        [self setDisplayBrightness:targetD];
        [self setKeyboardBrightness:targetK];
        self.wasDimmedForClamshell = NO;

        // Re-assert brightness after 0.35s to prevent macOS ambient sensor daemon from overriding
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self setDisplayBrightness:targetD];
            [self setKeyboardBrightness:targetK];
        });
    }
}

#pragma mark - Action Handling

- (void)statusItemClicked:(id)sender {
    NSEvent *event = [NSApp currentEvent];
    if (event.type == NSEventTypeRightMouseUp || (event.modifierFlags & NSEventModifierFlagControl)) {
        [self showMenu];
    } else {
        [self toggleSleep];
    }
}

- (void)toggleSleep {
    if (![self hasSudoPermission]) {
        [self checkAuthorizationOnLaunch];
        if (![self hasSudoPermission]) return;
    }

    BOOL newState = !self.isAwake;
    NSString *cmd = newState ? @"/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 1" : @"/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0";
    system([cmd UTF8String]);

    if (!newState) {
        [self restoreBrightness];
    }

    [self updateStateFromSystem];

    NSString *title = newState ? @"FoldAwake: Clamshell Active" : @"FoldAwake: Normal Sleep";
    NSString *body = newState ? @"Your Mac will stay awake with the lid closed (display & keys auto-dimmed)." : @"Your Mac will sleep normally when the lid is closed.";
    [self sendNotificationWithTitle:title message:body];
}

- (void)sendNotificationWithTitle:(NSString *)title message:(NSString *)msg {
    NSString *script = [NSString stringWithFormat:@"display notification \"%@\" with title \"%@\"", msg, title];
    NSAppleScript *as = [[NSAppleScript alloc] initWithSource:script];
    [as executeAndReturnError:nil];
}

- (void)ejectExternalDisks {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *script = @"tell application \"Finder\" to eject (every disk whose ejectable is true)";
        NSAppleScript *as = [[NSAppleScript alloc] initWithSource:script];
        NSDictionary *error = nil;
        [as executeAndReturnError:&error];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!error) {
                [self sendNotificationWithTitle:@"FoldAwake" message:@"All external disks have been safely ejected."];
            } else {
                [self sendNotificationWithTitle:@"FoldAwake" message:@"No external ejectable disks found."];
            }
        });
    });
}

- (void)openFeedback {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/alaska14/foldawake/issues"]];
}

- (void)showMenu {
    NSMenu *menu = [[NSMenu alloc] init];
    menu.autoenablesItems = NO;

    NSString *statusStr = self.isAwake ? @"● Clamshell Mode: Active" : @"○ Normal Sleep: Active";
    NSMenuItem *statusItem = [[NSMenuItem alloc] initWithTitle:statusStr action:nil keyEquivalent:@""];
    statusItem.enabled = NO;
    [menu addItem:statusItem];

    NSString *toggleTitle = self.isAwake ? @"Disable Clamshell Mode" : @"Enable Clamshell Mode";
    NSMenuItem *toggleItem = [[NSMenuItem alloc] initWithTitle:toggleTitle action:@selector(toggleSleep) keyEquivalent:@"t"];
    toggleItem.target = self;
    [menu addItem:toggleItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *ejectItem = [[NSMenuItem alloc] initWithTitle:@"⏏ Eject All External Disks" action:@selector(ejectExternalDisks) keyEquivalent:@"e"];
    ejectItem.target = self;
    [menu addItem:ejectItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *feedbackItem = [[NSMenuItem alloc] initWithTitle:@"💬 Send Feedback / Feature Request..." action:@selector(openFeedback) keyEquivalent:@""];
    feedbackItem.target = self;
    [menu addItem:feedbackItem];

    NSMenuItem *aboutItem = [[NSMenuItem alloc] initWithTitle:@"About FoldAwake" action:@selector(showAbout) keyEquivalent:@""];
    aboutItem.target = self;
    [menu addItem:aboutItem];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit FoldAwake" action:@selector(quitApp) keyEquivalent:@"q"];
    quitItem.target = self;
    [menu addItem:quitItem];

    self.statusItem.menu = menu;
    [self.statusItem.button performClick:nil];
    self.statusItem.menu = nil;
}

- (void)showAbout {
    NSAlert *about = [[NSAlert alloc] init];
    about.messageText = @"FoldAwake 1.1.2";
    about.informativeText = @"Zero-bloat clamshell mode toggle, auto display/keyboard dimmer, external disk ejector, and runaway background battery protector for macOS.\n\nCrafted with native AppKit for 0.0% CPU and zero battery impact.";
    [about addButtonWithTitle:@"OK"];
    [NSApp activateIgnoringOtherApps:YES];
    [about runModal];
}

- (void)quitApp {
    [self restoreBrightness];
    [NSApp terminate:nil];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self restoreBrightness];
}

- (void)reapRunawayZombies {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        FILE *fp = popen("/bin/ps -eo pid,ppid,pcpu,comm | /usr/bin/grep 'com.apple.WebKit.WebContent' | /usr/bin/awk '$2 == 1 && $3 > 80 {print $1, $3}'", "r");
        if (!fp) return;
        char line[128];
        while (fgets(line, sizeof(line), fp)) {
            int pid = 0;
            float cpu = 0;
            if (sscanf(line, "%d %f", &pid, &cpu) == 2 && pid > 1) {
                kill(pid, SIGKILL);
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSString *msg = [NSString stringWithFormat:@"Terminated orphaned WebKit background leak (PID %d, %.0f%% CPU).", pid, cpu];
                    [self sendNotificationWithTitle:@"Battery Saver Guard" message:msg];
                });
            }
        }
        pclose(fp);
    });
}

#pragma mark - Option 1: Clean Clamshell Outline (Active = 100% White, Inactive = 35% Dimmed Gray)

- (NSImage *)drawClamshellIconActive:(BOOL)active {
    NSSize size = NSMakeSize(18, 14);
    NSImage *image = [[NSImage alloc] initWithSize:size];
    [image lockFocus];

    [[NSColor clearColor] set];
    NSRectFill(NSMakeRect(0, 0, size.width, size.height));

    NSRect frameRect = NSMakeRect(1.0, 1.5, 16.0, 11.0);
    CGFloat radius = 2.2;
    CGFloat strokeW = 1.25;

    CGFloat yUpper = 7.2;
    CGFloat yLower = 5.8;
    CGFloat yNotch = 4.4;

    // Active: Full 100% contrast crisp white
    // Inactive: Subtle 35% translucent dimmed gray
    CGFloat alpha = active ? 1.0f : 0.35f;
    [[NSColor colorWithCalibratedWhite:0.0 alpha:alpha] set];

    // Clamshell outer rounded frame
    NSBezierPath *frame = [NSBezierPath bezierPathWithRoundedRect:frameRect xRadius:radius yRadius:radius];
    [frame setLineWidth:strokeW];
    [frame stroke];

    // Notch seam
    NSBezierPath *band = [NSBezierPath bezierPath];
    [band moveToPoint:NSMakePoint(frameRect.origin.x, yUpper)];
    [band lineToPoint:NSMakePoint(NSMaxX(frameRect), yUpper)];
    [band lineToPoint:NSMakePoint(NSMaxX(frameRect), yLower)];
    [band lineToPoint:NSMakePoint(13.6, yLower)];

    // Top right smooth curve
    [band curveToPoint:NSMakePoint(12.7, 5.0)
         controlPoint1:NSMakePoint(13.2, yLower)
         controlPoint2:NSMakePoint(12.9, 5.4)];

    // Bottom right smooth curve
    [band curveToPoint:NSMakePoint(11.7, yNotch)
         controlPoint1:NSMakePoint(12.5, yNotch)
         controlPoint2:NSMakePoint(12.1, yNotch)];

    // Flat notch bottom
    [band lineToPoint:NSMakePoint(6.3, yNotch)];

    // Bottom left smooth curve
    [band curveToPoint:NSMakePoint(5.3, 5.0)
         controlPoint1:NSMakePoint(5.9, yNotch)
         controlPoint2:NSMakePoint(5.5, yNotch)];

    // Top left smooth curve
    [band curveToPoint:NSMakePoint(4.4, yLower)
         controlPoint1:NSMakePoint(5.1, 5.4)
         controlPoint2:NSMakePoint(4.8, yLower)];

    [band lineToPoint:NSMakePoint(frameRect.origin.x, yLower)];
    [band closePath];
    [band fill];

    [image unlockFocus];
    [image setTemplate:YES];
    return image;
}

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
