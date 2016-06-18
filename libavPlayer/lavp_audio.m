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


static int audio_decode_frame(VideoState *is);
static void audio_queue_init(VideoState *is, AVCodecContext *avctx);

/* SDL audio buffer size, in samples. Should be small to have precise
 A/V sync as SDL does not have hardware buffer fullness info. */
#define SDL_AUDIO_BUFFER_SIZE 1024


int audio_open(VideoState *is, AVCodecContext *avctx)
{
    int64_t wanted_channel_layout = avctx->channel_layout;
    int wanted_nb_channels = avctx->channels;
    int wanted_sample_rate = avctx->sample_rate;

    if (wanted_sample_rate <= 0) wanted_sample_rate = 48000;
    if (wanted_nb_channels <= 0) wanted_nb_channels = 2;
    if (!wanted_channel_layout || wanted_nb_channels != av_get_channel_layout_nb_channels(wanted_channel_layout)) {
        wanted_channel_layout = av_get_default_channel_layout(wanted_nb_channels);
        wanted_channel_layout &= ~AV_CH_LAYOUT_STEREO_DOWNMIX;
    }

    is->audio_tgt.fmt = AV_SAMPLE_FMT_S16;
    is->audio_tgt.freq = wanted_sample_rate;
    is->audio_tgt.channel_layout = wanted_channel_layout;
    is->audio_tgt.channels = wanted_nb_channels;
    is->audio_tgt.frame_size = av_samples_get_buffer_size(NULL, is->audio_tgt.channels, 1, is->audio_tgt.fmt, 1);
    is->audio_tgt.bytes_per_sec = av_samples_get_buffer_size(NULL, is->audio_tgt.channels, is->audio_tgt.freq, is->audio_tgt.fmt, 1);
    if (is->audio_tgt.bytes_per_sec <= 0 || is->audio_tgt.frame_size <= 0) {
        av_log(NULL, AV_LOG_ERROR, "av_samples_get_buffer_size failed\n");
        return -1;
    }

    is->audio_hw_buf_size = SDL_AUDIO_BUFFER_SIZE * is->audio_tgt.channels * av_get_bytes_per_sample(is->audio_tgt.fmt);
    AudioParams audio_src = is->audio_tgt;
    is->audio_buf_size  = 0;
    is->audio_buf_index = 0;

    audio_queue_init(is, avctx);

    int64_t dec_channel_layout =
        (avctx->channel_layout && avctx->channels == av_get_channel_layout_nb_channels(avctx->channel_layout)) ?
        avctx->channel_layout : av_get_default_channel_layout(avctx->channels);

    if (avctx->sample_fmt != audio_src.fmt || dec_channel_layout != audio_src.channel_layout || avctx->sample_rate != audio_src.freq)
    {
        is->swr_ctx = swr_alloc_set_opts(NULL, is->audio_tgt.channel_layout, is->audio_tgt.fmt, is->audio_tgt.freq, dec_channel_layout, avctx->sample_fmt, avctx->sample_rate, 0, NULL);
        if (!is->swr_ctx || swr_init(is->swr_ctx) < 0) {
            av_log(NULL, AV_LOG_ERROR,
                "Cannot create sample rate converter for conversion of %d Hz %s %d channels to %d Hz %s %d channels!\n",
                avctx->sample_rate, av_get_sample_fmt_name(avctx->sample_fmt), avctx->channels,
                is->audio_tgt.freq, av_get_sample_fmt_name(is->audio_tgt.fmt), is->audio_tgt.channels);
            swr_free(&is->swr_ctx);
            return -1;
        }
    }

    return 0;
}

// Decode one audio frame (converting if required), store it in is->audio_buf, and return its uncompressed size in bytes (or negative on error).
int audio_decode_frame(VideoState *is)
{
    if (is->paused)
        return -1;

    Frame *af;
    do {
        if (!(af = decoder_peek_current_frame_blocking(is->auddec)))
            return -1;
        decoder_advance_frame(is->auddec);
    } while (af->frm_serial != is->auddec->current_serial);

    int data_size = av_samples_get_buffer_size(NULL, av_frame_get_channels(af->frm_frame), af->frm_frame->nb_samples, af->frm_frame->format, 1);

    int resampled_data_size;
    if (is->swr_ctx) {
        const uint8_t **in = (const uint8_t **)af->frm_frame->extended_data;
        uint8_t **out = &is->audio_buf1;
        int out_count = (int64_t)af->frm_frame->nb_samples * is->audio_tgt.freq / af->frm_frame->sample_rate + 256;
        int out_size  = av_samples_get_buffer_size(NULL, is->audio_tgt.channels, out_count, is->audio_tgt.fmt, 0);
        if (out_size < 0) {
            av_log(NULL, AV_LOG_ERROR, "av_samples_get_buffer_size() failed\n");
            return -1;
        }
        av_fast_malloc(&is->audio_buf1, &is->audio_buf1_size, out_size);
        if (!is->audio_buf1)
            return AVERROR(ENOMEM);
        int len2 = swr_convert(is->swr_ctx, out, out_count, in, af->frm_frame->nb_samples);
        if (len2 < 0) {
            av_log(NULL, AV_LOG_ERROR, "swr_convert() failed\n");
            return -1;
        }
        if (len2 == out_count) {
            av_log(NULL, AV_LOG_WARNING, "audio buffer is probably too small\n");
            if (swr_init(is->swr_ctx) < 0) swr_free(&is->swr_ctx);
        }
        is->audio_buf = is->audio_buf1;
        resampled_data_size = len2 * is->audio_tgt.channels * av_get_bytes_per_sample(is->audio_tgt.fmt);
    } else {
        is->audio_buf = af->frm_frame->data[0];
        resampled_data_size = data_size;
    }

    /* update the audio clock with the pts */
    if (!isnan(af->frm_pts))
        is->audio_clock = af->frm_pts + (double) af->frm_frame->nb_samples / af->frm_frame->sample_rate;
    else
        is->audio_clock = NAN;
    is->audio_clock_serial = af->frm_serial;
    return resampled_data_size;
}

