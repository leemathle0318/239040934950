#ifndef VCAMLIVE_BRIDGE_STATUS_H
#define VCAMLIVE_BRIDGE_STATUS_H
#include <stdint.h>

typedef struct {
    uint32_t enabled;
    uint32_t ipConfigured;
    uint64_t packets;
    uint64_t samples;
    uint64_t renderCalls;
    uint64_t injected;
    uint64_t unsupported;
    uint64_t underflows;
    uint64_t fallback;
    uint64_t socketFailures;
    uint64_t packetAgeMs;  /* UINT64_MAX = no packets received yet */
    uint32_t rate;
    uint32_t channels;
    uint32_t bits;
} VCamBridgeStatus;

#ifdef __cplusplus
extern "C" {
#endif
void VCamBridgeCopyStatus(VCamBridgeStatus *out);
#ifdef __cplusplus
}
#endif
#endif
