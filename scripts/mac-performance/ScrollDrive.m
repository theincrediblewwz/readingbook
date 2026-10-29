// In-process input for an isolated ReadingBook diagnostic app only.
// No OS events, AppleScript, input injection into other processes or forced draw.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <PDFKit/PDFKit.h>
#import <libproc.h>
#import <mach/mach_time.h>
#import <dispatch/dispatch.h>
#include <math.h>

static NSString *RBCanonical(NSString *path) {
    return [[path stringByStandardizingPath] stringByResolvingSymlinksInPath];
}
static BOOL RBInside(NSString *path, NSString *workspace) {
    return [path hasPrefix:[workspace stringByAppendingString:@"/"]];
}
static NSString *RBExecutable(void) {
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    return proc_pidpath(getpid(), path, sizeof(path)) > 0 ? RBCanonical([NSString stringWithUTF8String:path]) : @"";
}
static NSDictionary *RBRect(NSRect r) {
    return @{@"x": @(r.origin.x), @"y": @(r.origin.y), @"width": @(r.size.width), @"height": @(r.size.height)};
}

@interface RBScrollDrive : NSObject
@property(nonatomic, copy) NSString *workspace;
@property(nonatomic, copy) NSString *control;
@property(nonatomic, copy) NSString *nonce;
@property(nonatomic, copy) NSString *executable;
@property(nonatomic, strong) dispatch_source_t poller;
@property(nonatomic, strong) dispatch_source_t ticker;
@property(nonatomic, weak) PDFView *pdf;
@property(nonatomic, weak) NSClipView *clip;
@property(nonatomic, weak) NSScrollView *scroll;
@property(nonatomic, weak) NSWindow *window;
@property(nonatomic, strong) PDFDocument *document;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *ticks;
@property(nonatomic) NSPoint initialOrigin;
@property(nonatomic) NSPoint parkedPointer;
@property(nonatomic) BOOL pointerMoved;
@property(nonatomic) BOOL pointerHitsPDFAtStart;
@property(nonatomic) NSRect lastClipBounds;
@property(nonatomic) NSUInteger stablePolls;
@property(nonatomic) BOOL ready;
@property(nonatomic) BOOL commandAccepted;
@property(atomic) BOOL finished;
@property(nonatomic) uint64_t createdTicks;
@property(nonatomic) uint64_t startTicks;
@property(nonatomic) double secondsPerTick;
@property(nonatomic) double duration;
@property(nonatomic) double speed;
@property(nonatomic) double inputHz;
@property(nonatomic) NSInteger direction;
@property(nonatomic, copy) NSArray<NSNumber *> *initialVisiblePages;
@property(nonatomic, strong) id initialCenterPage;
@end

