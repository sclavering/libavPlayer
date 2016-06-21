/*
 *  Created by Takashi Mochizuki on 11/06/19.
 *  Copyright 2011 MyCometG3. All rights reserved.
 */
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

#import "lavp_core.h"
#import "lavp_video.h"
#import "packetqueue.h"
#import "lavp_audio.h"


static int audio_queue_init(VideoState *is, AVCodecContext *avctx);

/* SDL audio buffer size, in samples. Should be small to have precise
 A/V sync as SDL does not have hardware buffer fullness info. */
#define SDL_AUDIO_BUFFER_SIZE 1024


int audio_open(VideoState *is, AVCodecContext *avctx)
{
    int64_t wanted_channel_layout = avctx->channel_layout;
    int wanted_nb_channels = avctx->channels;

    if (wanted_nb_channels <= 0) wanted_nb_channels = 2;
    if (!wanted_channel_layout || wanted_nb_channels != av_get_channel_layout_nb_channels(wanted_channel_layout)) {
        wanted_channel_layout = av_get_default_channel_layout(wanted_nb_channels);
        wanted_channel_layout &= ~AV_CH_LAYOUT_STEREO_DOWNMIX;
    }

    is->audio_tgt_fmt = AV_SAMPLE_FMT_S16;
    int64_t tgt_channel_layout = wanted_channel_layout;
    is->audio_tgt_channels = wanted_nb_channels;

    is->audio_buf_size  = 0;
    is->audio_buf_index = 0;

    if (audio_queue_init(is, avctx) < 0)
        return -1;

    int64_t dec_channel_layout =
        (avctx->channel_layout && avctx->channels == av_get_channel_layout_nb_channels(avctx->channel_layout)) ?
        avctx->channel_layout : av_get_default_channel_layout(avctx->channels);

    if (avctx->sample_fmt != is->audio_tgt_fmt || dec_channel_layout != tgt_channel_layout) {
        is->swr_ctx = swr_alloc_set_opts(NULL, tgt_channel_layout, is->audio_tgt_fmt, avctx->sample_rate, dec_channel_layout, avctx->sample_fmt, avctx->sample_rate, 0, NULL);
        if (!is->swr_ctx || swr_init(is->swr_ctx) < 0) {
            av_log(NULL, AV_LOG_ERROR,
                "Cannot create sample rate converter for conversion of %d Hz %s %d channels to %d Hz %s %d channels!\n",
                avctx->sample_rate, av_get_sample_fmt_name(avctx->sample_fmt), avctx->channels,
                avctx->sample_rate, av_get_sample_fmt_name(is->audio_tgt_fmt), is->audio_tgt_channels);
            swr_free(&is->swr_ctx);
            return -1;
        }
    }

    return 0;
}

static void audio_decode_frame(VideoState *is)
{
    is->audio_buf = NULL;

    if (is->paused)
        return;

    Frame *af = decoder_peek_current_frame_blocking(is->auddec);

    if (is->swr_ctx) {
        int out_size = av_samples_get_buffer_size(NULL, is->audio_tgt_channels, af->frm_frame->nb_samples, is->audio_tgt_fmt, 0);
        if (out_size < 0) {
            av_log(NULL, AV_LOG_ERROR, "av_samples_get_buffer_size() failed\n");
            return;
        }
        av_fast_malloc(&is->audio_buf1, &is->audio_buf1_size, out_size);
        if (!is->audio_buf1)
            return;
        int len2 = swr_convert(is->swr_ctx, &is->audio_buf1, af->frm_frame->nb_samples, (const uint8_t **)af->frm_frame->extended_data, af->frm_frame->nb_samples);
        if (len2 < 0) {
            av_log(NULL, AV_LOG_ERROR, "swr_convert() failed\n");
            return;
        }
        is->audio_buf = is->audio_buf1;
        is->audio_buf_size = out_size;
        return;
    }

    is->audio_buf = af->frm_frame->data[0];
    is->audio_buf_size = av_samples_get_buffer_size(NULL, av_frame_get_channels(af->frm_frame), af->frm_frame->nb_samples, af->frm_frame->format, 1);
}

