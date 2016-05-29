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
@synthesize view;

-(void) startTimer {
    timer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(updatePos:) userInfo:nil repeats:YES];
}

-(void) stopTimer {
    if (timer) {
        [timer invalidate];
        timer = nil;
    }
}

-(void) updatePos:(NSTimer*)theTimer {
    if (viewwindow) {
        double_t pos = viewmovie.currentTimeAsFraction;
        [self setValue:[NSNumber numberWithDouble:pos] forKey:@"viewPos"];
        NSString *timeStr = formatTime(viewmovie.currentTimeInMicroseconds);
        [self setValue:[NSString stringWithFormat:@"View Window : %@ (%.3f)", timeStr, pos]
                forKey:@"viewTitle"];
    }
}

-(void) applicationDidFinishLaunching:(NSNotification *)aNotification {
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
    viewPrev = -1;
}

-(void) loadMovieAtURL:(NSURL *)url {
    if (viewmovie) [self stopTimer];

    if (viewwindow) {
        viewmovie = [[LAVPMovie alloc] initWithURL:url error:nil];
        [view setMovie:viewmovie];
    }

    if (viewmovie) [self startTimer];
}

-(BOOL) applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return NO;
}

-(void) windowWillClose:(NSNotification *)notification {
    NSWindow *obj = [notification object];
    if (obj == viewwindow) {
        NSLog(@"NOTE: viewwindow closing...");
        viewmovie = nil;
        viewwindow = nil;
        NSLog(@"NOTE: viewwindow closed.");
    }
}

-(IBAction) togglePlay:(id)sender {
    if (!viewmovie.paused) {
        viewmovie.paused = true;
    } else {
        if(viewmovie.currentTimeInMicroseconds >= viewmovie.durationInMicroseconds) viewmovie.currentTimeAsFraction = 0;
        BOOL shiftKey = [NSEvent modifierFlags] & NSShiftKeyMask ? TRUE : FALSE;
        viewmovie.playbackSpeedPercent = shiftKey ? 150 : 100;
        viewmovie.paused = false;
    }
}

-(IBAction) openDocument:(id)sender {
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

-(IBAction) rewindMovie:(id)sender {
    viewmovie.currentTimeAsFraction = 0;
}

-(IBAction) updatePosition:(id)sender {
    NSSlider *pos = (NSSlider*) sender;
    double_t newPos = [pos doubleValue];

    if ([pos window] == viewwindow) {
        if (newPos != viewPrev) {
            viewmovie.currentTimeAsFraction = newPos;
            viewPrev = newPos;
        }
    }

    SEL trackingEndedSelector = @selector(finishUpdatePosition:);
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:trackingEndedSelector object:sender];
    [self performSelector:trackingEndedSelector withObject:sender afterDelay:0.0];
}

-(void) finishUpdatePosition:(id)sender {
    viewPrev = -1;
}

@end

