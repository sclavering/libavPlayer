#include "lavp_common.h"

int64_t clock_get_usec(MovieState *mov)
{
    if (mov->auddec->current_serial != mov->clock_serial)
        return -1;
    if (mov->paused)
        return mov->clock_pts;
    return mov->clock_pts + (av_gettime_relative() - mov->clock_last_updated) * mov->playback_speed_percent / 100;
}

void clock_set(MovieState *mov, int64_t pts, int serial)
{
    mov->clock_pts = pts;
    mov->clock_last_updated = av_gettime_relative();
    mov->clock_serial = serial;
}

void clock_preserve(MovieState *mov)
{
    // This ensures the clock is correct after pausing, unpausing, or changing speed change (all of which would invalidate the basic calculation done by clock_get_usec, for different reasons).
    clock_set(mov, clock_get_usec(mov), mov->clock_serial);
}

void clock_init(MovieState *mov)
{
    clock_set(mov, -1, -1);
}
