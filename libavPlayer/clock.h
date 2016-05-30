typedef struct Clock {
    double pts;           /* clock base */
    double last_updated;
    double speed;
    int serial;           /* clock is based on a packet with this serial */
    int paused;
    int *queue_serial;    /* pointer to the current packet queue serial, used for obsolete clock detection */
} Clock;

double clock_get(Clock *c);
void clock_set_at(Clock *c, double pts, int serial, double time);
void clock_set(Clock *c, double pts, int serial);
void clock_set_paused(Clock *c, bool paused);
void clock_set_speed(Clock *c, double speed);
void clock_init(Clock *c, int *queue_serial);
