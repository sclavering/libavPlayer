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

#import "MovieState.h"
#import "decoder.h"


static void audio_callback(MovieState *mov, AudioQueueRef aq, AudioQueueBufferRef qbuf);
static int32_t audio_format_flags_from_sample_format(enum AVSampleFormat fmt);
static AudioChannelLabel convert_channel_label(uint64_t av_ch);


int audio_open(MovieState *mov, AVCodecContext *avctx)
{
    // Note: per the docs for AudioQueueNewOutput(), non-interleaved (a.k.a. planar) linear-PCM audio is **not supported**.  Thus we must always convert to interleaved (a.k.a. packed) (rather unfortunately, as most movies seem to use planar).
    mov->audio_tgt_fmt = av_get_packed_sample_fmt(avctx->sample_fmt);
    mov->audio_buf_size = 0;

    mov->audio_needs_interleaving = (avctx->sample_fmt != mov->audio_tgt_fmt);

    AudioStreamBasicDescription asbd = { 0 };
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mSampleRate = avctx->sample_rate;
    asbd.mFramesPerPacket = 1;
    asbd.mChannelsPerFrame = avctx->channels;
    asbd.mFormatFlags = audio_format_flags_from_sample_format(mov->audio_tgt_fmt);
    int bytes_per_sample = av_get_bytes_per_sample(mov->audio_tgt_fmt);
    asbd.mBytesPerFrame = avctx->channels * bytes_per_sample;
    asbd.mBitsPerChannel = bytes_per_sample * 8;
    asbd.mBytesPerPacket = asbd.mBytesPerFrame;

    mov->audio_dispatch_queue = dispatch_queue_create("audio", DISPATCH_QUEUE_SERIAL);
    {
        __weak MovieState* weak_mov = mov;
        OSStatus err = AudioQueueNewOutputWithDispatchQueue(&mov->audio_queue, &asbd, 0, mov->audio_dispatch_queue, ^(AudioQueueRef aq, AudioQueueBufferRef qbuf) {
            __strong MovieState* strong_mov = weak_mov;
            if (!strong_mov || strong_mov->abort_request) return;
            audio_callback(strong_mov, aq, qbuf);
        });
        if (!mov->audio_queue || err != 0)
            return -1;
    }

    // If we have more than two channels, we need to tell the AudioQueue what they are and what order they're in.
    if (avctx->channels > 2) {
        size_t sz = sizeof(AudioChannelLayout) + sizeof(AudioChannelDescription) * (avctx->channels - 1);
        mov->audio_channel_layout = malloc(sz);
        mov->audio_channel_layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
        mov->audio_channel_layout->mChannelBitmap = 0;
        mov->audio_channel_layout->mNumberChannelDescriptions = avctx->channels;
        for (int i = 0; i < avctx->channels; ++i) {
            // Note: ffmpeg's channel_layout is just a bitmap, because it apparently always stores channels in the same order.
            uint64_t av_ch = av_channel_layout_extract_channel(avctx->channel_layout, i);
            mov->audio_channel_layout->mChannelDescriptions[i].mChannelLabel = convert_channel_label(av_ch);
        }
        if (0 != AudioQueueSetProperty(mov->audio_queue, kAudioQueueProperty_ChannelLayout, mov->audio_channel_layout, sz))
            return -1;
    }

    unsigned int prop_value = 1;
    if (0 != AudioQueueSetProperty(mov->audio_queue, kAudioQueueProperty_EnableTimePitch, &prop_value, sizeof(prop_value)))
        return -1;
    prop_value = kAudioQueueTimePitchAlgorithm_Spectral;
    if (0 != AudioQueueSetProperty(mov->audio_queue, kAudioQueueProperty_TimePitchAlgorithm, &prop_value, sizeof(prop_value)))
        return -1;

    unsigned int buf_size = ((int) asbd.mSampleRate / 50) * asbd.mBytesPerFrame; // perform callback 50 times per sec
    for (int i = 0; i < 3; i++) {
        AudioQueueBufferRef out_buf = NULL;
        OSStatus err = AudioQueueAllocateBuffer(mov->audio_queue, buf_size, &out_buf);
        assert(err == 0 && out_buf != NULL);
        memset(out_buf->mAudioData, 0, out_buf->mAudioDataBytesCapacity);
        // Enqueue dummy data to start queuing
        out_buf->mAudioDataByteSize = 8; // dummy data
        AudioQueueEnqueueBuffer(mov->audio_queue, out_buf, 0, NULL);
    }

    return 0;
}

