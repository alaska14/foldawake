#import <Cocoa/Cocoa.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/pwr_mgt/IOPM.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <IOKit/hidsystem/IOHIDEventSystemClient.h>
#import <unistd.h>
#import <signal.h>

extern int DisplayServicesGetBrightness(CGDirectDisplayID display, float *brightness);
extern int DisplayServicesSetBrightness(CGDirectDisplayID display, float brightness);

// IOHID Private API Declarations for Hardware Thermal Sensors
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

#define kIOHIDEventTypeTemperature 15

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef key);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t to);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong, nonatomic) NSStatusItem *statusItem;
@property (strong, nonatomic) NSTimer *brightnessCacheTimer;
@property (assign, nonatomic) BOOL isAwake;
@property (assign, nonatomic) BOOL wasDimmedForClamshell;
@property (assign, nonatomic) float savedDisplayBrightness;
@property (assign, nonatomic) float savedKeyboardBrightness;
@property (strong, nonatomic) id keyboardClient;
@property (assign, nonatomic) IOPMAssertionID sleepAssertionID;
@property (assign, nonatomic) IOPMAssertionID idleAssertionID;
@property (assign, nonatomic) IONotificationPortRef notifyPort;
@property (assign, nonatomic) io_object_t notifier;

// Thermal Guardian State
@property (strong, nonatomic) NSTimer *thermalCheckTimer;
@property (assign, nonatomic) BOOL isThermalSleepOverruled;
@property (assign, nonatomic) int consecutiveDangerChecks;
@property (strong, nonatomic) NSString *lastThermalAbnormality;
@property (strong, nonatomic) NSDate *lastThermalTripDate;

- (void)handleClamshellChanged;
- (void)startThermalMonitoring;
- (void)stopThermalMonitoring;
- (void)runThermalCheck;
- (BOOL)checkThermalAbnormalities:(NSString **)outReason peakTemp:(double *)outPeak;
- (double)currentPeakTemperature;
- (BOOL)isKeyboardIdleDimmedOrSuppressed;
- (float)currentKeyboardBrightness;
- (void)setKeyboardBrightness:(float)val commit:(BOOL)commit;
- (void)setKeyboardBrightness:(float)val;
- (void)registerKeyboardNotifications;
@end

static void powerNotificationCallback(void *refCon, io_service_t service, natural_t messageType, void *messageArgument) {
    if (messageType == kIOPMMessageClamshellStateChange) {
        AppDelegate *delegate = (__bridge AppDelegate *)refCon;
        [delegate handleClamshellChanged];
    }
}

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self checkAuthorizationOnLaunch];

    // Load CoreBrightness framework for keyboard illumination control
    [[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/CoreBrightness.framework"] load];

    self.sleepAssertionID = kIOPMNullAssertionID;
    self.idleAssertionID = kIOPMNullAssertionID;
    self.wasDimmedForClamshell = NO;

    self.savedDisplayBrightness = [self currentDisplayBrightness];
    if (self.savedDisplayBrightness <= 0.05f) self.savedDisplayBrightness = 0.8f;

    // Load preserved keyboard brightness from NSUserDefaults or active hardware
    float persistedK = [[NSUserDefaults standardUserDefaults] floatForKey:@"FoldAwakeSavedKeyboardBrightness"];
    if (persistedK > 0.01f) {
        self.savedKeyboardBrightness = persistedK;
    } else {
        float curK = [self currentKeyboardBrightness];
        self.savedKeyboardBrightness = (curK > 0.01f) ? curK : 0.40f;
        [[NSUserDefaults standardUserDefaults] setFloat:self.savedKeyboardBrightness forKey:@"FoldAwakeSavedKeyboardBrightness"];
    }

    // Set up Status Item
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(statusItemClicked:);
    [self.statusItem.button sendActionOn:(NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp)];

    self.isThermalSleepOverruled = NO;
    self.lastThermalAbnormality = nil;
    self.lastThermalTripDate = nil;

    // Check system state ONCE at launch (zero recurring popen!)
    self.isAwake = [self checkSleepDisabled];
    if (self.isAwake) {
        [self acquireSleepAssertions];
        if ([self isLidClosed]) {
            [self startThermalMonitoring];
        }
    }
    [self updateIcon];

    // Register 100% event-driven IOKit clamshell notification (0.0% CPU, NO POLLING!)
    [self registerClamshellNotification];

    // Register event-driven keyboard brightness notification
    [self registerKeyboardNotifications];

    // Passive low-overhead brightness check (every 15s, purely in-memory, zero subshells)
    self.brightnessCacheTimer = [NSTimer scheduledTimerWithTimeInterval:15.0 target:self selector:@selector(cacheActiveBrightness) userInfo:nil repeats:YES];
}

#pragma mark - IOKit Event Notification (Zero CPU)

- (void)registerClamshellNotification {
    self.notifyPort = IONotificationPortCreate(kIOMainPortDefault);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource(self.notifyPort), kCFRunLoopDefaultMode);

    io_service_t rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    if (rootDomain) {
        io_object_t notif;
        IOServiceAddInterestNotification(self.notifyPort, rootDomain, kIOGeneralInterest, powerNotificationCallback, (__bridge void *)self, &notif);
        self.notifier = notif;
        IOObjectRelease(rootDomain);
    }
}