@implementation RBScrollDrive
- (void)write:(NSDictionary *)value name:(NSString *)name {
    NSMutableDictionary *record = [value mutableCopy];
    record[@"nonce"] = self.nonce; record[@"pid"] = @(getpid());
    record[@"executable"] = self.executable; record[@"recordedMachTicks"] = @(mach_absolute_time());
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    if (data) [data writeToFile:[self.control stringByAppendingPathComponent:name] options:NSDataWritingAtomic error:nil];
}
- (PDFView *)pdfUnder:(NSView *)view {
    if (!view || view.hiddenOrHasHiddenAncestor) return nil;
    if ([view isKindOfClass:PDFView.class]) return (PDFView *)view;
    for (NSView *child in view.subviews) {
        PDFView *found = [self pdfUnder:child]; if (found) return found;
    }
    return nil;
}
- (BOOL)findOwnPDF {
    for (NSWindow *window in NSApp.windows) {
        if (!window.visible) continue;
        PDFView *pdf = [self pdfUnder:window.contentView];
        if (!pdf || !pdf.document || [pdf.document isLocked] || pdf.document.pageCount == 0) continue;
        NSURL *url = pdf.document.documentURL;
        // An accidentally inherited real-library preference must not turn a
        // diagnostic into activity in the user's actual book workspace.
        if (!url.isFileURL || !RBInside(RBCanonical(url.path), self.workspace)) continue;
        NSView *documentView = pdf.documentView;
        NSScrollView *scroll = documentView.enclosingScrollView;
        NSClipView *clip = scroll.contentView;
        if (!documentView || !scroll || !clip || clip.bounds.size.height < 100 ||
            documentView.bounds.size.height <= clip.bounds.size.height + 100) continue;
        if (self.pdf == pdf && self.clip == clip && self.document == pdf.document &&
            NSEqualRects(self.lastClipBounds, clip.bounds)) self.stablePolls += 1;
        else { self.stablePolls = 0; self.ready = NO; }
        self.pdf = pdf; self.clip = clip; self.scroll = scroll;
        self.window = window; self.document = pdf.document; self.lastClipBounds = clip.bounds;
        return self.stablePolls >= 2;
    }
    self.ready = NO; self.stablePolls = 0;
    return NO;
}
- (NSDictionary *)foreground {
    return @{@"appActive": @(NSApp.active), @"keyWindow": @(self.window.keyWindow),
             @"windowVisible": @(self.window.visible),
             @"occlusionVisible": @((self.window.occlusionState & NSWindowOcclusionStateVisible) != 0)};
}
- (BOOL)foregroundOK {
    return NSApp.active && self.window.keyWindow && self.window.visible &&
        (self.window.occlusionState & NSWindowOcclusionStateVisible) != 0;
}
- (BOOL)pointerHitsPDF {
    NSView *content = self.window.contentView;
    NSPoint windowPoint = [self.window convertPointFromScreen:NSEvent.mouseLocation];
    NSView *hit = [content hitTest:[content convertPoint:windowPoint fromView:nil]];
    return hit && (hit == self.pdf || [hit isDescendantOf:self.pdf]);
}
- (NSArray<NSNumber *> *)visiblePageNumbers {
    NSMutableArray<NSNumber *> *numbers = [NSMutableArray array];
    for (PDFPage *page in self.pdf.visiblePages) {
        NSUInteger index = [self.document indexForPage:page];
        if (index != NSNotFound) [numbers addObject:@(index + 1)];
    }
    return [numbers sortedArrayUsingSelector:@selector(compare:)];
}
- (id)centerPageNumber {
    NSPoint clipCenter = NSMakePoint(NSMidX(self.clip.bounds), NSMidY(self.clip.bounds));
    NSPoint point = [self.pdf convertPoint:clipCenter fromView:self.clip];
    PDFPage *page = [self.pdf pageForPoint:point nearest:YES];
    NSUInteger index = page ? [self.document indexForPage:page] : NSNotFound;
    return index == NSNotFound ? (id)NSNull.null : @(index + 1);
}
- (void)beginPolling {
    self.createdTicks = mach_absolute_time();
    mach_timebase_info_data_t timebase; mach_timebase_info(&timebase);
    self.secondsPerTick = (double)timebase.numer / (double)timebase.denom / 1e9;
    [self write:@{@"status": @"driver-loaded", @"permissionRequested": @NO,
        @"inputMethod": @"programmatic-own-process-NSClipView-scrollToPoint"} name:@"driver-loaded.json"];
    self.poller = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.poller, DISPATCH_TIME_NOW, NSEC_PER_SEC / 4, NSEC_PER_MSEC * 5);
    __weak RBScrollDrive *weakSelf = self;
    dispatch_source_set_event_handler(self.poller, ^{ [weakSelf poll]; });
    dispatch_resume(self.poller);
}
- (void)poll {
    if ((mach_absolute_time() - self.createdTicks) * self.secondsPerTick > 180) {
        [self write:@{@"status": @"timed-out-waiting-for-command-or-workspace-pdf"} name:@"driver-failure.json"];
        dispatch_source_cancel(self.poller); self.poller = nil; self.finished = YES; return;
    }
    if (![self findOwnPDF]) return;
    if (!self.ready) {
        self.ready = YES;
        mach_timebase_info_data_t timebase; mach_timebase_info(&timebase);
        [self write:@{@"status": @"driver-ready", @"windowID": @(self.window.windowNumber),
            @"timebaseNumer": @(timebase.numer), @"timebaseDenom": @(timebase.denom),
            @"clipBounds": RBRect(self.clip.bounds), @"documentBounds": RBRect(self.clip.documentView.bounds),
            @"documentIsFlipped": @(self.clip.documentView.flipped), @"pdfPageCount": @(self.document.pageCount),
            @"workspacePDFVerified": @YES, @"foreground": self.foreground} name:@"driver-ready.json"];
    }
    if (self.commandAccepted) return;
    NSData *data = [NSData dataWithContentsOfFile:[self.control stringByAppendingPathComponent:@"start.json"]];
    NSDictionary *command = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![command isKindOfClass:NSDictionary.class] || ![command[@"nonce"] isEqual:self.nonce]) return;
    double duration = [command[@"durationSeconds"] isKindOfClass:NSNumber.class] ? [command[@"durationSeconds"] doubleValue] : 12;
    double speed = [command[@"pointsPerSecond"] isKindOfClass:NSNumber.class] ? [command[@"pointsPerSecond"] doubleValue] : 600;
    double hz = [command[@"inputHz"] isKindOfClass:NSNumber.class] ? [command[@"inputHz"] doubleValue] : 60;
    double delay = [command[@"startAfterSeconds"] isKindOfClass:NSNumber.class] ? [command[@"startAfterSeconds"] doubleValue] : 2;
    NSString *direction = command[@"direction"] ?: @"down";
    if (!isfinite(duration) || duration < 2 || duration > 60 || !isfinite(speed) || speed < 10 || speed > 5000 ||
        !isfinite(hz) || hz < 30 || hz > 120 || !isfinite(delay) || delay < 0 || delay > 30 ||
        ![@[@"down", @"up"] containsObject:direction]) {
        [self write:@{@"status": @"invalid-start-configuration"} name:@"driver-failure.json"]; return;
    }
    self.commandAccepted = YES; self.duration = duration; self.speed = speed; self.inputHz = hz;
    self.direction = [direction isEqual:@"down"] ? 1 : -1;
    [self write:@{@"status": @"scroll-armed", @"startAfterSeconds": @(delay), @"acceptedCommand": command} name:@"scroll-armed.json"];
    dispatch_source_cancel(self.poller); self.poller = nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self start]; });
}
- (void)start {
    if (!self.pdf || !self.clip || self.pdf.document != self.document || ![self foregroundOK]) {
        [self write:@{@"status": @"ineligible-not-foreground-or-pdf-replaced", @"foreground": self.foreground} name:@"driver-failure.json"];
        self.finished = YES; return;
    }
    self.initialOrigin = self.clip.bounds.origin;
    self.parkedPointer = NSEvent.mouseLocation;
    self.pointerMoved = NO;
    self.pointerHitsPDFAtStart = self.pointerHitsPDF;
    // Public geometry queries at the boundaries only. PDFView.currentPage can
    // remain cached after direct clip scrolling; it is not crossing evidence.
    self.initialVisiblePages = self.visiblePageNumbers; self.initialCenterPage = self.centerPageNumber;
    self.startTicks = mach_absolute_time();
    self.ticks = [NSMutableArray array];
    [self write:@{@"status": @"scroll-started", @"startMachTicks": @(self.startTicks),
        @"requestedDurationSeconds": @(self.duration), @"pointsPerSecond": @(self.speed), @"inputHz": @(self.inputHz),
        @"direction": self.direction > 0 ? @"down" : @"up", @"initialClipBounds": RBRect(self.clip.bounds),
        @"initialVisiblePDFPages": self.initialVisiblePages, @"initialCenterPDFPage": self.initialCenterPage,
        @"foreground": self.foreground} name:@"scroll-start.json"];
    self.ticker = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    uint64_t interval = (uint64_t)llround(NSEC_PER_SEC / self.inputHz);
    dispatch_source_set_timer(self.ticker, DISPATCH_TIME_NOW, interval, NSEC_PER_MSEC);
    __weak RBScrollDrive *weakSelf = self;
    dispatch_source_set_event_handler(self.ticker, ^{ [weakSelf tick]; });
    dispatch_resume(self.ticker);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((self.duration + 5) * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (!self.finished) [self write:@{@"status": @"main-thread-did-not-finish-scroll-within-deadline", @"startMachTicks": @(self.startTicks)} name:@"driver-watchdog.json"];
    });
}
- (void)tick {
    uint64_t now = mach_absolute_time(); double elapsed = (now - self.startTicks) * self.secondsPerTick;
    if (!self.pdf || !self.clip || self.pdf.document != self.document || self.clip.window != self.window) {
        [self finish:@"ineligible-pdf-or-clip-replaced"]; return;
    }
    if (![self foregroundOK]) { [self finish:@"ineligible-background"]; return; }
    if (!NSEqualPoints(NSEvent.mouseLocation, self.parkedPointer)) self.pointerMoved = YES;
    NSView *documentView = self.clip.documentView;
    double sign = (documentView.flipped ? 1 : -1) * self.direction;
    NSRect proposed = self.clip.bounds;
    proposed.origin = NSMakePoint(self.initialOrigin.x, self.initialOrigin.y + sign * self.speed * MIN(elapsed, self.duration));
    NSRect constrained = [self.clip constrainBoundsRect:proposed];
    BOOL boundary = fabs(constrained.origin.y - proposed.origin.y) > 0.5;
    [self.clip scrollToPoint:constrained.origin]; [self.scroll reflectScrolledClipView:self.clip];
    PDFPage *current = self.pdf.currentPage;
    NSUInteger page = current ? [self.document indexForPage:current] : NSNotFound;
    [self.ticks addObject:@{@"machTicks": @(now), @"afterScrollMachTicks": @(mach_absolute_time()),
        @"elapsedSeconds": @(elapsed), @"requestedY": @(proposed.origin.y), @"actualY": @(self.clip.bounds.origin.y),
        @"clipBounds": RBRect(self.clip.bounds), @"documentBounds": RBRect(documentView.bounds),
        @"currentPDFPage": page == NSNotFound ? (id)NSNull.null : @(page + 1),
        @"foreground": self.foreground, @"documentBoundaryClamped": @(boundary)}];
    if (boundary) { [self finish:@"ineligible-document-boundary"]; return; }
    if (elapsed >= self.duration) [self finish:@"completed"];
}
- (void)finish:(NSString *)status {
    uint64_t end = mach_absolute_time(); self.finished = YES;
    if (self.ticker) { dispatch_source_cancel(self.ticker); self.ticker = nil; }
    mach_timebase_info_data_t timebase; mach_timebase_info(&timebase);
    [self write:@{@"status": status, @"startMachTicks": @(self.startTicks), @"endMachTicks": @(end),
        @"timebaseNumer": @(timebase.numer), @"timebaseDenom": @(timebase.denom),
        @"requestedDurationSeconds": @(self.duration), @"actualDurationSeconds": @((end - self.startTicks) * self.secondsPerTick),
        @"pointsPerSecond": @(self.speed), @"inputHz": @(self.inputHz), @"tickCount": @(self.ticks.count),
        @"inputMethod": @"programmatic-own-process-NSClipView-scrollToPoint-and-reflectScrolledClipView",
        @"speedUnit": @"PDF-document-clip-coordinate-points-per-second",
        @"initialVisiblePDFPages": self.initialVisiblePages ?: @[], @"finalVisiblePDFPages": self.visiblePageNumbers,
        @"initialCenterPDFPage": self.initialCenterPage ?: NSNull.null, @"finalCenterPDFPage": self.centerPageNumber,
        @"pageGeometryQueriedOutsideInputInterval": @YES,
        @"pointerGuard": @{@"policy": @"stationary-and-native-hit-outside-PDF-subtree",
            @"hitsPDFAtStart": @(self.pointerHitsPDFAtStart), @"hitsPDFAtEnd": @(self.pointerHitsPDF),
            @"movedDuringInput": @(self.pointerMoved)},
        @"forcesDrawOrLayout": @NO, @"hardwareGesture": @NO, @"ticks": self.ticks ?: @[],
        @"finalForeground": self.foreground} name:@"scroll-trace.json"];
    [self write:@{@"status": status, @"intervals": @[@{@"label": @"programmatic-continuous-scroll",
        @"inputMethod": @"own-process-time-based-NSClipView-scrollToPoint", @"startMachTicks": @(self.startTicks), @"endMachTicks": @(end)}]} name:@"scroll-intervals.json"];
}
@end