static void audio_callback(VideoState *is, AudioQueueRef aq, AudioQueueBufferRef qbuf)
{
        qbuf->mAudioDataByteSize = 0;
        int len = qbuf->mAudioDataBytesCapacity;

        int64_t audio_callback_time = av_gettime_relative();

        while (len > 0) {
            if (is->audio_buf_index >= is->audio_buf_size) {
                int audio_size = audio_decode_frame(is);
                if (audio_size < 0) {
                    /* if error, just output silence */
                    is->audio_buf = NULL;
                    is->audio_buf_size = SDL_AUDIO_BUFFER_SIZE;
                } else {
                    is->audio_buf_size = audio_size;
                }
                is->audio_buf_index = 0;
            }
            int len1 = is->audio_buf_size - is->audio_buf_index;
            if (len1 > len)
                len1 = len;
            if (is->audio_buf)
                memcpy(qbuf->mAudioData + qbuf->mAudioDataByteSize, (uint8_t *)is->audio_buf + is->audio_buf_index, len1);
            len -= len1;
            qbuf->mAudioDataByteSize += len1;
            is->audio_buf_index += len1;
        }

        /* Let's assume the audio driver that is used by SDL has two periods. */
        if (!isnan(is->audio_clock)) {
            unsigned int audio_write_buf_size = is->audio_buf_size - is->audio_buf_index;
            clock_set_at(&is->audclk, is->audio_clock - (double)(2 * is->audio_hw_buf_size + audio_write_buf_size) / is->audio_tgt.bytes_per_sec, is->audio_clock_serial, audio_callback_time / 1000000.0);
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

static void audio_queue_init(VideoState *is, AVCodecContext *avctx)
{
    // prepare Audio stream basic description
    double inSampleRate = avctx->sample_rate;
    unsigned int inTotalBitsPerChannels = 16, inValidBitsPerChannel = 16;    // Packed
    unsigned int inChannelsPerFrame = avctx->channels;
    unsigned int inFramesPerPacket = 1;
    unsigned int inBytesPerFrame = inChannelsPerFrame * inTotalBitsPerChannels/8;
    unsigned int inBytesPerPacket = inBytesPerFrame * inFramesPerPacket;
    AudioStreamBasicDescription asbd;
    memset(&asbd, 0, sizeof(AudioStreamBasicDescription));
    asbd.mSampleRate = inSampleRate;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    asbd.mBytesPerPacket = inBytesPerPacket;
    asbd.mFramesPerPacket = inFramesPerPacket;
    asbd.mBytesPerFrame = inBytesPerFrame;
    asbd.mChannelsPerFrame = inChannelsPerFrame;
    asbd.mBitsPerChannel = inValidBitsPerChannel;

    is->audio_queue_num_frames_to_prepare = asbd.mSampleRate / 60; // Prepare for 1/60 sec (assuming normal playback speed).

    // prepare AudioQueue for Output
    OSStatus err = 0;
    AudioQueueRef audio_queue = NULL;

    if (!is->audio_dispatch_queue) {
        __weak VideoState* weakIs = is; // So the block doesn't keep |is| alive.
        void (^audioCallbackBlock)() = ^(AudioQueueRef aq, AudioQueueBufferRef qbuf) {
            __strong VideoState* strongIs = weakIs;
            /* AudioQueue Callback should be ignored when closing */
            if (!strongIs || strongIs->abort_request) return;
            audio_callback(strongIs, aq, qbuf);
        };

        is->audio_dispatch_queue = dispatch_queue_create("audio", DISPATCH_QUEUE_SERIAL);
        err = AudioQueueNewOutputWithDispatchQueue(&audio_queue, &asbd, 0, is->audio_dispatch_queue, audioCallbackBlock);
    }

    assert(err == 0 && audio_queue != NULL);
    is->audio_queue = audio_queue;

    unsigned int prop_value = 1;
    err = AudioQueueSetProperty(is->audio_queue, kAudioQueueProperty_EnableTimePitch, &prop_value, sizeof(prop_value));
    assert(err == 0);
    prop_value = kAudioQueueTimePitchAlgorithm_Spectral;
    err = AudioQueueSetProperty(is->audio_queue, kAudioQueueProperty_TimePitchAlgorithm, &prop_value, sizeof(prop_value));
    assert(err == 0);

    // prepare audio queue buffers for Output
    unsigned int buf_size = (asbd.mSampleRate / 50) * asbd.mBytesPerFrame; // perform callback 50 times per sec
    for (int i = 0; i < 3; i++) {
        AudioQueueBufferRef out_buf = NULL;
        err = AudioQueueAllocateBuffer(is->audio_queue, buf_size, &out_buf);
        assert(err == 0 && out_buf != NULL);
        memset(out_buf->mAudioData, 0, out_buf->mAudioDataBytesCapacity);
        // Enqueue dummy data to start queuing
        out_buf->mAudioDataByteSize = 8; // dummy data
        AudioQueueEnqueueBuffer(is->audio_queue, out_buf, 0, 0);
    }
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
