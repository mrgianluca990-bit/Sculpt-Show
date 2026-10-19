#include "SculptConditionalLoop.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <math.h>
#include <limits.h>
#include <string.h>
#define VOICES 64
#define PAGE_FRAMES 8192
#define PAGE_COUNT 64
#define WRITING UINT_MAX
struct StreamPage { atomic_uint readers; atomic_int_fast64_t first; float *pcm; };
struct SculptPCMStream {
    int channels;
    int64_t frames;
    atomic_int_fast64_t position;
    atomic_bool failed;
    struct StreamPage pages[PAGE_COUNT];
};
SculptPCMStream *sculpt_stream_create(int channels, int64_t frames, int64_t from) {
    if ((channels != 1 && channels != 2) || frames <= 0 || from < 0) return NULL;
    SculptPCMStream *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->channels = channels; s->frames = frames;
    atomic_init(&s->position, from); atomic_init(&s->failed, false);
    for (int i = 0; i < PAGE_COUNT; ++i) {
        atomic_init(&s->pages[i].readers, 0); atomic_init(&s->pages[i].first, -1);
        s->pages[i].pcm = calloc(PAGE_FRAMES * channels, sizeof(float));
        if (!s->pages[i].pcm) { sculpt_stream_destroy(s); return NULL; }
    }
    return s;
}
void sculpt_stream_destroy(SculptPCMStream *s) {
    if (!s) return;
    for (int i = 0; i < PAGE_COUNT; ++i) free(s->pages[i].pcm);
    free(s);
}
uint64_t sculpt_stream_bytes(const SculptPCMStream *s) { return s ? PAGE_COUNT * PAGE_FRAMES * s->channels * sizeof(float) : 0; }
int64_t sculpt_stream_position(const SculptPCMStream *s) { return s ? atomic_load(&s->position) : 0; }
void sculpt_stream_fail(SculptPCMStream *s) { if (s) atomic_store(&s->failed, true); }
bool sculpt_stream_contains(const SculptPCMStream *s, int64_t first) {
    if (!s) return false;
    for (int i = 0; i < PAGE_COUNT; ++i)
        if (atomic_load(&s->pages[i].first) == first && atomic_load(&s->pages[i].readers) != WRITING) return true;
    return false;
}
bool sculpt_stream_publish(SculptPCMStream *s, int64_t first, const float *left, const float *right,
        uint32_t frames, const int64_t *keep, uint32_t count) {
    if (!s || (count && !keep) || first < 0 || first % PAGE_FRAMES || !left || frames > PAGE_FRAMES || frames == 0 ||
        first >= s->frames || frames > s->frames - first || (s->channels == 2 && !right)) return false;
    if (sculpt_stream_contains(s, first)) return true;
    for (int i = 0; i < PAGE_COUNT; ++i) {
        int64_t old = atomic_load(&s->pages[i].first);
        bool retained = false;
        for (uint32_t k = 0; k < count; ++k) if (keep[k] == old) { retained = true; break; }
        if (retained) continue;
        unsigned expected = 0;
        if (!atomic_compare_exchange_strong(&s->pages[i].readers, &expected, WRITING)) continue;
        atomic_store(&s->pages[i].first, -1);
        memcpy(s->pages[i].pcm, left, frames * sizeof(float));
        memset(s->pages[i].pcm + frames, 0, (PAGE_FRAMES - frames) * sizeof(float));
        if (s->channels == 2) {
            memcpy(s->pages[i].pcm + PAGE_FRAMES, right, frames * sizeof(float));
            memset(s->pages[i].pcm + PAGE_FRAMES + frames, 0, (PAGE_FRAMES - frames) * sizeof(float));
        }
        atomic_store(&s->pages[i].first, first);
        atomic_store(&s->pages[i].readers, 0);
        return true;
    }
    return false;
}
static int stream_pin(SculptPCMStream *s, int64_t first) {
    for (int i = 0; i < PAGE_COUNT; ++i) {
        if (atomic_load(&s->pages[i].first) != first) continue;
        unsigned n = atomic_load(&s->pages[i].readers);
        if (n == WRITING || n == WRITING - 1) continue;
        // A single bounded attempt: the render thread never waits for a writer.
        if (!atomic_compare_exchange_strong(&s->pages[i].readers, &n, n + 1)) continue;
        if (atomic_load(&s->pages[i].first) == first) return i;
        atomic_fetch_sub(&s->pages[i].readers, 1);
    }
    return -1;
}
struct SculptCueSignal {
    atomic_int phase;
    atomic_bool exists;
    atomic_uint_fast64_t start_ns, end_ns;
};
struct SculptConditionalLoop {
    double rate;
    int64_t in_frame, out_frame, end_frame, from_frame;
    uint64_t start_ns;
    SculptCueSignal *condition, *own;
    int required_phase;
    // Low bit: exit. Remaining bits: last boundary decided. Earlier decisions
    // are necessarily repeats, so all voices share one coherent decision word.
    atomic_uint_fast64_t decision;
    atomic_int_fast64_t start_sample;
    atomic_int_fast64_t last_sample;
    atomic_uint_fast64_t last_host;
    const float *left[VOICES], *right[VOICES];
    int64_t lengths[VOICES];
    SculptPCMStream *streams[VOICES];
    atomic_int failure;
};
struct SculptLoopSlot {
    unsigned voice;
    _Atomic(SculptConditionalLoop *) transport;
    atomic_bool rendering;
};
SculptCueSignal *sculpt_signal_create(void) {
    SculptCueSignal *s = calloc(1, sizeof(*s));
    if (s) { atomic_init(&s->phase, 0); atomic_init(&s->exists, true);
        atomic_init(&s->start_ns, 0); atomic_init(&s->end_ns, UINT64_MAX); }
    return s;
}
void sculpt_signal_destroy(SculptCueSignal *s) { free(s); }
void sculpt_signal_set(SculptCueSignal *s, int phase, uint64_t start, uint64_t end) {
    if (!s) return;
    atomic_store(&s->start_ns, start); atomic_store(&s->end_ns, end);
    atomic_store(&s->phase, phase);
}
void sculpt_signal_end(SculptCueSignal *s, uint64_t end) { if (s) atomic_store(&s->end_ns, end); }
void sculpt_signal_phase(SculptCueSignal *s, int phase) { if (s) atomic_store(&s->phase, phase); }
void sculpt_signal_exists(SculptCueSignal *s, bool exists) { if (s) atomic_store(&s->exists, exists); }
static bool matches(const SculptCueSignal *s, int wanted, uint64_t when) {
    if (!s || !atomic_load(&s->exists)) return false;
    int phase = atomic_load(&s->phase);
    if (phase == 1) {
        if (when < atomic_load(&s->start_ns)) phase = 3;
        else if (when >= atomic_load(&s->end_ns)) phase = 0;
    }
    return phase == wanted;
}
SculptConditionalLoop *sculpt_loop_create(double rate, int64_t in, int64_t out,
        int64_t end, SculptCueSignal *condition, int wanted, SculptCueSignal *own) {
    if (!isfinite(rate) || rate < 8000 || in < 0 || out <= in || end < out || wanted < 0 || wanted > 3) return NULL;
    SculptConditionalLoop *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->rate = rate; s->in_frame = in; s->out_frame = out; s->end_frame = end;
    s->condition = condition; s->required_phase = wanted; s->own = own;
    atomic_init(&s->failure, 0);
    atomic_init(&s->decision, 0);
    atomic_init(&s->start_sample, INT64_MIN);
    atomic_init(&s->last_sample, 0);
    atomic_init(&s->last_host, 0);
    return s;
}
void sculpt_loop_destroy(SculptConditionalLoop *s) { free(s); }
bool sculpt_loop_voice(SculptConditionalLoop *s, unsigned i, const float *left, const float *right, int64_t n) {
    if (!s || i >= VOICES || !left || n <= 0) return false;
    s->left[i] = left; s->right[i] = right; s->lengths[i] = n;
    return true;
}
bool sculpt_loop_stream_voice(SculptConditionalLoop *s, unsigned voice, SculptPCMStream *stream) {
    if (!s || voice >= VOICES || !stream) return false;
    s->streams[voice] = stream; s->lengths[voice] = stream->frames;
    return true;
}
int sculpt_loop_failure(const SculptConditionalLoop *s) { return s ? atomic_load(&s->failure) : 0; }
void sculpt_loop_arm(SculptConditionalLoop *s, uint64_t start, int64_t from) {
    if (!s) return;
    s->start_ns = start; s->from_frame = from; atomic_store(&s->decision, 0);
    atomic_store(&s->failure, 0);
    atomic_store(&s->start_sample, INT64_MIN);
    atomic_store(&s->last_host, 0);
    // A possible loop has no predetermined end. The render boundary that exits
    // it publishes the final end time, including the remaining tail.
    sculpt_signal_set(s->own, 1, start, UINT64_MAX);
}
static int64_t source_position(const SculptConditionalLoop *s, int64_t frame, uint64_t decision) {
    if (frame < s->out_frame) return frame;
    int64_t length = s->out_frame - s->in_frame;
    uint64_t cycle = (uint64_t)((frame - s->out_frame) / length) + 1;
    uint64_t decided = decision >> 1;
    if ((decision & 1) && cycle >= decided) {
        return frame - (int64_t)(decided - 1) * length;
    }
    return s->in_frame + (frame - s->out_frame) % length;
}
static uint64_t boundary_time(const SculptConditionalLoop *s, uint64_t cycle) {
    double frame = (double)s->out_frame + (double)(cycle - 1) * (double)(s->out_frame - s->in_frame);
    double delta = (frame - (double)s->from_frame) / s->rate * 1e9;
    return delta <= 0 ? s->start_ns : s->start_ns + (uint64_t)llround(delta);
}
void sculpt_loop_render_frames(SculptConditionalLoop *s, unsigned voice, int64_t first,
        uint32_t n, float *left, float *right) {
    if (!left || !right) return;
    SculptPCMStream *stream = s && voice < VOICES ? s->streams[voice] : NULL;
    int pinned = -1;
    int64_t pinned_first = -1;
    for (uint32_t i = 0; i < n; ++i) {
        float l = 0, r = 0;
        if (stream && atomic_load(&stream->failed)) atomic_store(&s->failure, 2);
        if (s && !atomic_load(&s->failure) && voice < VOICES && (s->left[voice] || stream) && first <= INT64_MAX - (int64_t)i) {
            int64_t frame = first + (int64_t)i;
            uint64_t decision = atomic_load(&s->decision);
            if (frame >= s->out_frame) {
                uint64_t cycle = (uint64_t)((frame - s->out_frame) / (s->out_frame - s->in_frame)) + 1;
                if (!(decision & 1) && (decision >> 1) < cycle) {
                    // Only one voice can publish each boundary. A later voice
                    // must use that decision even if the condition has changed.
                    uint64_t next_cycle = (decision >> 1) + 1;
                    bool repeat = matches(s->condition, s->required_phase, boundary_time(s, next_cycle));
                    uint64_t next = (next_cycle << 1) | (repeat ? 0 : 1);
                    if (atomic_compare_exchange_strong(&s->decision, &decision, next)) {
                        decision = next;
                        if (!repeat && s->own) {
                            double end = (double)s->end_frame + (double)(next_cycle - 1) * (double)(s->out_frame - s->in_frame);
                            double delta = (end - (double)s->from_frame) / s->rate * 1e9;
                            atomic_store(&s->own->end_ns, s->start_ns + (uint64_t)llround(fmax(0, delta)));
                        }
                    }
                }
            }
            int64_t position = source_position(s, frame, decision);
            if (position >= 0 && position < s->end_frame && position < s->lengths[voice]) {
                if (stream) {
                    int64_t page = position / PAGE_FRAMES * PAGE_FRAMES;
                    if (page != pinned_first) {
                        if (pinned >= 0) atomic_fetch_sub(&stream->pages[pinned].readers, 1);
                        pinned = stream_pin(stream, page); pinned_first = page;
                    }
                    if (pinned < 0) atomic_store(&s->failure, 1);
                    else {
                        l = stream->pages[pinned].pcm[position - page];
                        r = stream->channels == 2 ? stream->pages[pinned].pcm[PAGE_FRAMES + position - page] : 0;
                    }
                } else {
                    l = s->left[voice][position]; r = s->right[voice] ? s->right[voice][position] : 0;
                }
            }
        }
        left[i] = l; right[i] = r;
    }
    if (pinned >= 0) atomic_fetch_sub(&stream->pages[pinned].readers, 1);
    if (stream && n > 0 && s && first >= 0 && first < INT64_MAX - n) {
        int64_t next = source_position(s, first + n, atomic_load(&s->decision));
        atomic_store(&stream->position, next);
    }
}
double sculpt_loop_position_at(const SculptConditionalLoop *s, uint64_t now) {
    if (!s) return 0;
    int64_t frame = s->from_frame;
    uint64_t last_host = atomic_load(&s->last_host);
    int64_t anchor = atomic_load(&s->start_sample);
    if (last_host && anchor != INT64_MIN) {
        double delta = now >= last_host ? (double)(now - last_host) : -(double)(last_host - now);
        frame += atomic_load(&s->last_sample) - anchor + (int64_t)llround(delta * s->rate / 1e9);
        if (frame < s->from_frame) frame = s->from_frame;
    } else if (now > s->start_ns) frame += (int64_t)llround((double)(now - s->start_ns) * s->rate / 1e9);
    int64_t source = source_position(s, frame, atomic_load(&s->decision));
    return (double)(source < s->end_frame ? source : s->end_frame) / s->rate;
}
SculptLoopSlot *sculpt_loop_slot_create(unsigned voice) {
    if (voice >= VOICES) return NULL;
    SculptLoopSlot *s = calloc(1, sizeof(*s));
    if (s) { s->voice = voice; atomic_init(&s->transport, NULL); atomic_init(&s->rendering, false); }
    return s;
}
void sculpt_loop_slot_destroy(SculptLoopSlot *s) { free(s); }
void sculpt_loop_slot_bind(SculptLoopSlot *s, SculptConditionalLoop *t) { if (s) atomic_store(&s->transport, t); }
bool sculpt_loop_slot_busy(const SculptLoopSlot *s) { return s && atomic_load(&s->rendering); }
void sculpt_loop_slot_render(SculptLoopSlot *s, uint64_t now, int64_t sample_frame, uint32_t n, float *left, float *right) {
    if (!s) return;
    atomic_store(&s->rendering, true);
    SculptConditionalLoop *t = atomic_load(&s->transport);
    if (t) {
        int64_t anchor = atomic_load(&t->start_sample);
        if (anchor == INT64_MIN) {
            double delta = t->start_ns >= now ? (double)(t->start_ns - now) : -(double)(now - t->start_ns);
            int64_t proposed = sample_frame + (int64_t)ceil(delta * t->rate / 1e9);
            atomic_compare_exchange_strong(&t->start_sample, &anchor, proposed);
            anchor = atomic_load(&t->start_sample);
        }
        // The device sample clock, not elapsed wall time, advances audio. This
        // avoids skipped/repeated samples when the physical clock drifts.
        int64_t first = t->from_frame + sample_frame - anchor;
        atomic_store(&t->last_sample, sample_frame);
        atomic_store(&t->last_host, now);
        uint32_t silent = sample_frame < anchor ?
            (uint32_t)fmin((double)n, (double)(anchor - sample_frame)) : 0;
        for (uint32_t i = 0; i < silent; ++i) { left[i] = 0; right[i] = 0; }
        sculpt_loop_render_frames(t, s->voice, first + silent, n - silent, left + silent, right + silent);
    } else for (uint32_t i = 0; i < n; ++i) { left[i] = 0; right[i] = 0; }
    atomic_store(&s->rendering, false);
}

uint64_t sculpt_loop_boundary_count(const SculptConditionalLoop *s) {
    return s ? atomic_load(&s->decision) >> 1 : 0;
}
