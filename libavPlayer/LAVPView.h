#import <Cocoa/Cocoa.h>
#import "LAVPLayer.h"
#import "LAVPMovie.h"

@interface LAVPView : NSView
{
    LAVPLayer* _videoLayer;
}

-(void) setMovie:(LAVPMovie *)movie;

@end