static int32_t audio_format_flags_from_sample_format(enum AVSampleFormat fmt)
{
    int32_t flags = 0;
    flags |= kAudioFormatFlagIsPacked;
    flags |= kAudioFormatFlagsNativeEndian; // ffmpeg docs say it always uses native endian
    switch (fmt) {
        case AV_SAMPLE_FMT_FLT:
        case AV_SAMPLE_FMT_DBL:
        case AV_SAMPLE_FMT_FLTP:
        case AV_SAMPLE_FMT_DBLP:
            flags |= kAudioFormatFlagIsFloat;
            break;
        case AV_SAMPLE_FMT_S16:
        case AV_SAMPLE_FMT_S32:
        case AV_SAMPLE_FMT_S16P:
        case AV_SAMPLE_FMT_S32P:
            flags |= kAudioFormatFlagIsSignedInteger;
            break;
        default:
            break;
    }
    return flags;
}

static AudioChannelLabel convert_channel_label(uint64_t av_ch)
{
    switch (av_ch) {
        // Note: these mappings are mostly based on how GStreamer maps its own channel labels to/from AV_CH_* and kAudioChannelLabel_*, plus a little guesswork.
        case AV_CH_FRONT_LEFT: return kAudioChannelLabel_Left;
        case AV_CH_FRONT_RIGHT: return kAudioChannelLabel_Right;
        case AV_CH_FRONT_CENTER: return kAudioChannelLabel_Center;
        case AV_CH_LOW_FREQUENCY: return kAudioChannelLabel_LFEScreen;
        case AV_CH_BACK_LEFT: return kAudioChannelLabel_RearSurroundLeft;
        case AV_CH_BACK_RIGHT: return kAudioChannelLabel_RearSurroundRight;
        case AV_CH_FRONT_LEFT_OF_CENTER: return kAudioChannelLabel_LeftCenter;
        case AV_CH_FRONT_RIGHT_OF_CENTER: return kAudioChannelLabel_RightCenter;
        case AV_CH_BACK_CENTER: return kAudioChannelLabel_CenterSurround;
        case AV_CH_SIDE_LEFT: return kAudioChannelLabel_LeftSurround;
        case AV_CH_SIDE_RIGHT: return kAudioChannelLabel_RightSurround;
        case AV_CH_TOP_CENTER: return kAudioChannelLabel_TopCenterSurround;
        case AV_CH_TOP_FRONT_LEFT: return kAudioChannelLabel_VerticalHeightLeft;
        case AV_CH_TOP_FRONT_CENTER: return kAudioChannelLabel_VerticalHeightCenter;
        case AV_CH_TOP_FRONT_RIGHT: return kAudioChannelLabel_VerticalHeightRight;
        case AV_CH_TOP_BACK_LEFT: return kAudioChannelLabel_TopBackLeft;
        case AV_CH_TOP_BACK_CENTER: return kAudioChannelLabel_TopBackCenter;
        case AV_CH_TOP_BACK_RIGHT: return kAudioChannelLabel_TopBackRight;
        case AV_CH_STEREO_LEFT: return kAudioChannelLabel_Left;
        case AV_CH_STEREO_RIGHT: return kAudioChannelLabel_Right;
        case AV_CH_WIDE_LEFT: return kAudioChannelLabel_LeftWide;
        case AV_CH_WIDE_RIGHT: return kAudioChannelLabel_RightWide;
        case AV_CH_SURROUND_DIRECT_LEFT: return kAudioChannelLabel_LeftSurroundDirect;
        case AV_CH_SURROUND_DIRECT_RIGHT: return kAudioChannelLabel_RightSurroundDirect;
        case AV_CH_LOW_FREQUENCY_2: return kAudioChannelLabel_LFE2;
        // Surprisingly unused values:
        // kAudioChannelLabel_LeftTotal
        // kAudioChannelLabel_RightTotal
        // kAudioChannelLabel_CenterSurroundDirect
    }
    return kAudioChannelLabel_Unused;
}

static void audio_convert_to_interleaved(uint8_t *output_buf, AVFrame *af)
{
    int nb_samples = af->nb_samples;
    int samp_size = av_get_bytes_per_sample(af->format);
    int channels = af->channels;
    for (int s = 0; s < nb_samples; ++s) {
        for (int ch = 0; ch < channels; ++ch) {
            memcpy(output_buf + (s * channels + ch) * samp_size, af->extended_data[ch] + s * samp_size, samp_size);
        }
    }
}

