#import "LAVPView.h"

@implementation LAVPView

-(void) setMovie:(LAVPMovie *)movie {
    if(!_videoLayer) {
        [self setWantsLayer:YES];
        CALayer *rootLayer = self.layer;
        rootLayer.needsDisplayOnBoundsChange = YES;
        _videoLayer = [LAVPLayer layer];
        _videoLayer.frame = rootLayer.frame;
        _videoLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
        _videoLayer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
        [rootLayer addSublayer:_videoLayer];
    }
    _videoLayer.movie = movie;
}

@end
