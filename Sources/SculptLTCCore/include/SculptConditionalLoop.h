#ifndef SCULPT_CONDITIONAL_LOOP_H
#define SCULPT_CONDITIONAL_LOOP_H
#include <stdint.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
// Phase: stopped=0, playing=1, paused=2, waiting=3. All changes are lock-free.
typedef struct SculptConditionalLoop SculptConditionalLoop;
typedef struct SculptPCMStream SculptPCMStream;
// Bounded immutable pages: one producer, lock-free readers. No I/O in render.
SculptPCMStream *sculpt_stream_create(int channels, int64_t frames, int64_t from);
void sculpt_stream_destroy(SculptPCMStream *s);
uint64_t sculpt_stream_bytes(const SculptPCMStream *s);
int64_t sculpt_stream_position(const SculptPCMStream *s);
bool sculpt_stream_contains(const SculptPCMStream *s, int64_t first);
bool sculpt_stream_publish(SculptPCMStream *s, int64_t first, const float *left, const float *right,
    uint32_t frames, const int64_t *keep, uint32_t keep_count);
void sculpt_stream_fail(SculptPCMStream *s);
bool sculpt_loop_stream_voice(SculptConditionalLoop *s, unsigned voice, SculptPCMStream *stream);
int sculpt_loop_failure(const SculptConditionalLoop *s);
typedef struct SculptCueSignal SculptCueSignal;
typedef struct SculptLoopSlot SculptLoopSlot;
SculptCueSignal *sculpt_signal_create(void);
void sculpt_signal_destroy(SculptCueSignal *s);
void sculpt_signal_set(SculptCueSignal *s, int phase, uint64_t start_ns, uint64_t end_ns);
void sculpt_signal_phase(SculptCueSignal *s, int phase);
void sculpt_signal_end(SculptCueSignal *s, uint64_t end_ns);
void sculpt_signal_exists(SculptCueSignal *s, bool exists);
SculptConditionalLoop *sculpt_loop_create(double rate, int64_t in_frame, int64_t out_frame,
    int64_t end_frame, SculptCueSignal *condition, int required_phase, SculptCueSignal *own);
void sculpt_loop_destroy(SculptConditionalLoop *s);
bool sculpt_loop_voice(SculptConditionalLoop *s, unsigned voice, const float *left, const float *right, int64_t frames);
void sculpt_loop_set_repeat(SculptConditionalLoop *s, bool enabled);
void sculpt_loop_arm(SculptConditionalLoop *s, uint64_t start_ns, int64_t from_frame);
// Number of OUT boundaries decided, including the final exit; shared by all voices.
uint64_t sculpt_loop_boundary_count(const SculptConditionalLoop *s);
double sculpt_loop_position_at(const SculptConditionalLoop *s, uint64_t now_ns);
// Frame-based entry point also used by deterministic audio regression tests.
void sculpt_loop_render_frames(SculptConditionalLoop *s, unsigned voice, int64_t first_frame,
    uint32_t count, float *left, float *right);
SculptLoopSlot *sculpt_loop_slot_create(unsigned voice);
void sculpt_loop_slot_destroy(SculptLoopSlot *s);
void sculpt_loop_slot_bind(SculptLoopSlot *s, SculptConditionalLoop *transport);
bool sculpt_loop_slot_busy(const SculptLoopSlot *s);
void sculpt_loop_slot_render(SculptLoopSlot *s, uint64_t host_ns, int64_t sample_frame, uint32_t count, float *left, float *right);
#ifdef __cplusplus
}
#endif
#endif
