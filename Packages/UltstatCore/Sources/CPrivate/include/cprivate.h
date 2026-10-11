// Declarations for private-but-stable macOS SPI used by system monitors.
// Every symbol here is resolved at link time from IOKit; nothing is loaded dynamically.
#ifndef CPRIVATE_H
#define CPRIVATE_H

#include <CoreFoundation/CoreFoundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: IOHIDEventSystem (thermal sensors on Apple Silicon)
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;

IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef key);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

enum {
    kUltIOHIDEventTypeTemperature = 15,
    kUltIOHIDEventTypePower = 25,
};
#define ULT_IOHID_EVENT_FIELD_BASE(type) ((type) << 16)

#ifdef __cplusplus
}
#endif
#endif

// MARK: IOReport energy (libIOReport; same source powermetrics uses, no root needed)
#ifndef ULT_IOREPORT
#define ULT_IOREPORT
#include <stdint.h>
#include <stdbool.h>

typedef struct ult_energy_reader ult_energy_reader;

typedef struct {
    double cpu_mj;   // energy over the interval, millijoules
    double gpu_mj;
    double ane_mj;
    double dram_mj;
    uint64_t nanos;  // interval length
} ult_energy_sample;

/// Subscribes to energy totals. `gpu_only` = true for unprivileged callers: on macOS 27 the CPU,
/// ANE and DRAM channels read 0 unless the caller is root. Returns NULL if unavailable.
ult_energy_reader *ult_energy_open(bool gpu_only);
/// Energy since the previous call (first call establishes a baseline and returns false).
bool ult_energy_read(ult_energy_reader *r, ult_energy_sample *out);
void ult_energy_close(ult_energy_reader *r);
#endif
