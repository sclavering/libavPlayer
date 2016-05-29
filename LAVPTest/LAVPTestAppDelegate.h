//
//  LAVPTestAppDelegate.h
//  LAVPTest
//
//  Created by Takashi Mochizuki on 11/06/19.
//  Copyright 2011 MyCometG3. All rights reserved.
//

@import Cocoa;

#import <libavPlayer/libavPlayer.h>

@interface LAVPTestAppDelegate : NSObject <NSApplicationDelegate> {
    LAVPMovie *viewmovie;
    double_t viewPos;
    NSString *viewTitle;
    NSTimer *timer;
    double_t viewPrev;
}

@property (unsafe_unretained) IBOutlet NSWindow *viewwindow;
@property (unsafe_unretained) IBOutlet LAVPView *view;

-(void) loadMovieAtURL:(NSURL *)url;

-(IBAction) togglePlay:(id)sender;
-(IBAction) rewindMovie:(id)sender;
-(IBAction) updatePosition:(id)sender;

@end
