#include "csmc.h"
#include <string.h>

// Layout of the AppleSMC kSMCHandleYPCEvent parameter block (80 bytes).
typedef struct {
    uint8_t  major, minor, build, reserved;
    uint16_t release;
} smc_vers_t;

typedef struct {
    uint16_t version, length;
    uint32_t cpuPLimit, gpuPLimit, memPLimit;
} smc_plimit_t;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t  dataAttributes;
} smc_info_wire_t;

typedef struct {
    uint32_t        key;
    smc_vers_t      vers;
    smc_plimit_t    pLimitData;
    smc_info_wire_t keyInfo;
    uint8_t         result;
    uint8_t         status;
    uint8_t         data8;
    uint32_t        data32;
    uint8_t         bytes[32];
} smc_param_t;

_Static_assert(sizeof(smc_param_t) == 80, "AppleSMC parameter block must be 80 bytes");

enum {
    kSMCUserClientSelector = 2,   // kSMCHandleYPCEvent
    kSMCCmdReadKey = 5,
    kSMCCmdWriteKey = 6,
    kSMCCmdKeyAtIndex = 8,
    kSMCCmdKeyInfo = 9,
};

static kern_return_t smc_call(const smc_conn_t *c, smc_param_t *in, smc_param_t *out) {
    size_t outSize = sizeof(smc_param_t);
    return IOConnectCallStructMethod(c->conn, kSMCUserClientSelector, in, sizeof(smc_param_t), out, &outSize);
}

kern_return_t smc_open(smc_conn_t *out) {
    out->conn = IO_OBJECT_NULL;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (svc == IO_OBJECT_NULL) return kIOReturnNotFound;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &out->conn);
    IOObjectRelease(svc);
    return kr;
}

void smc_close(smc_conn_t *c) {
    if (c->conn != IO_OBJECT_NULL) {
        IOServiceClose(c->conn);
        c->conn = IO_OBJECT_NULL;
    }
}

kern_return_t smc_key_info(const smc_conn_t *c, smc_key_t key, smc_key_info_t *info, uint8_t *result) {
    smc_param_t in = {0}, out = {0};
    in.key = key;
    in.data8 = kSMCCmdKeyInfo;
    kern_return_t kr = smc_call(c, &in, &out);
    if (result) *result = out.result;
    if (kr != KERN_SUCCESS) return kr;
    if (out.result != 0) return kIOReturnNotFound;
    info->size = out.keyInfo.dataSize;
    info->type = out.keyInfo.dataType;
    info->attributes = out.keyInfo.dataAttributes;
    return KERN_SUCCESS;
}

kern_return_t smc_read(const smc_conn_t *c, smc_key_t key, const smc_key_info_t *info, uint8_t out_bytes[32], uint8_t *result) {
    if (info->size > 32) return kIOReturnBadArgument;
    smc_param_t in = {0}, out = {0};
    in.key = key;
    in.keyInfo.dataSize = info->size;
    in.data8 = kSMCCmdReadKey;
    kern_return_t kr = smc_call(c, &in, &out);
    if (result) *result = out.result;
    if (kr != KERN_SUCCESS) return kr;
    if (out.result != 0) return kIOReturnError;
    memcpy(out_bytes, out.bytes, 32);
    return KERN_SUCCESS;
}

kern_return_t smc_write(const smc_conn_t *c, smc_key_t key, const smc_key_info_t *info, const uint8_t *bytes, uint8_t *result) {
    if (info->size > 32) return kIOReturnBadArgument;
    smc_param_t in = {0}, out = {0};
    in.key = key;
    in.keyInfo.dataSize = info->size;
    in.data8 = kSMCCmdWriteKey;
    memcpy(in.bytes, bytes, info->size);
    kern_return_t kr = smc_call(c, &in, &out);
    if (result) *result = out.result;
    if (kr != KERN_SUCCESS) return kr;
    return out.result == 0 ? KERN_SUCCESS : kIOReturnError;
}

kern_return_t smc_key_at_index(const smc_conn_t *c, uint32_t index, smc_key_t *key, uint8_t *result) {
    smc_param_t in = {0}, out = {0};
    in.data8 = kSMCCmdKeyAtIndex;
    in.data32 = index;
    kern_return_t kr = smc_call(c, &in, &out);
    if (result) *result = out.result;
    if (kr != KERN_SUCCESS) return kr;
    if (out.result != 0) return kIOReturnError;
    *key = out.key;
    return KERN_SUCCESS;
}
