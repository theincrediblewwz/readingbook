// Actual current ScrollDrive methods with a formula-only mutant. Hidden AppKit windows; no OS input or pointer injection.
#import <AppKit/AppKit.h>
#import <PDFKit/PDFKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#include "ScrollDrive.m"

static NSPoint FixtureScreenPoint;
@interface NSEvent (RBPointerFixture)
+ (NSPoint)rb_fixtureMouseLocation;
@end
@implementation NSEvent (RBPointerFixture)
+ (NSPoint)rb_fixtureMouseLocation { return FixtureScreenPoint; }
@end

@interface RBFlippedContent : NSView
@end
@implementation RBFlippedContent
- (BOOL)isFlipped { return YES; }
@end

static NSDictionary *RBTestPoint(NSPoint point) { return @{ @"x": @(point.x), @"y": @(point.y) }; }
static NSString *HitClass(NSView *view) { return view ? NSStringFromClass(view.class) : @"<nil>"; }
static BOOL IsPDF(NSView *hit, PDFView *pdf) { return hit && (hit == pdf || [hit isDescendantOf:pdf]); }
static PDFDocument *SyntheticDocument(void) {
    NSMutableData *data = [NSMutableData data];
    CGDataConsumerRef consumer = CGDataConsumerCreateWithCFData((__bridge CFMutableDataRef)data);
    CGRect page = CGRectMake(0, 0, 612, 792);
    CGContextRef context = CGPDFContextCreate(consumer, &page, NULL);
    CGPDFContextBeginPage(context, NULL);
    CGContextSetRGBFillColor(context, 1, 1, 1, 1); CGContextFillRect(context, page);
    CGContextSetRGBFillColor(context, 0, 0, 0, 1); CGContextFillRect(context, CGRectMake(40, 600, 500, 20));
    CGPDFContextEndPage(context); CGPDFContextClose(context);
    CGContextRelease(context); CGDataConsumerRelease(consumer);
    return [[PDFDocument alloc] initWithData:data];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) { fprintf(stderr, "usage: ScrollPointerCoordinates result.json\n"); return 2; }
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        Method original = class_getClassMethod(NSEvent.class, @selector(mouseLocation));
        Method fixture = class_getClassMethod(NSEvent.class, @selector(rb_fixtureMouseLocation));
        NSPoint hardwareBefore = NSEvent.mouseLocation;
        method_exchangeImplementations(original, fixture);
        NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
        NSUInteger actualFailures = 0, oldDisagreements = 0;
        NSUInteger nonFlippedDisagreements = 0, flippedDisagreements = 0;
        BOOL windowsStayedHidden = YES, appStayedInactive = !NSApp.active;
        for (NSNumber *flippedValue in @[@NO, @YES]) {
            BOOL flipped = flippedValue.boolValue;
            NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(300, 200, 800, 600)
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
            window.releasedWhenClosed = NO; window.restorable = NO;
            NSView *content = flipped ? [[RBFlippedContent alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)]
                                      : [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
            window.contentView = content;
            CGFloat height = NSHeight(content.bounds), width = NSWidth(content.bounds), toolbarHeight = 80;
            PDFView *pdf = [[PDFView alloc] initWithFrame:NSMakeRect(0, flipped ? toolbarHeight : 0, width, height - toolbarHeight)];
            pdf.document = SyntheticDocument(); [content addSubview:pdf];
            NSView *toolbar = [[NSView alloc] initWithFrame:NSMakeRect(0, flipped ? 0 : height - toolbarHeight, width, toolbarHeight)];
            NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(20, 20, 120, 30)];
            button.title = @"Synthetic toolbar"; [toolbar addSubview:button]; [content addSubview:toolbar];
            RBScrollDrive *driver = [RBScrollDrive new]; driver.window = window; driver.pdf = pdf;
            NSArray<NSDictionary *> *cases = @[
                @{ @"name": @"pdf-center", @"point": [NSValue valueWithPoint:NSMakePoint(width / 2, NSMidY(pdf.frame))], @"expectedPDF": @YES },
                @{ @"name": @"pdf-visual-bottom", @"point": [NSValue valueWithPoint:NSMakePoint(width / 2, flipped ? height - 20 : 20)], @"expectedPDF": @YES },
                @{ @"name": @"toolbar-center", @"point": [NSValue valueWithPoint:NSMakePoint(width / 2, NSMidY(toolbar.frame))], @"expectedPDF": @NO },
                @{ @"name": @"above-content", @"point": [NSValue valueWithPoint:NSMakePoint(width / 2, flipped ? -30 : height + 30)], @"expectedPDF": @NO },
                @{ @"name": @"left-of-window", @"point": [NSValue valueWithPoint:NSMakePoint(-30, height / 2)], @"expectedPDF": @NO }
            ];
            for (NSDictionary *item in cases) {
                NSPoint knownContentPoint = [item[@"point"] pointValue];
                NSPoint windowPoint = [content convertPoint:knownContentPoint toView:nil];
                FixtureScreenPoint = [window convertPointToScreen:windowPoint];
                NSPoint observedWindowPoint = [window convertPointFromScreen:NSEvent.mouseLocation];
                // Deliberately wrong formula, evaluated only as a mutant oracle.
                // Never compile or run an archived driver variant.
                NSPoint oldPoint = [content convertPoint:observedWindowPoint fromView:nil];
                NSPoint correctPoint = [content.superview convertPoint:observedWindowPoint fromView:nil];
                NSView *oldHit = [content hitTest:oldPoint], *correctHit = [content hitTest:correctPoint];
                BOOL expected = [item[@"expectedPDF"] boolValue], correct = IsPDF(correctHit, pdf), old = IsPDF(oldHit, pdf);
                BOOL actual = driver.pointerHitsPDF;
                NSDictionary *geometry = [driver pointerGeometryAtScreenPoint:FixtureScreenPoint];
                BOOL geometryMatches = [geometry[@"available"] boolValue] && [geometry[@"hitsPDF"] boolValue] == actual
                    && [geometry[@"hitTestCoordinateSpace"] isEqual:@"content-superview"];
                windowsStayedHidden = windowsStayedHidden && !window.visible;
                appStayedInactive = appStayedInactive && !NSApp.active;
                BOOL passed = correct == expected && actual == expected && geometryMatches && !window.visible;
                if (!passed) actualFailures += 1;
                if (old != expected) { oldDisagreements += 1; if (flipped) flippedDisagreements += 1; else nonFlippedDisagreements += 1; }
                [rows addObject:@{ @"rootFlipped": @(flipped), @"case": item[@"name"], @"expectedPDF": @(expected),
                    @"actualDriverGeometry": geometry, @"actualDriverHitsPDF": @(actual), @"oldHitsPDF": @(old), @"superviewHitsPDF": @(correct), @"passed": @(passed),
                    @"screenPoint": RBTestPoint(FixtureScreenPoint), @"windowPoint": RBTestPoint(observedWindowPoint),
                    @"contentPointPassedByOld": RBTestPoint(oldPoint), @"superviewPointRequired": RBTestPoint(correctPoint),
                    @"contentFrame": RBRect(content.frame), @"contentBounds": RBRect(content.bounds), @"superviewBounds": RBRect(content.superview.bounds),
                    @"oldHitClass": HitClass(oldHit), @"superviewHitClass": HitClass(correctHit),
                    @"windowWasNeverOrderedFront": @((BOOL)!window.visible), @"nativePDFPages": @(pdf.document.pageCount) }];
            }
            [window close];
        }
        method_exchangeImplementations(original, fixture);
        NSPoint hardwareAfter = NSEvent.mouseLocation;
        for (NSWindow *window in NSApp.windows) windowsStayedHidden = windowsStayedHidden && !window.visible;
        BOOL prohibited = NSApp.activationPolicy == NSApplicationActivationPolicyProhibited;
        BOOL reproduced = nonFlippedDisagreements == 0 && flippedDisagreements == 2 && oldDisagreements == 2;
        BOOL passed = actualFailures == 0 && reproduced && rows.count == 10 && windowsStayedHidden && appStayedInactive && prohibited;
        NSDictionary *result = @{ @"mode": @"current-driver-with-formula-mutant", @"passed": @(passed), @"caseCount": @(rows.count),
            @"actualFailures": @(actualFailures), @"oldCoordinateDisagreements": @(oldDisagreements),
            @"nonFlippedOldDisagreements": @(nonFlippedDisagreements), @"flippedOldDisagreements": @(flippedDisagreements),
            @"oldBugReproduced": @(reproduced), @"hardwarePointerBefore": RBTestPoint(hardwareBefore), @"hardwarePointerAfter": RBTestPoint(hardwareAfter),
            @"systemPointerMovedByTest": @NO, @"NSEventFixtureScope": @"In this test process only; no OS event or cursor injection",
            @"activationPolicy": @"prohibited", @"activationPolicyProhibited": @(prohibited),
            @"allWindowsRemainedHidden": @(windowsStayedHidden), @"appWasNeverActive": @(appStayedInactive),
            @"mutantScope": @"Wrong formula only; current driver included directly; no archived driver executed", @"rows": rows };
        NSError *error = nil;
        NSData *encoded = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
        BOOL written = encoded && [encoded writeToFile:[NSString stringWithUTF8String:argv[1]] options:NSDataWritingAtomic error:&error];
        if (!written) { fprintf(stderr, "Result write failed: %s\n", error.localizedDescription.UTF8String); return 1; }
        printf("passed=%d cases=%lu oldFormulaDisagreements=%lu hidden=%d\n", passed,
            (unsigned long)rows.count, (unsigned long)oldDisagreements, windowsStayedHidden);
        return passed ? 0 : 1;
    }
}
