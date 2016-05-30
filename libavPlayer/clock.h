typedef struct Clock {
    double pts;           /* clock base */
    double last_updated;
    double speed;
    int serial;           /* clock is based on a packet with this serial */
    int paused;
    int *queue_serial;    /* pointer to the current packet queue serial, used for obsolete clock detection */
} Clock;

double get_clock(Clock *c);
void set_clock_at(Clock *c, double pts, int serial, double time);
void set_clock(Clock *c, double pts, int serial);
void clock_set_paused(Clock *c, bool paused);
void set_clock_speed(Clock *c, double speed);
void init_clock(Clock *c, int *queue_serial);
