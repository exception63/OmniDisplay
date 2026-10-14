#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
// Status: 0 transport succeeded (requires reply validation), 1 API missing,
// 2 identity/route unknown, 3 ambiguous, 4 inactive/built-in/mirrored, 5 I/O error, 6 locked.
size_t ODInputGetPacket(bool includeSourceAddress, uint8_t bytes[4]); // Pure codec.
size_t ODInputSetPacket(uint16_t value, uint8_t bytes[6]); // Pure codec, no hardware I/O.
int ODReadInput(uint32_t display, const char *uuid, uint8_t reply[12], char *detail, size_t capacity);
int ODReadInputProfile(uint32_t display, const char *uuid, uint8_t reply[12], char *detail, size_t capacity,
                       uint64_t *route, uint32_t offset, uint32_t delayMicros, bool includeSourceChecksum);
// Only CoreGraphicsBackend invokes this write boundary. Per-call consent deadline applies independently here.
int ODSetInput(uint32_t display, const char *uuid, uint16_t value, uint64_t expectedRoute, uint32_t retainedDisplay, const char *retainedUUID, bool confirmed, double expiresUptime, char *detail, size_t capacity);