static void audio_decode_frame(MovieState *mov, AVFrame *af)
{
    mov->audio_buf = NULL;
    mov->audio_buf_size = 0;

    if (mov->audio_needs_interleaving) {
        int out_size = av_samples_get_buffer_size(NULL, af->channels, af->nb_samples, mov->audio_tgt_fmt, 0);
        if (out_size < 0) {
            NSLog(@"libavPlayer: av_samples_get_buffer_size() failed");
            return;
        }
        av_fast_malloc(&mov->audio_buf1, &mov->audio_buf1_size, out_size);
        if (!mov->audio_buf1)
            return;
        audio_convert_to_interleaved(mov->audio_buf1, af);
        mov->audio_buf = mov->audio_buf1;
        mov->audio_buf_size = out_size;
        return;
    }

    // xxx this really needs to be memcpy()'d, since we free the AVFrame soon after returning.  Except that interleaved audio is really rare, so it's fairly irrelevant in practice.
    mov->audio_buf = af->data[0];
    mov->audio_buf_size = av_samples_get_buffer_size(NULL, av_frame_get_channels(af), af->nb_samples, af->format, 1);
}

static void audio_callback(MovieState *mov, AudioQueueRef aq, AudioQueueBufferRef qbuf)
{
    qbuf->mAudioDataByteSize = 0;
    while (qbuf->mAudioDataBytesCapacity - qbuf->mAudioDataByteSize > 0) {
        if (mov->audio_buf_size <= 0) {
            Frame *fr = decoder_peek_current_frame_blocking(mov->auddec, mov);
            if (!fr) return; // ->abort_request must have been set

            // Obviously this isn't really correct (it doesn't take account of the audio already buffered but not yet played), but with our callback running at 50Hz ish, it ought to be only ~20ms out, which should be OK.
            // Note: I tried using AudioQueueGetCurrentTime(), but it seemed to be running faster than it should, leading to ~500ms desync after only a minute or two of playing.  Also, it's a pain to handle seeking for (as it doesn't reset the time on seek, even if flushed), and according to random internet sources has other gotchas like the time resetting if someone plugs/unplugs headphones.
            if (!mov->paused) clock_set(mov, fr->frm_pts_usec);

            audio_decode_frame(mov, fr->frm_frame);
            if (!mov->audio_buf) return; // something really weird went wrong

            decoder_advance_frame(mov->auddec, mov);
        }
        int len1 = MIN(mov->audio_buf_size, qbuf->mAudioDataBytesCapacity - qbuf->mAudioDataByteSize);
        memcpy(qbuf->mAudioData + qbuf->mAudioDataByteSize, mov->audio_buf, len1);
        qbuf->mAudioDataByteSize += len1;
        mov->audio_buf += len1;
        mov->audio_buf_size -= len1;
    }

    OSStatus err = AudioQueueEnqueueBuffer(aq, qbuf, 0, NULL);
    if (err) NSLog(@"libavPlayer: error from AudioQueueEnqueueBuffer(): %d", err);
}

void audio_queue_set_paused(MovieState *mov, bool pause)
{
    if (!mov->audio_queue) return;
    if (pause) AudioQueuePause(mov->audio_queue);
    else AudioQueueStart(mov->audio_queue, NULL);
}

void audio_queue_destroy(MovieState *mov)
{
    if (!mov->audio_queue) return;
    AudioQueueStop(mov->audio_queue, YES);
    AudioQueueDispose(mov->audio_queue, NO);
    mov->audio_queue = NULL;
    mov->audio_dispatch_queue = NULL;
    free(mov->audio_channel_layout);
    mov->audio_channel_layout = NULL;
}

void lavp_audio_update_speed(MovieState *mov)
{
    if (!mov->audio_queue) return;
    OSStatus err = AudioQueueSetParameter(mov->audio_queue, kAudioQueueParam_PlayRate, mov->playback_speed_percent / 100.0f);
    assert(err == 0);
    unsigned int prop_value = (mov->playback_speed_percent == 100);
    err = AudioQueueSetProperty(mov->audio_queue, kAudioQueueProperty_TimePitchBypass, &prop_value, sizeof(prop_value));
    assert(err == 0);
}

void lavp_set_volume_percent(MovieState *mov, int volume)
{
    mov->volume_percent = volume;
    if (mov->audio_queue) AudioQueueSetParameter(mov->audio_queue, kAudioQueueParam_Volume, volume / 100.0f);
}
