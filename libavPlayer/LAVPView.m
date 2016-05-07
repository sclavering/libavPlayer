#import "LAVPView.h"

@implementation LAVPView

-(void) setStream:(LAVPStream *)newStream {
    if(!_videoLayer) {
        [self setWantsLayer:YES];
        CALayer *rootLayer = [self layer];
        rootLayer.needsDisplayOnBoundsChange = YES;
        _videoLayer = [LAVPLayer layer];
        _videoLayer.contentsGravity = kCAGravityResizeAspect;
        _videoLayer.frame = rootLayer.frame;
        _videoLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
        _videoLayer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
        [rootLayer addSublayer:_videoLayer];
    }
    [_videoLayer setStream:newStream];
}

@end