- (void)cacheActiveBrightness {
    if (!self.wasDimmedForClamshell && ![self isLidClosed]) {
        float curD = [self currentDisplayBrightness];
        if (curD > 0.05f) {
            self.savedDisplayBrightness = curD;
        }

        // Only record active keyboard brightness if it's NOT currently idle-dimmed or suppressed by ambient light!
        if (![self isKeyboardIdleDimmedOrSuppressed]) {
            float curK = [self currentKeyboardBrightness];
            if (curK > 0.01f) {
                self.savedKeyboardBrightness = curK;
                [[NSUserDefaults standardUserDefaults] setFloat:curK forKey:@"FoldAwakeSavedKeyboardBrightness"];
                [[NSUserDefaults standardUserDefaults] synchronize];
            }
        }
    }
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

#pragma mark - State Management & Assertions

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

- (void)acquireSleepAssertions {
    if (self.sleepAssertionID == kIOPMNullAssertionID) {
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventSystemSleep,
            kIOPMAssertionLevelOn,
            CFSTR("FoldAwake Clamshell Mode"),
            &_sleepAssertionID
        );
    }
    if (self.idleAssertionID == kIOPMNullAssertionID) {
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep,
            kIOPMAssertionLevelOn,
            CFSTR("FoldAwake Clamshell Mode"),
            &_idleAssertionID
        );
    }
}

- (void)releaseSleepAssertions {
    if (self.sleepAssertionID != kIOPMNullAssertionID) {
        IOPMAssertionRelease(self.sleepAssertionID);
        self.sleepAssertionID = kIOPMNullAssertionID;
    }
    if (self.idleAssertionID != kIOPMNullAssertionID) {
        IOPMAssertionRelease(self.idleAssertionID);
        self.idleAssertionID = kIOPMNullAssertionID;
    }
}

- (void)updateIcon {
    NSImage *icon = [self drawClamshellIconActive:self.isAwake];
    [icon setTemplate:YES];
    self.statusItem.button.image = icon;
    self.statusItem.button.toolTip = self.isAwake ? @"FoldAwake: Active (Mac stays awake with lid closed)" : @"FoldAwake: Inactive (Normal sleep)";
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

- (void)registerKeyboardNotifications {
    id client = [self getKeyboardClient];
    if (client) {
        SEL selCopy = @selector(copyKeyboardBacklightIDs);
        SEL selReg = @selector(registerNotificationForKeys:keyboardID:block:);
        if ([client respondsToSelector:selCopy] && [client respondsToSelector:selReg]) {
            NSArray *ids = ((id (*)(id, SEL))[client methodForSelector:selCopy])(client, selCopy);
            if (ids && ids.count > 0) {
                unsigned long long kid = [ids[0] unsignedLongLongValue];
                __weak AppDelegate *weakSelf = self;
                void (^block)(id) = ^(id key) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [weakSelf cacheActiveBrightness];
                    });
                };
                ((void (*)(id, SEL, id, unsigned long long, id))[client methodForSelector:selReg])(client, selReg, @[@"KeyboardBacklightBrightness"], kid, block);
            }
        }
    }
}

