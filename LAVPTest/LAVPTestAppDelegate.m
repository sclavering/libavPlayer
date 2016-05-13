//
//  LAVPTestAppDelegate.m
//  LAVPTest
//
//  Created by Takashi Mochizuki on 11/06/19.
//  Copyright 2011 MyCometG3. All rights reserved.
//

#import "LAVPTestAppDelegate.h"

NSString* formatTime(int64_t usec)
{
    int i = usec / 1000000;
    int d = i / (24*60*60);
    int h = (i - d * (24*60*60)) / (60*60);
    int m = (i - d * (24*60*60) - h * (60*60)) / 60;
    int s = (i - d * (24*60*60) - h * (60*60) - m * 60);
    int f = (usec % 1000000) / 1000;
    return [NSString stringWithFormat:@"%02d:%02d:%02d:%03d", h, m, s, f];
}

@implementation LAVPTestAppDelegate

@synthesize viewwindow;
@synthesize layerwindow;
@synthesize view;
@synthesize layerView;

- (void)startTimer
{
    timer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(updatePos:) userInfo:nil repeats:YES];
}

- (void)stopTimer
{
    if (timer) {
        [timer invalidate];
        timer = nil;
    }
}

- (void)updatePos:(NSTimer*)theTimer
{
    if (layerwindow) {
        double_t pos = layermovie.position;
        [self setValue:[NSNumber numberWithDouble:pos] forKey:@"layerPos"];
        NSString *timeStr = formatTime(layermovie.currentTimeInMicroseconds);
        [self setValue:[NSString stringWithFormat:@"Layer Window : %@ (%.3f)", timeStr, pos]
                forKey:@"layerTitle"];
    }
    if (viewwindow) {
        double_t pos = viewmovie.position;
        [self setValue:[NSNumber numberWithDouble:pos] forKey:@"viewPos"];
        NSString *timeStr = formatTime(viewmovie.currentTimeInMicroseconds);
        [self setValue:[NSString stringWithFormat:@"View Window : %@ (%.3f)", timeStr, pos]
                forKey:@"viewTitle"];
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    // Restore prev movie (on start up)
    NSURL *url = [[NSUserDefaults standardUserDefaults] URLForKey:@"url"];
    NSURL *urlDefault = [[NSBundle mainBundle] URLForResource:@"ColorBars" withExtension:@"mov"];

    BOOL shiftKey = [NSEvent modifierFlags] & NSShiftKeyMask ? TRUE : FALSE;
    if (url && !shiftKey) {
        NSError *error = NULL;
        NSFileWrapper *file = [[NSFileWrapper alloc] initWithURL:url
                                                         options:NSFileWrapperReadingImmediate
                                                           error:&error];
        if ( file ) {
            [self loadMovieAtURL:url];
            return;
        }
    }
    [self loadMovieAtURL:urlDefault];

    timer = nil;
    layerPrev = -1;
    viewPrev = -1;
}

- (void) loadMovieAtURL:(NSURL *)url
{
    if (layermovie || viewmovie) {
        [self stopTimer];
    }
#if 1
    if (viewwindow) {
        if (viewmovie) {
            viewmovie.rate = 0.0;
            [view setMovie:nil];
            viewmovie = nil;
        }

        // LAVPView test
        viewmovie = [[LAVPMovie alloc] initWithURL:url error:nil];
        [view setMovie:viewmovie];
    }
#endif

#if 1
    if (layerwindow) {
        if (layermovie) {
            layermovie.rate = 0.0;
            [layer setMovie:nil];
            layermovie = nil;
        }

        // LAVPLayer test
        layermovie = [[LAVPMovie alloc] initWithURL:url error:nil];

        //
        [layerView setWantsLayer:YES];
        CALayer *rootLayer = [layerView layer];
        rootLayer.needsDisplayOnBoundsChange = YES;

        //
        layer = [LAVPLayer layer];

    //    layer.contentsGravity = kCAGravityBottomRight;
    //    layer.contentsGravity = kCAGravityBottomLeft;
    //    layer.contentsGravity = kCAGravityTopRight;
    //    layer.contentsGravity = kCAGravityTopLeft;
    //    layer.contentsGravity = kCAGravityRight;
    //    layer.contentsGravity = kCAGravityLeft;
    //    layer.contentsGravity = kCAGravityBottom;
    //    layer.contentsGravity = kCAGravityTop;
    //    layer.contentsGravity = kCAGravityCenter;
    //    layer.contentsGravity = kCAGravityResize;
        layer.contentsGravity = kCAGravityResizeAspect;
    //    layer.contentsGravity = kCAGravityResizeAspectFill;

        layer.frame = rootLayer.frame;
    //    layer.bounds = rootLayer.bounds;
    //    layer.position = rootLayer.position;
        layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
        layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);

        //
        [layer setMovie:layermovie];
        [rootLayer addSublayer:layer];

    }
#endif
    if (layermovie || viewmovie) {
        [self startTimer];
    }
}