static void audio_callback(VideoState *is, AudioQueueRef aq, AudioQueueBufferRef qbuf)
{
        // Obviously this isn't really correct (it doesn't take account of the audio already buffered but not yet played), but with our callback running at 50Hz ish, it ought to be only ~20ms out, which should be OK.
        // Note: I tried using AudioQueueGetCurrentTime(), but it seemed to be running faster than it should, leading to ~500ms desync after only a minute or two of playing.  Also, it's a pain to handle seeking for (as it doesn't reset the time on seek, even if flushed), and according to random internet sources has other gotchas like the time resetting if someone plugs/unplugs headphones.
        if (!is->paused) {
            Frame *fr = decoder_peek_current_frame_blocking(is->auddec);
            if (fr && fr->frm_pts_usec > 0) clock_set(&is->audclk, fr->frm_pts_usec, fr->frm_serial);
        }

        qbuf->mAudioDataByteSize = 0;
        int len = qbuf->mAudioDataBytesCapacity;

        while (len > 0) {
            if (is->audio_buf_index >= is->audio_buf_size) {
                audio_decode_frame(is);
                if (!is->audio_buf) {
                    is->audio_buf_size = SDL_AUDIO_BUFFER_SIZE;
                } else {
                    decoder_advance_frame(is->auddec);
                }
                is->audio_buf_index = 0;
            }
            int len1 = is->audio_buf_size - is->audio_buf_index;
            if (len1 > len)
                len1 = len;
            if (is->audio_buf) {
                memcpy(qbuf->mAudioData + qbuf->mAudioDataByteSize, (uint8_t *)is->audio_buf + is->audio_buf_index, len1);
                qbuf->mAudioDataByteSize += len1;
            } else {
                // We need to output some silence because AudioQueueEnqueueBuffer() returns an error if you give it an empty buffer (and then the audio_callback isn't called again).
                // xxx And we need to output a full buffer of silence (not just a minimal amount) because otherwise we end up swamping the CPU with audio_callbacks (which can end up using >100% CPU with several open paused movies).  Honestly that's probably a bug to fix elsewhere, but do this for now.
                memset(qbuf->mAudioData + qbuf->mAudioDataByteSize, 0, qbuf->mAudioDataBytesCapacity - qbuf->mAudioDataByteSize);
                qbuf->mAudioDataByteSize = qbuf->mAudioDataBytesCapacity;
            }
            len -= len1;
            is->audio_buf_index += len1;
        }

        OSStatus err = AudioQueueEnqueueBuffer(aq, qbuf, 0, NULL);
        if (err) {
            NSString *errStr = @"kAudioQueueErr_???";
            switch (err) {
                case kAudioQueueErr_DisposalPending:
                    errStr = @"kAudioQueueErr_DisposalPending"; break;
                case kAudioQueueErr_InvalidDevice:
                    errStr = @"kAudioQueueErr_InvalidDevice"; break;
                case kAudioQueueErr_InvalidRunState:
                    errStr = @"kAudioQueueErr_InvalidRunState"; break;
                case kAudioQueueErr_QueueInvalidated:
                    errStr = @"kAudioQueueErr_QueueInvalidated"; break;
                case kAudioQueueErr_EnqueueDuringReset:
                    errStr = @"kAudioQueueErr_EnqueueDuringReset"; break;
            }
            NSLog(@"DEBUG: AudioQueueEnqueueBuffer() returned %d (%@)", err, errStr);
        }
}

