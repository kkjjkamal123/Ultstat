#include "cprivate.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct IOReportSubscriptionRef *IOReportSubscriptionRef;
typedef CFDictionaryRef IOReportSampleRef;

extern CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef group, CFStringRef subgroup, uint64_t a, uint64_t b, uint64_t c);
extern IOReportSubscriptionRef IOReportCreateSubscription(void *a, CFMutableDictionaryRef desired, CFMutableDictionaryRef *subbed, uint64_t channel, CFTypeRef b);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef sub, CFMutableDictionaryRef subbed, CFTypeRef a);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef prev, CFDictionaryRef cur, CFTypeRef a);
extern int IOReportIterate(CFDictionaryRef samples, int (^)(IOReportSampleRef ch));
extern CFStringRef IOReportChannelGetChannelName(IOReportSampleRef ch);
extern CFStringRef IOReportChannelGetUnitLabel(IOReportSampleRef ch);
extern int64_t IOReportSimpleGetIntegerValue(IOReportSampleRef ch, int32_t *idx);

struct ult_energy_reader {
    IOReportSubscriptionRef sub;
    CFMutableDictionaryRef subbed;
    CFDictionaryRef prev;
    uint64_t prev_ns;
};

/* Must accept exactly what ult_energy_read sums: "GPU Energy*", "*CPU Energy*", "ANE*", "DRAM*".
   Exact matching would drop numbered channels ("ANE0", "DRAM0") on chips that use them. */
static bool has_prefix(CFStringRef s, CFStringRef p);
static bool contains(CFStringRef s, CFStringRef p);

static bool wanted(CFStringRef name, bool gpu_only) {
    if (!name) return false;
    if (has_prefix(name, CFSTR("GPU Energy"))) return true;
    if (gpu_only) return false;
    return contains(name, CFSTR("CPU Energy")) || has_prefix(name, CFSTR("ANE")) || has_prefix(name, CFSTR("DRAM"));
}

ult_energy_reader *ult_energy_open(bool gpu_only) {
    CFDictionaryRef channels = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0);
    if (!channels) return NULL;
    CFMutableDictionaryRef desired = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, channels);
    CFRelease(channels);
    // Subscribe to the four totals only; the group has ~170 channels (per-core detail), and sampling
    // all of them cost ~2.2 ms per read on M5.
    CFArrayRef all = CFDictionaryGetValue(desired, CFSTR("IOReportChannels"));
    if (all) {
        CFMutableArrayRef keep = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
        for (CFIndex i = 0; i < CFArrayGetCount(all); i++) {
            CFDictionaryRef ch = CFArrayGetValueAtIndex(all, i);
            if (wanted(IOReportChannelGetChannelName(ch), gpu_only)) CFArrayAppendValue(keep, ch);
        }
        CFDictionarySetValue(desired, CFSTR("IOReportChannels"), keep);
        CFRelease(keep);
    }
    CFMutableDictionaryRef subbed = NULL;
    IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL, desired, &subbed, 0, NULL);
    CFRelease(desired);
    if (!sub || !subbed) return NULL;
    ult_energy_reader *r = calloc(1, sizeof *r);
    r->sub = sub;
    r->subbed = subbed;
    return r;
}

static double to_mj(int64_t v, CFStringRef unit) {
    if (!unit) return 0;
    if (CFStringCompare(unit, CFSTR("mJ"), 0) == kCFCompareEqualTo) return (double)v;
    if (CFStringCompare(unit, CFSTR("uJ"), 0) == kCFCompareEqualTo) return (double)v / 1e3;
    if (CFStringCompare(unit, CFSTR("nJ"), 0) == kCFCompareEqualTo) return (double)v / 1e6;
    return 0;
}

static bool has_prefix(CFStringRef s, CFStringRef p) { return s && CFStringHasPrefix(s, p); }
static bool contains(CFStringRef s, CFStringRef p) {
    return s && CFStringFind(s, p, 0).location != kCFNotFound;
}

bool ult_energy_read(ult_energy_reader *r, ult_energy_sample *out) {
    if (!r) return false;
    CFDictionaryRef cur = IOReportCreateSamples(r->sub, r->subbed, NULL);
    if (!cur) return false;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (!r->prev) {
        r->prev = cur;
        r->prev_ns = now;
        return false;
    }
    CFDictionaryRef delta = IOReportCreateSamplesDelta(r->prev, cur, NULL);
    CFRelease(r->prev);
    r->prev = cur;
    uint64_t dt = now - r->prev_ns;
    r->prev_ns = now;
    if (!delta) return false;

    __block double cpu = 0, gpu = 0, ane = 0, dram = 0;
    IOReportIterate(delta, ^int(IOReportSampleRef ch) {
        CFStringRef name = IOReportChannelGetChannelName(ch);
        double mj = to_mj(IOReportSimpleGetIntegerValue(ch, NULL), IOReportChannelGetUnitLabel(ch));
        // On macOS 27 the mJ channels read 0 for non-root callers; "GPU Energy" (nJ) does not.
        if (contains(name, CFSTR("CPU Energy"))) cpu += mj;
        else if (has_prefix(name, CFSTR("GPU Energy"))) gpu += mj;
        else if (has_prefix(name, CFSTR("ANE"))) ane += mj;
        else if (has_prefix(name, CFSTR("DRAM"))) dram += mj;
        return 0;
    });
    CFRelease(delta);
    out->cpu_mj = cpu;
    out->gpu_mj = gpu;
    out->ane_mj = ane;
    out->dram_mj = dram;
    out->nanos = dt;
    return true;
}

void ult_energy_close(ult_energy_reader *r) {
    if (!r) return;
    if (r->prev) CFRelease(r->prev);
    if (r->subbed) CFRelease(r->subbed);
    if (r->sub) CFRelease((CFTypeRef)r->sub);
    free(r);
}
