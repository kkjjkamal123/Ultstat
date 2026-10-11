// Minimal, allocation-free client for the AppleSMC user client.
// One IOConnectCallStructMethod per read once a key's info is cached.
#ifndef CSMC_H
#define CSMC_H

#include <stdint.h>
#include <stdbool.h>
#include <IOKit/IOKitLib.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint32_t smc_key_t;    // big-endian FourCC packed into a host integer ('CHTE')

typedef struct {
    uint32_t size;             // payload bytes (<= 32)
    uint32_t type;             // FourCC of the data type ('ui8 ', 'flt ', 'sp78', ...)
    uint8_t  attributes;
} smc_key_info_t;

typedef struct smc_conn {
    io_connect_t conn;
} smc_conn_t;

// Opens the AppleSMC user client. Returns KERN_SUCCESS or an IOKit error.
kern_return_t smc_open(smc_conn_t *out);
void smc_close(smc_conn_t *c);

// Key metadata. `result` (optional) receives the SMC firmware result byte.
kern_return_t smc_key_info(const smc_conn_t *c, smc_key_t key, smc_key_info_t *info, uint8_t *result);

// Reads `info->size` bytes into `out` (must hold 32 bytes).
kern_return_t smc_read(const smc_conn_t *c, smc_key_t key, const smc_key_info_t *info, uint8_t out[32], uint8_t *result);

// Writes `info->size` bytes. Requires root.
kern_return_t smc_write(const smc_conn_t *c, smc_key_t key, const smc_key_info_t *info, const uint8_t *bytes, uint8_t *result);

// Key at a given index in the firmware's key table (0 ..< key count).
kern_return_t smc_key_at_index(const smc_conn_t *c, uint32_t index, smc_key_t *key, uint8_t *result);

#ifdef __cplusplus
}
#endif
#endif
