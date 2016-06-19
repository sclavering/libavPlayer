//  Created by Takashi Mochizuki on 11/06/18.
//  Copyright 2011 MyCometG3. All rights reserved.
/*
 This file is part of libavPlayer.

 libavPlayer is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation; either version 2 of the License, or
 (at your option) any later version.

 libavPlayer is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with libavPlayer; if not, write to the Free Software
 Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
 */

#import "LAVPMovie.h"
#import "LAVPMovie+Internal.h"

#import "lavp_core.h"
#import "lavp_common.h"
#import "lavp_video.h"
#import "lavp_audio.h"


@implementation LAVPMovie

-(instancetype) initWithURL:(NSURL *)sourceURL error:(NSError **)errorPtr {
    self = [super init];
    if(self) {
        is = stream_open(sourceURL);
        if(!is) return nil;
    }
    return self;
}

-(void) dealloc {
    [self invalidate];
}

-(void) invalidate {
    if(!is) return;
    self.paused = true;
    stream_close(is);
    is = NULL;
}

-(void) setOutput:(id<LAVPMovieOutput>)output {
    if(!is) return;
    is->weak_output = output;
}

-(NSSize) naturalSize {
    if(!is) return NSMakeSize(1, 1);
    // Use the stream aspect ratio
    AVRational sRatio = is->viddec->stream->sample_aspect_ratio;
    if(sRatio.num && sRatio.den) return NSMakeSize(is->width * sRatio.num / sRatio.den, is->height);
    // Or use the codec aspect ratio
    AVRational cRatio = is->viddec->stream->codecpar->sample_aspect_ratio;
    if(cRatio.num && cRatio.den) return NSMakeSize(is->width * cRatio.num / cRatio.den, is->height);
    return NSMakeSize(is->width, is->height);
}

// I *think* (but am not certain) that the difference from the above is that this ignores the possibility of rectangular pixels.
-(IntSize) sizeForGLTextures {
    if(!is) return (IntSize) { 1, 1 };
    return (IntSize) { is->width, is->height };
}

-(int64_t) durationInMicroseconds {
    if(!is) return 0;
    return is->ic->duration;
}

-(int64_t) currentTimeInMicroseconds {
    if(!is) return 0;
    int64_t pos = clock_get_usec(&is->audclk);
    if(pos >= 0) lastPosition = pos;
    return lastPosition;
}

-(double) currentTimeAsFraction {
    int64_t position = self.currentTimeInMicroseconds;
    int64_t duration = self.durationInMicroseconds;
    if(duration == 0) return 0;
    position = (position < 0 ? 0 : position);
    position = (position > duration ? duration : position);
    return (double)position/duration;
}

-(void) setCurrentTimeAsFraction:(double)pos {
    self.currentTimeInMicroseconds = (int64_t) (pos * self.durationInMicroseconds);
}

-(void) setCurrentTimeInMicroseconds:(int64_t)newTime {
    if(!is) return;
    if(newTime < 0) newTime = 0;
    if(newTime > self.durationInMicroseconds) newTime = self.durationInMicroseconds;
    if(is->ic->start_time != AV_NOPTS_VALUE) newTime += is->ic->start_time;
    lavp_seek(is, newTime, self.currentTimeInMicroseconds);
    // This exists because clock_get_usec() returns invalid values after seeking while paused, and we need to mask that.
    lastPosition = newTime;
}

-(BOOL) paused {
    if(!is) return true;
    return is->paused;
}

-(void) setPaused:(BOOL)shouldPause {
    if(!is) return;
    lavp_set_paused(is, shouldPause);
}

-(int) playbackSpeedPercent {
    if(!is) return 100;
    return is->playback_speed_percent;
}

-(void) setPlaybackSpeedPercent:(int)speed {
    if(!is) return;
    lavp_set_playback_speed_percent(is, speed);
}

-(int) volumePercent {
    if(!is) return 100;
    return lavp_get_volume_percent(is);
}

-(void) setVolumePercent:(int)volume {
    if(!is) return;
    lavp_set_volume_percent(is, volume);
}

-(AVFrame*) getCurrentFrame {
    if(!is) return NULL;
    return lavp_get_current_frame(is);
}

@end