static int audio_queue_init(VideoState *is, AVCodecContext *avctx)
{
    // prepare Audio stream basic description
    double inSampleRate = avctx->sample_rate;
    unsigned int inTotalBitsPerChannels = 16, inValidBitsPerChannel = 16;    // Packed
    unsigned int inChannelsPerFrame = avctx->channels;
    unsigned int inFramesPerPacket = 1;
    unsigned int inBytesPerFrame = inChannelsPerFrame * inTotalBitsPerChannels/8;
    unsigned int inBytesPerPacket = inBytesPerFrame * inFramesPerPacket;
    AudioStreamBasicDescription asbd = { 0 };
    asbd.mSampleRate = inSampleRate;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    asbd.mBytesPerPacket = inBytesPerPacket;
    asbd.mFramesPerPacket = inFramesPerPacket;
    asbd.mBytesPerFrame = inBytesPerFrame;
    asbd.mChannelsPerFrame = inChannelsPerFrame;
    asbd.mBitsPerChannel = inValidBitsPerChannel;

    is->audio_queue_num_frames_to_prepare = (int) (asbd.mSampleRate / 60); // Prepare for 1/60 sec (assuming normal playback speed).

    is->audio_dispatch_queue = dispatch_queue_create("audio", DISPATCH_QUEUE_SERIAL);
    {
        __weak VideoState* weakIs = is; // So the block doesn't keep |is| alive.
        OSStatus err = AudioQueueNewOutputWithDispatchQueue(&is->audio_queue, &asbd, 0, is->audio_dispatch_queue, ^(AudioQueueRef aq, AudioQueueBufferRef qbuf) {
            __strong VideoState* strongIs = weakIs;
            if (!strongIs || strongIs->abort_request) return;
            audio_callback(strongIs, aq, qbuf);
        });
        if (!is->audio_queue || err != 0)
            return -1;
    }

    unsigned int prop_value = 1;
    if (0 != AudioQueueSetProperty(is->audio_queue, kAudioQueueProperty_EnableTimePitch, &prop_value, sizeof(prop_value)))
        return -1;
    prop_value = kAudioQueueTimePitchAlgorithm_Spectral;
    if (0 != AudioQueueSetProperty(is->audio_queue, kAudioQueueProperty_TimePitchAlgorithm, &prop_value, sizeof(prop_value)))
        return -1;

    // prepare audio queue buffers for Output
    unsigned int buf_size = ((int) asbd.mSampleRate / 50) * asbd.mBytesPerFrame; // perform callback 50 times per sec
    for (int i = 0; i < 3; i++) {
        AudioQueueBufferRef out_buf = NULL;
        OSStatus err = AudioQueueAllocateBuffer(is->audio_queue, buf_size, &out_buf);
        assert(err == 0 && out_buf != NULL);
        memset(out_buf->mAudioData, 0, out_buf->mAudioDataBytesCapacity);
        // Enqueue dummy data to start queuing
        out_buf->mAudioDataByteSize = 8; // dummy data
        AudioQueueEnqueueBuffer(is->audio_queue, out_buf, 0, 0);
    }

    return 0;
}

void audio_queue_start(VideoState *is)
{
    if (!is->audio_queue) return;
    lavp_audio_update_speed(is);
    OSStatus err = AudioQueuePrime(is->audio_queue, is->audio_queue_num_frames_to_prepare, NULL);
    assert(err == 0);
    err = AudioQueueStart(is->audio_queue, NULL);
    assert(err == 0);
}

void audio_queue_pause(VideoState *is)
{
    if (!is->audio_queue) return;
    OSStatus err = AudioQueueFlush(is->audio_queue);
    assert(err == 0);
    err = AudioQueuePause(is->audio_queue);
    assert(err == 0);
}

void audio_queue_destroy(VideoState *is)
{
    if (!is->audio_queue) return;
    AudioQueueStop(is->audio_queue, YES);
    AudioQueueDispose(is->audio_queue, NO);
    is->audio_queue = NULL;
    if (is->audio_dispatch_queue) is->audio_dispatch_queue = NULL;
}

void lavp_audio_update_speed(VideoState *is)
{
    if (!is->audio_queue) return;
    OSStatus err = AudioQueueSetParameter(is->audio_queue, kAudioQueueParam_PlayRate, is->playback_speed_percent / 100.0f);
    assert(err == 0);
    unsigned int prop_value = (is->playback_speed_percent == 100);
    err = AudioQueueSetProperty(is->audio_queue, kAudioQueueProperty_TimePitchBypass, &prop_value, sizeof(prop_value));
    assert(err == 0);
}

int lavp_get_volume_percent(VideoState *is)
{
    return is ? is->volume_percent : 100;
}

void lavp_set_volume_percent(VideoState *is, int volume)
{
    if (!is) return;
    is->volume_percent = volume;
    if (is->audio_queue) AudioQueueSetParameter(is->audio_queue, kAudioQueueParam_Volume, volume / 100.0f);
}
