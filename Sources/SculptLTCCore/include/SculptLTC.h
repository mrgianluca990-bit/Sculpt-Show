#ifndef SCULPT_LTC_H
#define SCULPT_LTC_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Single-output audio-thread-safe SMPTE LTC encoder. Never allocates/locks in render.
typedef struct SculptLTCGenerator SculptLTCGenerator;
SculptLTCGenerator *sculpt_ltc_create(void);
void sculpt_ltc_destroy(SculptLTCGenerator *g);
// rate: 0=24, 1=25, 2=30000/1001 drop, 3=30 fps.
// Caller must validate initial SMPTE frame and dedicated physical output.
void sculpt_ltc_start(SculptLTCGenerator *g, uint64_t host_start_ns,
                      int64_t first_frame, int rate, double cue_offset_seconds,
                      double start_at_seconds, double cue_duration_seconds);
void sculpt_ltc_stop(SculptLTCGenerator *g);
// start_ns is the Core Audio render buffer's host time, converted to nanoseconds.
// Silence before scheduled cue/TC onset and outside cue duration.
void sculpt_ltc_render(SculptLTCGenerator *g, uint64_t start_ns,
                       float sample_rate, float *output, uint32_t frames);
// Audio LTC receiver. Feed float PCM on a single physical input channel.
// `consume` returns 1 when a newly decoded time address is available.
typedef struct SculptLTCDecoder SculptLTCDecoder;
typedef struct {
    int hours, minutes, seconds, frames, drop_frame;
} SculptLTCAddress;
SculptLTCDecoder *sculpt_ltc_decoder_create(float sample_rate, int rate);
void sculpt_ltc_decoder_destroy(SculptLTCDecoder *d);
void sculpt_ltc_decoder_reset(SculptLTCDecoder *d);
int sculpt_ltc_decoder_consume(SculptLTCDecoder *d, const float *samples,
                               uint32_t frame_count, SculptLTCAddress *out);

// Pure helpers used in the DSP and cross-platform tests.
void sculpt_ltc_codeword(int64_t frame, int rate, uint8_t bits[80]);
float sculpt_ltc_sample(int64_t frame, int rate, double fraction);
#ifdef __cplusplus
}
#endif
#endif
