#include "SculptLTC.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>

struct SculptLTCGenerator {
    atomic_int active;
    atomic_ullong start_ns;
    atomic_llong first_frame;
    atomic_int rate;
    atomic_llong offset_ns;
    atomic_llong seek_ns;
    atomic_llong end_ns;
};

static void set_bcd(uint8_t b[80], int start, int length, int value) {
    for (int i=0; i<length; i++) b[start+i] = (uint8_t)((value >> i) & 1);
}

static int64_t wrapped_frame(int64_t n, int64_t daily) {
    n %= daily;
    return n < 0 ? n + daily : n;
}

void sculpt_ltc_codeword(int64_t frame, int rate, uint8_t bits[80]) {
    memset(bits, 0, 80);
    int h, m, s, f;
    if (rate == 2) {
        // SMPTE 29.97 drop-frame: skip labels 00 and 01 at every minute
        // except multiples of ten. 2,589,408 physical frames per 24 hours.
        int64_t x = wrapped_frame(frame, 2589408);
        int64_t ten = x / 17982;
        int64_t in = x % 17982;
        int64_t labels = x + ten * 18 + (in >= 2 ? 2 * ((in - 2) / 1798) : 0);
        labels %= 2592000;
        f = (int)(labels % 30); s = (int)((labels / 30) % 60);
        m = (int)((labels / 1800) % 60); h = (int)((labels / 108000) % 24);
    } else {
        int fps = rate == 0 ? 24 : rate == 1 ? 25 : 30;
        int64_t n = wrapped_frame(frame, (int64_t)fps * 86400);
        f = (int)(n % fps); s = (int)((n / fps) % 60);
        m = (int)((n / ((int64_t)fps*60)) % 60);
        h = (int)((n / ((int64_t)fps*3600)) % 24);
    }
    set_bcd(bits, 0, 4, f%10); set_bcd(bits, 8, 2, f/10);
    set_bcd(bits, 16, 4, s%10); set_bcd(bits, 24, 3, s/10);
    set_bcd(bits, 32, 4, m%10); set_bcd(bits, 40, 3, m/10);
    set_bcd(bits, 48, 4, h%10); set_bcd(bits, 56, 2, h/10);
    bits[10] = rate == 2 ? 1 : 0;
    const uint8_t sync[16] = {0,0,1,1,1,1,1,1,1,1,1,1,1,1,0,1};
    memcpy(bits+64, sync, 16);
    // SMPTE polarity correction must give an even number of 0s.
    // Parity correction is bit 59 at 25 fps, bit 27 otherwise.
    int ones = 0;
    for (int i=0; i<80; i++) ones += bits[i];
    if (ones & 1) bits[rate == 1 ? 59 : 27] = 1;
}

float sculpt_ltc_sample(int64_t frame, int rate, double fraction) {
    if (fraction < 0) fraction = 0;
    if (fraction >= 1) fraction = nextafter(1, 0);
    uint8_t bits[80]; sculpt_ltc_codeword(frame, rate, bits);
    double bitpos = fraction * 80;
    int idx = (int)bitpos;
    int flips = idx + 1;
    for (int i=0; i<idx; i++) flips += bits[i];
    if (bits[idx] && bitpos - idx >= 0.5) flips++;
    // 0.251 = -12 dBFS; LTC level can be handled as line-level downstream.
    return (flips & 1) ? -0.25118864f : 0.25118864f;
}

SculptLTCGenerator *sculpt_ltc_create(void) {
    return calloc(1, sizeof(SculptLTCGenerator));
}
void sculpt_ltc_destroy(SculptLTCGenerator *g) { if (g) free(g); }
void sculpt_ltc_stop(SculptLTCGenerator *g) { if (g) atomic_store_explicit(&g->active, 0, memory_order_release); }

void sculpt_ltc_start(SculptLTCGenerator *g, uint64_t host_start_ns,
                      int64_t first_frame, int rate, double cue_offset_seconds,
                      double start_at_seconds, double cue_duration_seconds) {
    if (!g) return;
    atomic_store_explicit(&g->active, 0, memory_order_release);
    atomic_store(&g->start_ns, host_start_ns);
    atomic_store(&g->first_frame, first_frame);
    atomic_store(&g->rate, rate);
    atomic_store(&g->offset_ns, (int64_t)llround(fmax(0, cue_offset_seconds)*1e9));
    atomic_store(&g->seek_ns, (int64_t)llround(fmax(0, start_at_seconds)*1e9));
    atomic_store(&g->end_ns, (int64_t)llround(fmax(0, cue_duration_seconds)*1e9));
    atomic_store_explicit(&g->active, 1, memory_order_release);
}

void sculpt_ltc_render(SculptLTCGenerator *g, uint64_t start_ns,
                       float sample_rate, float *output, uint32_t frames) {
    if (!output) return;
    if (!g || !atomic_load_explicit(&g->active, memory_order_acquire) ||
        sample_rate <= 0 || start_ns == 0) {
        memset(output, 0, (size_t)frames * sizeof(float)); return;
    }
    uint64_t t0=atomic_load(&g->start_ns);
    int64_t first=atomic_load(&g->first_frame);
    int rate=atomic_load(&g->rate);
    int64_t offset=atomic_load(&g->offset_ns);
    int64_t seek=atomic_load(&g->seek_ns);
    int64_t end=atomic_load(&g->end_ns);
    const double fps = rate == 0 ? 24.0 : rate == 1 ? 25.0 : rate == 2 ? 30000.0/1001.0 : 30.0;
    // Buffer host timestamp belongs to the SAME Core Audio output timeline
    // used by AVAudioPlayerNode.play(atTime:), so no UI timer drives LTC.
    double firstNs = (double)((int64_t)start_ns - (int64_t)t0) + (double)seek;
    double nsPerSample = 1e9 / sample_rate;
    int64_t cachedFrame = -1;
    uint8_t b[80] = {0};
    int signByHalf[160] = {0};
    for (uint32_t i=0; i<frames; i++) {
        double cueNs = firstNs + (double)i * nsPerSample;
        if (cueNs < (double)offset || cueNs < 0 || cueNs >= (double)end) {
            output[i] = 0; continue;
        }
        double elapsedFrames = ((cueNs - (double)offset) / 1e9) * fps;
        double integral;
        double frac = modf(elapsedFrames, &integral);
        int64_t frame = first + (int64_t)integral;
        if (frame != cachedFrame) {
            sculpt_ltc_codeword(frame, rate, b);
            int flips = 0;
            for (int bit=0; bit<80; bit++) {
                flips++;
                signByHalf[bit*2] = (flips & 1) ? -1 : 1;
                if (b[bit]) flips++;
                signByHalf[bit*2+1] = (flips & 1) ? -1 : 1;
            }
            cachedFrame = frame;
        }
        int slot = (int)(frac * 160);
        if (slot < 0) slot = 0;
        if (slot > 159) slot = 159;
        output[i] = 0.25118864f * signByHalf[slot];
    }
}