- (BOOL)isKeyboardIdleDimmedOrSuppressed {
    id client = [self getKeyboardClient];
    if (client) {
        SEL selCopy = @selector(copyKeyboardBacklightIDs);
        SEL selIsDim = @selector(isBacklightDimmedOnKeyboard:);
        SEL selIsSupp = @selector(isBacklightSuppressedOnKeyboard:);

        NSArray *ids = nil;
        if ([client respondsToSelector:selCopy]) {
            ids = ((id (*)(id, SEL))[client methodForSelector:selCopy])(client, selCopy);
        }
        if (ids && ids.count > 0) {
            unsigned long long kid = [ids[0] unsignedLongLongValue];
            BOOL isDim = NO;
            BOOL isSupp = NO;
            if ([client respondsToSelector:selIsDim]) {
                isDim = ((BOOL (*)(id, SEL, unsigned long long))[client methodForSelector:selIsDim])(client, selIsDim, kid);
            }
            if ([client respondsToSelector:selIsSupp]) {
                isSupp = ((BOOL (*)(id, SEL, unsigned long long))[client methodForSelector:selIsSupp])(client, selIsSupp, kid);
            }
            return (isDim || isSupp);
        }
    }
    return NO;
}

- (float)currentKeyboardBrightness {
    id client = [self getKeyboardClient];
    if (client) {
        SEL selCopy = @selector(copyKeyboardBacklightIDs);
        SEL selGet = @selector(brightnessForKeyboard:);
        if ([client respondsToSelector:selCopy] && [client respondsToSelector:selGet]) {
            NSArray *ids = ((id (*)(id, SEL))[client methodForSelector:selCopy])(client, selCopy);
            if (ids && ids.count > 0) {
                unsigned long long kid = [ids[0] unsignedLongLongValue];
                return ((float (*)(id, SEL, unsigned long long))[client methodForSelector:selGet])(client, selGet, kid);
            }
        }
        if ([client respondsToSelector:selGet]) {
            return ((float (*)(id, SEL, unsigned long long))[client methodForSelector:selGet])(client, selGet, 1ULL);
        }
    }
    return 0.0f;
}

- (void)setKeyboardBrightness:(float)val commit:(BOOL)commit {
    id client = [self getKeyboardClient];
    if (client) {
        SEL selCopy = @selector(copyKeyboardBacklightIDs);
        SEL selSetCommit = @selector(setBrightness:fadeSpeed:commit:forKeyboard:);
        SEL selSetSimple = @selector(setBrightness:forKeyboard:);

        NSArray *ids = nil;
        if ([client respondsToSelector:selCopy]) {
            ids = ((id (*)(id, SEL))[client methodForSelector:selCopy])(client, selCopy);
        }

        if (ids && ids.count > 0) {
            for (NSNumber *nid in ids) {
                unsigned long long kid = [nid unsignedLongValue];
                if ([client respondsToSelector:selSetCommit]) {
                    ((BOOL (*)(id, SEL, float, int, BOOL, unsigned long long))[client methodForSelector:selSetCommit])(client, selSetCommit, val, 1, commit, kid);
                } else if ([client respondsToSelector:selSetSimple]) {
                    ((void (*)(id, SEL, float, unsigned long long))[client methodForSelector:selSetSimple])(client, selSetSimple, val, kid);
                }
            }
        } else {
            if ([client respondsToSelector:selSetCommit]) {
                ((BOOL (*)(id, SEL, float, int, BOOL, unsigned long long))[client methodForSelector:selSetCommit])(client, selSetCommit, val, 1, commit, 1ULL);
            } else if ([client respondsToSelector:selSetSimple]) {
                ((void (*)(id, SEL, float, unsigned long long))[client methodForSelector:selSetSimple])(client, selSetSimple, val, 1ULL);
            }
        }
    }
}

