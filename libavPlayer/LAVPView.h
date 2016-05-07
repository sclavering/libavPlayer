#import <Cocoa/Cocoa.h>
#import "LAVPLayer.h"
#import "LAVPStream.h"

@interface LAVPView : NSView
{
    LAVPLayer* _videoLayer;
}

-(void) setStream:(LAVPStream *)newStream;

@end
