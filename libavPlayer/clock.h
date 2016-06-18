// The clock is used to track the current time in a movie, in usec.

typedef struct Clock {
    int64_t pts;
    int64_t last_updated;
    int speed_percent;
    int serial;           /* clock is based on a packet with this serial */
    int paused;
    int *queue_serial;    /* pointer to the current packet queue serial, used for obsolete clock detection */
} Clock;

int64_t clock_get_usec(Clock *c);
void clock_set_at(Clock *c, int64_t pts, int serial, int64_t time);
void clock_set(Clock *c, int64_t pts, int serial);
void clock_set_paused(Clock *c, bool paused);
void clock_set_speed(Clock *c, int speed_percent);
void clock_init(Clock *c, int *queue_serial);
