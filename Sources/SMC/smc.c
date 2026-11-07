#include "smc.h"
#include <string.h>

#define KERNEL_INDEX_SMC      2
#define SMC_CMD_READ_BYTES    5
#define SMC_CMD_WRITE_BYTES   6
#define SMC_CMD_READ_INDEX    8
#define SMC_CMD_READ_KEYINFO  9

typedef struct {
    char major, minor, build, reserved[1];
    uint16_t release;
} SMCKeyData_vers_t;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCKeyData_pLimitData_t;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    char dataAttributes;
} SMCKeyData_keyInfo_t;

typedef struct {
    uint32_t key;
    SMCKeyData_vers_t vers;
    SMCKeyData_pLimitData_t pLimitData;
    SMCKeyData_keyInfo_t keyInfo;
    char result;
    char status;
    char data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData_t;

static uint32_t str_to_u32(const char *s) {
    uint32_t r = 0;
    for (int i = 0; i < 4; i++) r = (r << 8) | (uint8_t)(s[i] ? s[i] : ' ');
    return r;
}

static void u32_to_str(uint32_t v, char out[5]) {
    out[0] = (char)(v >> 24); out[1] = (char)(v >> 16);
    out[2] = (char)(v >> 8);  out[3] = (char)v; out[4] = 0;
}

kern_return_t smc_open(io_connect_t *conn) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return KERN_FAILURE;
    kern_return_t r = IOServiceOpen(svc, mach_task_self(), 0, conn);
    IOObjectRelease(svc);
    return r;
}

void smc_close(io_connect_t conn) { IOServiceClose(conn); }

static kern_return_t smc_call(io_connect_t conn, SMCKeyData_t *in, SMCKeyData_t *out) {
    size_t outSize = sizeof(SMCKeyData_t);
    return IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, in, sizeof(SMCKeyData_t), out, &outSize);
}

static kern_return_t smc_key_info(io_connect_t conn, uint32_t key, SMCKeyData_keyInfo_t *info) {
    SMCKeyData_t in = {0}, out = {0};
    in.key = key;
    in.data8 = SMC_CMD_READ_KEYINFO;
    kern_return_t r = smc_call(conn, &in, &out);
    if (r != KERN_SUCCESS) return r;
    if (out.result != 0) return KERN_FAILURE;
    *info = out.keyInfo;
    return KERN_SUCCESS;
}

kern_return_t smc_read(io_connect_t conn, const char *key, SMCValue *val) {
    memset(val, 0, sizeof(*val));
    strncpy(val->key, key, 4);
    uint32_t k = str_to_u32(key);

    SMCKeyData_keyInfo_t info;
    kern_return_t r = smc_key_info(conn, k, &info);
    if (r != KERN_SUCCESS) return r;

    SMCKeyData_t in = {0}, out = {0};
    in.key = k;
    in.keyInfo.dataSize = info.dataSize;
    in.data8 = SMC_CMD_READ_BYTES;
    r = smc_call(conn, &in, &out);
    if (r != KERN_SUCCESS) return r;
    if (out.result != 0) return KERN_FAILURE;

    val->size = info.dataSize > 32 ? 32 : info.dataSize;
    u32_to_str(info.dataType, val->type);
    memcpy(val->bytes, out.bytes, val->size);
    return KERN_SUCCESS;
}

kern_return_t smc_read_fast(io_connect_t conn, SMCValue *val) {
    SMCKeyData_t in = {0}, out = {0};
    in.key = str_to_u32(val->key);
    in.keyInfo.dataSize = val->size;
    in.data8 = SMC_CMD_READ_BYTES;
    kern_return_t r = smc_call(conn, &in, &out);
    if (r != KERN_SUCCESS) return r;
    if (out.result != 0) return KERN_FAILURE;
    memcpy(val->bytes, out.bytes, val->size);
    return KERN_SUCCESS;
}

kern_return_t smc_write(io_connect_t conn, const SMCValue *val) {
    uint32_t k = str_to_u32(val->key);
    SMCKeyData_keyInfo_t info;
    kern_return_t r = smc_key_info(conn, k, &info);
    if (r != KERN_SUCCESS) return r;
    if (info.dataSize != val->size) return KERN_INVALID_ARGUMENT;

    SMCKeyData_t in = {0}, out = {0};
    in.key = k;
    in.data8 = SMC_CMD_WRITE_BYTES;
    in.keyInfo.dataSize = val->size;
    memcpy(in.bytes, val->bytes, val->size);
    r = smc_call(conn, &in, &out);
    if (r != KERN_SUCCESS) return r;
    return out.result == 0 ? KERN_SUCCESS : KERN_FAILURE;
}

uint32_t smc_key_count(io_connect_t conn) {
    SMCValue v;
    if (smc_read(conn, "#KEY", &v) != KERN_SUCCESS || v.size < 4) return 0;
    return ((uint32_t)v.bytes[0] << 24) | ((uint32_t)v.bytes[1] << 16) |
           ((uint32_t)v.bytes[2] << 8) | v.bytes[3];
}

kern_return_t smc_key_at_index(io_connect_t conn, uint32_t index, char out[5]) {
    SMCKeyData_t in = {0}, o = {0};
    in.data8 = SMC_CMD_READ_INDEX;
    in.data32 = index;
    kern_return_t r = smc_call(conn, &in, &o);
    if (r != KERN_SUCCESS) return r;
    u32_to_str(o.key, out);
    return KERN_SUCCESS;
}

bool smc_value_to_double(const SMCValue *v, double *out) {
    const uint8_t *b = v->bytes;
    if (!strcmp(v->type, "flt ") && v->size == 4) {
        float f; memcpy(&f, b, 4); *out = f; return true;          // little-endian (Apple Silicon)
    }
    if (!strcmp(v->type, "fpe2") && v->size == 2) {               // Intel : RPM
        *out = ((b[0] << 8) | b[1]) / 4.0; return true;
    }
    if (!strcmp(v->type, "sp78") && v->size == 2) {               // Intel : température
        *out = (int16_t)((b[0] << 8) | b[1]) / 256.0; return true;
    }
    if (!strcmp(v->type, "ui8 ") && v->size == 1) { *out = b[0]; return true; }
    if (!strcmp(v->type, "ui16") && v->size == 2) { *out = (b[0] << 8) | b[1]; return true; }
    if (!strcmp(v->type, "ui32") && v->size == 4) {
        *out = (double)(((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3]);
        return true;
    }
    return false;
}

bool smc_value_from_double(SMCValue *v, double d) {
    uint8_t *b = v->bytes;
    if (!strcmp(v->type, "flt ") && v->size == 4) {
        float f = (float)d; memcpy(b, &f, 4); return true;
    }
    if (!strcmp(v->type, "fpe2") && v->size == 2) {
        uint16_t x = (uint16_t)(d * 4.0); b[0] = x >> 8; b[1] = x & 0xff; return true;
    }
    if (!strcmp(v->type, "ui8 ") && v->size == 1) { b[0] = (uint8_t)d; return true; }
    return false;
}