- (void)setKeyboardBrightness:(float)val {
    [self setKeyboardBrightness:val commit:YES];
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

- (void)handleClamshellChanged {
    BOOL closed = [self isLidClosed];

    if (!closed) {
        // Clamshell opened up!
        [self stopThermalMonitoring];

        if (self.wasDimmedForClamshell) {
            [self restoreBrightness];
        }

        // Check if keep-awake was overruled due to abnormal heat while folded shut
        if (self.isThermalSleepOverruled) {
            self.isThermalSleepOverruled = NO;
            NSLog(@"[FoldAwake] Lid opened. Clearing emergency thermal override.");

            // Re-arm keep-awake if it was active
            if (self.isAwake) {
                [self acquireSleepAssertions];
                system("/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 1");
            }
            [self updateIcon];

            NSString *msg = [NSString stringWithFormat:@"Your Mac was put to sleep while folded shut to prevent overheating (%@). Normal clamshell protection has been restored.", self.lastThermalAbnormality ?: @"high temperature detected"];
            [self sendNotificationWithTitle:@"⚠️ Thermal Safety Alert" message:msg];
        }
    } else {
        // Clamshell folded shut!
        if (self.isAwake && !self.wasDimmedForClamshell) {
            // First cache active user brightness immediately before dimming
            [self cacheActiveBrightness];

            // Lid just shut while active! Dim display & keyboard to 0%
            [self setDisplayBrightness:0.0f];
            [self setKeyboardBrightness:0.0f commit:NO];
            self.wasDimmedForClamshell = YES;

            // Run zombie cleanup once when packed away
            [self reapRunawayZombies];

            // Start active Thermal Guardian monitoring while folded shut
            [self startThermalMonitoring];
        }
    }
}

#pragma mark - Thermal Guardian (Auto-sleeps on overheat while folded shut)

- (void)startThermalMonitoring {
    [self stopThermalMonitoring];
    self.consecutiveDangerChecks = 0;
    // Immediate initial check upon folding shut
    [self runThermalCheck];
    // Check every 10 seconds while folded shut (~0.003% CPU overhead, purely in-memory IOKit)
    self.thermalCheckTimer = [NSTimer scheduledTimerWithTimeInterval:10.0
                                                              target:self
                                                            selector:@selector(runThermalCheck)
                                                            userInfo:nil
                                                             repeats:YES];
}

- (void)stopThermalMonitoring {
    if (self.thermalCheckTimer) {
        [self.thermalCheckTimer invalidate];
        self.thermalCheckTimer = nil;
    }
    self.consecutiveDangerChecks = 0;
}

- (void)runThermalCheck {
    if (![self isLidClosed] || !self.isAwake || self.isThermalSleepOverruled) {
        return;
    }

    NSString *reason = nil;
    double peak = 0.0;
    BOOL danger = [self checkThermalAbnormalities:&reason peakTemp:&peak];

    if (danger) {
        self.consecutiveDangerChecks++;
        NSLog(@"[FoldAwake ThermalGuardian] Warning: Near-unsafe thermal level detected (%@, Peak: %.1f°C). Strike %d/2.", reason, peak, self.consecutiveDangerChecks);

        // Immediate emergency if battery exceeds 52°C or core exceeds 104°C
        BOOL isExtremeEmergency = (peak >= 104.0);
        if ([reason containsString:@"Battery"] && peak >= 52.0) {
            isExtremeEmergency = YES;
        }

        // Require 2 consecutive checks (sustained heat runaway) to avoid 1-second burst false positives
        if (self.consecutiveDangerChecks >= 2 || isExtremeEmergency) {
            [self triggerEmergencyThermalSleepWithReason:reason peakTemp:peak];
        }
    } else {
        if (self.consecutiveDangerChecks > 0) {
            NSLog(@"[FoldAwake ThermalGuardian] Temperature normalized (Peak: %.1f°C). Danger counter reset.", peak);
        }
        self.consecutiveDangerChecks = 0;
    }
}

- (void)triggerEmergencyThermalSleepWithReason:(NSString *)reason peakTemp:(double)peak {
    NSLog(@"[FoldAwake ThermalGuardian] EMERGENCY OVERHEAT: %@ (Peak: %.1f°C). Overruling keep-awake and putting Mac to sleep!", reason, peak);

    self.isThermalSleepOverruled = YES;
    self.lastThermalAbnormality = reason;
    self.lastThermalTripDate = [NSDate date];

    [self stopThermalMonitoring];

    // 1. Release sleep assertions
    [self releaseSleepAssertions];

    // 2. Overrule pmset disablesleep
    system("/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0");

    // 3. Put Mac to sleep until user opens the lid
    system("/usr/bin/pmset sleepnow &");
}

- (BOOL)checkThermalAbnormalities:(NSString **)outReason peakTemp:(double *)outPeak {
    // 1. Check OS Kernel Thermal State
    // Only trigger on Critical (cooling capacity fully exhausted, hardware emergency)
    // Fair/Serious are normal during heavy workloads and are allowed.
    NSProcessInfoThermalState osState = [[NSProcessInfo processInfo] thermalState];
    if (osState >= NSProcessInfoThermalStateCritical) {
        if (outReason) *outReason = @"macOS Kernel Thermal State reached Critical";
        return YES;
    }

    // 2. Scan Hardware Thermal Sensors via IOHID (Apple Silicon / modern macOS)
    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!client) return NO;

    NSDictionary *match = @{
        @"PrimaryUsagePage": @(0xff00),
        @"PrimaryUsage": @(5)
    };
    IOHIDEventSystemClientSetMatching(client, (__bridge CFDictionaryRef)match);
    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (!services) {
        CFRelease(client);
        return NO;
    }

    CFIndex count = CFArrayGetCount(services);
    double peak = 0.0;
    BOOL danger = NO;
    NSString *dangerReason = nil;

    for (CFIndex i = 0; i < count; i++) {
        IOHIDServiceClientRef s = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        NSString *name = (__bridge_transfer NSString *)IOHIDServiceClientCopyProperty(s, CFSTR("Product"));
        if (!name) name = (__bridge_transfer NSString *)IOHIDServiceClientCopyProperty(s, CFSTR("Transport"));
        if (!name) name = [NSString stringWithFormat:@"Sensor_%ld", (long)i];

        IOHIDEventRef ev = IOHIDServiceClientCopyEvent(s, kIOHIDEventTypeTemperature, 0, 0);
        if (ev) {
            double temp = IOHIDEventGetFloatValue(ev, (kIOHIDEventTypeTemperature << 16));
            CFRelease(ev);

            if (temp > 0.0 && temp < 150.0) {
                NSString *lower = [name lowercaseString];

                // Skip calibration target/offset pseudo-sensors (e.g. "tcal")
                if ([lower containsString:@"tcal"]) {
                    continue;
                }

                if (temp > peak) {
                    peak = temp;
                }

                // Threshold 1: Battery (Li-ion chemical danger limit is 50°C; BMS cutoff is 55°C)
                // Bag heat is totally acceptable up to 45-49°C. Only trigger at genuine unsafe limit >= 50.0°C.
                if ([lower containsString:@"battery"] || [lower containsString:@"gas gauge"]) {
                    if (temp >= 50.0) {
                        danger = YES;
                        dangerReason = [NSString stringWithFormat:@"Battery reached %.1f°C (%@)", temp, name];
                        break;
                    }
                }
                // Threshold 2: SoC / CPU / GPU Core Dies (TjMax is 106-108°C)
                // Heavy tasks in a bag can run hot at 85-95°C safely. Only intervene if approaching silicon shutdown >= 98.0°C.
                else if ([lower containsString:@"tdie"] || [lower containsString:@"soc"] || [lower containsString:@"cpu"] || [lower containsString:@"gpu"]) {
                    if (temp >= 98.0) {
                        danger = YES;
                        dangerReason = [NSString stringWithFormat:@"SoC Core Die reached %.1f°C (%@)", temp, name];
                        break;
                    }
                }
                // Threshold 3: Board / NAND Storage / Chassis (Display panel adhesive begins degrading at 65-70°C)
                // Allow warm bag operation up to 67°C. Only trigger if heat-soak reaches >= 68.0°C.
                else if ([lower containsString:@"nand"] || [lower containsString:@"tdev"]) {
                    if (temp >= 68.0) {
                        danger = YES;
                        dangerReason = [NSString stringWithFormat:@"Chassis/NAND heat-soak reached %.1f°C (%@)", temp, name];
                        break;
                    }
                }
                // Threshold 4: General hardware sensor limit
                else {
                    if (temp >= 95.0) {
                        danger = YES;
                        dangerReason = [NSString stringWithFormat:@"Hardware sensor reached %.1f°C (%@)", temp, name];
                        break;
                    }
                }
            }
        }
    }

    CFRelease(services);
    CFRelease(client);

    if (outPeak) *outPeak = peak;
    if (danger && outReason) *outReason = dangerReason;

    return danger;
}

