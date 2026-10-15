#include "SculptLTC.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>

struct SculptLTCDecoder {
    float bit_samples;
    int rate;
    uint64_t counter, last_edge;
    int previous_sign;
    int short_interval;
    uint8_t history[80];
    uint64_t history_count;
};

SculptLTCDecoder *sculpt_ltc_decoder_create(float sample_rate, int rate) {
    if (!(sample_rate >= 8000 && sample_rate <= 384000) || rate < 0 || rate > 3) return NULL;
    SculptLTCDecoder *d = calloc(1, sizeof(SculptLTCDecoder));
    if (!d) return NULL;
    d->rate = rate;
    float fps = rate == 0 ? 24.f : rate == 1 ? 25.f : rate == 2 ? 30000.f/1001.f : 30.f;
    d->bit_samples = sample_rate / (80.f * fps);
    return d;
}
void sculpt_ltc_decoder_destroy(SculptLTCDecoder *d) { free(d); }
void sculpt_ltc_decoder_reset(SculptLTCDecoder *d) {
    if (!d) return;
    d->counter = d->last_edge = d->history_count = 0;
    d->previous_sign = d->short_interval = 0;
    memset(d->history, 0, 80);
}

static int decode_history(SculptLTCDecoder *d, SculptLTCAddress *out) {
    if (d->history_count < 80) return 0;
    uint64_t first = d->history_count - 80;
    uint8_t b[80];
    for (int i=0; i<80; i++) b[i] = d->history[(first+i)%80];
    const uint8_t sync[16] = {0,0,1,1,1,1,1,1,1,1,1,1,1,1,0,1};
    if (memcmp(b+64, sync, 16) != 0) return 0;
    int h = (int)(b[48] | (b[49]<<1) | (b[50]<<2) | (b[51]<<3))
          + 10*(int)(b[56] | (b[57]<<1));
    int m = (int)(b[32] | (b[33]<<1) | (b[34]<<2) | (b[35]<<3))
          + 10*(int)(b[40] | (b[41]<<1) | (b[42]<<2));
    int s = (int)(b[16] | (b[17]<<1) | (b[18]<<2) | (b[19]<<3))
          + 10*(int)(b[24] | (b[25]<<1) | (b[26]<<2));
    int f = (int)(b[0] | (b[1]<<1) | (b[2]<<2) | (b[3]<<3))
          + 10*(int)(b[8] | (b[9]<<1));
    int nominal = d->rate == 0 ? 24 : d->rate == 1 ? 25 : 30;
    if (h > 23 || m > 59 || s > 59 || f >= nominal ||
        (d->rate == 2 && m%10 && s==0 && f<2)) return 0;
    int zeros = 0;
    for (int i=0; i<80; i++) zeros += b[i] == 0;
    if (zeros & 1) return 0; // Reject corrupted words.
    out->hours=h; out->minutes=m; out->seconds=s; out->frames=f;
    out->drop_frame = b[10] == 1;
    return 1;
}

static int accept_bit(SculptLTCDecoder *d, int bit, SculptLTCAddress *out) {
    d->history[d->history_count%80] = (uint8_t)bit;
    d->history_count++;
    return decode_history(d, out);
}

int sculpt_ltc_decoder_consume(SculptLTCDecoder *d, const float *samples,
                               uint32_t frame_count, SculptLTCAddress *out) {
    if (!d || !samples || !out) return 0;
    int found = 0;
    for (uint32_t i=0; i<frame_count; i++,d->counter++) {
        float x=samples[i];
        if (!isfinite(x)) continue;
        int sign = x > 0.055f ? 1 : x < -0.055f ? -1 : 0;
        if (!sign) continue;
        if (d->previous_sign == 0) {d->previous_sign=sign; d->last_edge=d->counter;continue;}
        if (sign == d->previous_sign) continue;
        d->previous_sign=sign;
        uint64_t delta=d->counter-d->last_edge;
        d->last_edge=d->counter;
        double ratio=(double)delta / (double)d->bit_samples;
        if (ratio < 0.3 || ratio > 1.65) {
            d->short_interval=0;d->history_count=0;continue;
        }
        if (ratio < 0.76) {
            if (d->short_interval) {
                d->short_interval=0;
                if (accept_bit(d,1,out)) found=1;
            } else d->short_interval=1;
        } else {
            d->short_interval=0;
            if (accept_bit(d,0,out)) found=1;
        }
    }
    return found;
}