static RBScrollDrive *RBDriver;
__attribute__((constructor)) static void RBInstallScrollDrive(void) {
    @autoreleasepool {
        NSDictionary *environment = NSProcessInfo.processInfo.environment;
        NSString *workspace = environment[@"READINGBOOK_SCROLL_WORKSPACE"];
        NSString *expected = environment[@"READINGBOOK_SCROLL_EXPECTED_EXECUTABLE"];
        NSString *control = environment[@"READINGBOOK_SCROLL_CONTROL"];
        NSString *nonce = environment[@"READINGBOOK_SCROLL_NONCE"];
        if (!workspace.length || !expected.length || !control.length || nonce.length < 16 || nonce.length > 128) return;
        workspace = RBCanonical(workspace); expected = RBCanonical(expected); control = RBCanonical(control);
        BOOL directory = NO;
        if (!RBInside(expected, workspace) || !RBInside(control, workspace) || ![RBExecutable() isEqual:expected] ||
            ![NSFileManager.defaultManager fileExistsAtPath:control isDirectory:&directory] || !directory) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            RBDriver = [RBScrollDrive new]; RBDriver.workspace = workspace; RBDriver.control = control;
            RBDriver.nonce = nonce; RBDriver.executable = expected; [RBDriver beginPolling];
        });
    }
}