- (double)currentPeakTemperature {
    double peak = 0.0;
    [self checkThermalAbnormalities:nil peakTemp:&peak];
    return peak;
}

- (void)restoreBrightness {
    if (self.wasDimmedForClamshell) {
        float targetD = (self.savedDisplayBrightness > 0.05f) ? self.savedDisplayBrightness : 0.8f;

        // Strictly preserve user's preferred keyboard level
        float targetK = self.savedKeyboardBrightness;
        if (targetK <= 0.01f) {
            float persistedK = [[NSUserDefaults standardUserDefaults] floatForKey:@"FoldAwakeSavedKeyboardBrightness"];
            if (persistedK > 0.01f) {
                targetK = persistedK;
                self.savedKeyboardBrightness = persistedK;
            } else {
                targetK = 0.40f;
            }
        }

        [self setDisplayBrightness:targetD];
        [self setKeyboardBrightness:targetK commit:YES];
        self.wasDimmedForClamshell = NO;

        // Anti-glitch multi-assertion: macOS CoreBrightness wake daemon re-evaluates
        // backlight ~200-500ms after lid open. Re-assert with commit:YES at 0.35s and 0.80s
        // so the user's exact setting strictly wins every single time!
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self setDisplayBrightness:targetD];
            [self setKeyboardBrightness:targetK commit:YES];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.80 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self setKeyboardBrightness:targetK commit:YES];
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

    [self cacheActiveBrightness];

    BOOL newState = !self.isAwake;
    self.isAwake = newState;

    NSString *cmd = newState ? @"/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 1" : @"/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0";
    system([cmd UTF8String]);

    if (newState) {
        [self acquireSleepAssertions];
        if ([self isLidClosed]) {
            [self startThermalMonitoring];
        }
    } else {
        [self stopThermalMonitoring];
        self.isThermalSleepOverruled = NO;
        [self releaseSleepAssertions];
        [self restoreBrightness];
    }

    [self updateIcon];

    NSString *title = newState ? @"FoldAwake: Clamshell Active" : @"FoldAwake: Normal Sleep";
    NSString *body = newState ? @"Your Mac will stay awake with the lid closed (display & keys auto-dimmed with Thermal Guardian)." : @"Your Mac will sleep normally when the lid is closed.";
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
    [self cacheActiveBrightness];

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

    // Thermal Guardian Status
    double curPeak = [self currentPeakTemperature];
    NSString *guardStr = (curPeak > 0.0)
        ? [NSString stringWithFormat:@"🛡️ Thermal Safety Guard: Armed (Peak: %.1f°C)", curPeak]
        : @"🛡️ Thermal Safety Guard: Armed (Auto-sleeps on overheat)";
    NSMenuItem *guardItem = [[NSMenuItem alloc] initWithTitle:guardStr action:nil keyEquivalent:@""];
    guardItem.enabled = NO;
    [menu addItem:guardItem];

    if (self.lastThermalAbnormality && self.lastThermalTripDate) {
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.timeStyle = NSDateFormatterShortStyle;
        NSString *tripStr = [NSString stringWithFormat:@"⚠️ Last Safety Sleep: %@ (%@)", [df stringFromDate:self.lastThermalTripDate], self.lastThermalAbnormality];
        NSMenuItem *tripItem = [[NSMenuItem alloc] initWithTitle:tripStr action:nil keyEquivalent:@""];
        tripItem.enabled = NO;
        [menu addItem:tripItem];
    }

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
    about.messageText = @"FoldAwake 1.1.3";
    about.informativeText = @"Zero-bloat clamshell mode toggle, auto display/keyboard dimmer, external disk ejector, automatic thermal runaway safety sleep guard, and runaway background battery protector for macOS.\n\nCrafted with native AppKit for 0.0% CPU and zero battery impact.";
    [about addButtonWithTitle:@"OK"];
    [NSApp activateIgnoringOtherApps:YES];
    [about runModal];
}

- (void)quitApp {
    [self stopThermalMonitoring];
    [self releaseSleepAssertions];
    [self restoreBrightness];
    [NSApp terminate:nil];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self stopThermalMonitoring];
    [self releaseSleepAssertions];
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
