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

#import "lavp_core.h"
#import "lavp_common.h"
#import "lavp_video.h"
#import "lavp_audio.h"


@implementation LAVPMovie

-(instancetype) initWithURL:(NSURL *)sourceURL error:(NSError **)errorPtr {
    self = [super init];
    if (self) {
        is = stream_open(sourceURL);
        if (!is) return nil;
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

#pragma mark -

-(void) setOutput:(id<LAVPMovieOutput>)output {
    is->weak_output = output;
}

-(NSSize) naturalSize {
    NSSize size = NSMakeSize(is->width, is->height);
    if (is->viddec->stream && is->viddec->stream->codecpar) {
        AVRational sRatio = is->viddec->stream->sample_aspect_ratio;
        AVRational cRatio = is->viddec->stream->codecpar->sample_aspect_ratio;
        if (sRatio.num * sRatio.den) {
            // Use stream aspect ratio
            size = NSMakeSize(is->width * sRatio.num / sRatio.den, is->height);
        } else if (cRatio.num * cRatio.den) {
            // Use codec aspect ratio
            size = NSMakeSize(is->width * cRatio.num / cRatio.den, is->height);
        }
    }
    return size;
}

// I *think* (but am not certain) that the difference from the above is that this ignores the possibility of rectangular pixels.
-(NSSize) sizeForGLTextures {
    return is ? NSMakeSize(is->width, is->height) : NSMakeSize(1, 1);
}

-(int64_t) durationInMicroseconds {
    return is->ic ? is->ic->duration : 0;
}

-(int64_t) currentTimeInMicroseconds {
    if(!is || !is->ic) return 0;
    // Note: the audio clock is the master clock.
    double pos = clock_get(&is->audclk) * 1e6;
    if(!isnan(pos)) lastPosition = pos;
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
    self.currentTimeInMicroseconds = pos * self.durationInMicroseconds;
}

-(void) setCurrentTimeInMicroseconds:(int64_t)newTime {
    if(!is) return;
    if(newTime < 0) newTime = 0;
    if(newTime > self.durationInMicroseconds) newTime = self.durationInMicroseconds;
    if(is->ic) {
        if (is->ic->start_time != AV_NOPTS_VALUE) newTime += is->ic->start_time;
        lavp_seek(is, newTime, self.currentTimeInMicroseconds);
        // This exists because clock_get() returns NAN after seeking while paused, and we need to mask that.
        lastPosition = newTime;
    }
}

-(BOOL) paused {
    return is->paused;
}

-(void) setPaused:(BOOL)shouldPause {
    lavp_set_paused(is, shouldPause);
}

-(int) playbackSpeedPercent {
    if (is->ic && is->ic->duration <= 0) return 0;
    return lavp_get_playback_speed_percent(is);
}

-(void) setPlaybackSpeedPercent:(int)speed {
    if(!is || speed <= 0) return;
    if(self.playbackSpeedPercent == speed) return;
    lavp_set_playback_speed_percent(is, speed);
}

-(int) volumePercent {
    return lavp_get_volume_percent(is);
}

-(void) setVolumePercent:(int)volume {
    lavp_set_volume_percent(is, volume);
}

-(Frame*) getCurrentFrame {
    return lavp_get_current_frame(is);
}

@end
