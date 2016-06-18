#include "lavp_common.h"

int64_t clock_get_usec(Clock *c)
{
    if (*c->queue_serial != c->serial)
        return -1;
    if (c->paused)
        return c->pts;
    return c->pts + (av_gettime_relative() - c->last_updated) * c->speed_percent / 100;
}

void clock_set_at(Clock *c, int64_t pts, int serial, int64_t time)
{
    c->pts = pts;
    c->last_updated = time;
    c->serial = serial;
}

void clock_set(Clock *c, int64_t pts, int serial)
{
    clock_set_at(c, pts, serial, av_gettime_relative());
}

void clock_set_paused(Clock *c, bool paused) {
    // We need to save on pause and restore on resume for the clock to be accurate.  (Otherwise it'd be ahead by however long the movie had been paused for, until it next got corrected based on actual audio playback.)
    clock_set(c, clock_get_usec(c), c->serial);
    c->paused = paused;
}

void clock_set_speed(Clock *c, int speed_percent)
{
    clock_set(c, clock_get_usec(c), c->serial);
    c->speed_percent = speed_percent;
}

void clock_init(Clock *c, int *queue_serial)
{
    c->speed_percent = 100;
    c->paused = 0;
    c->queue_serial = queue_serial;
    clock_set(c, -1, -1);
}
