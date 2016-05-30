#include "lavp_common.h"

double clock_get(Clock *c)
{
    if (*c->queue_serial != c->serial)
        return NAN;
    if (c->paused) {
        return c->pts;
    } else {
        double time = av_gettime_relative() / 1000000.0;
        return c->pts + (time - c->last_updated) * c->speed;
    }
}

void clock_set_at(Clock *c, double pts, int serial, double time)
{
    c->pts = pts;
    c->last_updated = time;
    c->serial = serial;
}

void clock_set(Clock *c, double pts, int serial)
{
    double time = av_gettime_relative() / 1000000.0;
    clock_set_at(c, pts, serial, time);
}

void clock_set_paused(Clock *c, bool paused) {
    // We need to save on pause and restore on resume for the clock to be accurate.  (Otherwise it'd be ahead by however long the movie had been paused for, until it next got corrected based on actual audio playback.)
    clock_set(c, clock_get(c), c->serial);
    c->paused = paused;
}

void clock_set_speed(Clock *c, double speed)
{
    clock_set(c, clock_get(c), c->serial);
    c->speed = speed;
}

void clock_init(Clock *c, int *queue_serial)
{
    c->speed = 1.0;
    c->paused = 0;
    c->queue_serial = queue_serial;
    clock_set(c, NAN, -1);
}