- (BOOL) applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    return YES;
}

- (void) windowWillClose:(NSNotification *)notification
{
    NSWindow *obj = [notification object];
    if (obj == layerwindow) {
        NSLog(@"NOTE: layerwindow closing...");
        layermovie.rate = 0.0;
        [layer setMovie:nil];
        layermovie = nil;
        layerwindow = nil;
        [layer removeFromSuperlayer];
        layer = nil;
        NSLog(@"NOTE: layerwindow closed.");
    }
    if (obj == viewwindow) {
        NSLog(@"NOTE: viewwindow closing...");
        viewmovie.rate = 0.0;
        [view setMovie:nil];
        viewmovie = nil;
        viewwindow = nil;
        NSLog(@"NOTE: viewwindow closed.");
    }
}

- (IBAction) togglePlay:(id)sender
{
    LAVPMovie *theMovie = nil;

    NSButton *button = (NSButton*) sender;
    if ([button window] == layerwindow) {
        theMovie = layermovie;
    }
    if ([button window] == viewwindow) {
        theMovie = viewmovie;
    }

    if ([theMovie rate]) {
        theMovie.rate = 0.0;
    } else {
        if(theMovie.currentTimeInMicroseconds >= theMovie.durationInMicroseconds) [theMovie setPosition:0];
        // test code for playRate support
        BOOL shiftKey = [NSEvent modifierFlags] & NSShiftKeyMask ? TRUE : FALSE;
        theMovie.rate = shiftKey ? 1.5 : 1.0;
    }
}

- (IBAction) openDocument:(id)sender
{
    // configure open sheet
    NSOpenPanel *openPanel = [NSOpenPanel openPanel];

    // build completion block
    void (^movieOpenPanelHandler)(NSInteger) = ^(NSInteger result)
    {
        if (result == NSFileHandlingPanelOKButton) {
            // Load new movie
            NSURL *newURL = [openPanel URL];
            [openPanel close];

            [[NSUserDefaults standardUserDefaults] setURL:newURL forKey:@"url"];
            [[NSUserDefaults standardUserDefaults] synchronize];

            [self loadMovieAtURL:newURL];
        }
    };

    // show sheet
    [openPanel beginSheetModalForWindow:[NSApp mainWindow] completionHandler:movieOpenPanelHandler];
}

- (IBAction) rewindMovie:(id)sender
{
    NSButton *button = (NSButton*) sender;
    if ([button window] == layerwindow) {
        [layermovie setPosition:0];
    }
    if ([button window] == viewwindow) {
        [viewmovie setPosition:0];
    }
}

- (IBAction) updatePosition:(id)sender
{
    NSSlider *pos = (NSSlider*) sender;
    double_t newPos = [pos doubleValue];

    if ([pos window] == layerwindow && !layermovie.busy) {
        if (newPos != layerPrev) {
            [layermovie setPosition:newPos];
            layerPrev = newPos;
        }
    }
    if ([pos window] == viewwindow && !viewmovie.busy) {
        if (newPos != viewPrev) {
            [viewmovie setPosition:newPos];
            viewPrev = newPos;
        }
    }

    SEL trackingEndedSelector = @selector(finishUpdatePosition:);
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:trackingEndedSelector object:sender];
    [self performSelector:trackingEndedSelector withObject:sender afterDelay:0.0];
}

- (void) finishUpdatePosition:(id)sender
{
    layerPrev = -1;
    viewPrev = -1;
}

@end

