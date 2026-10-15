#include <stdint.h>
#include <stdbool.h>
bool ODRotationAvailable(void);
int ODRotateDisplay(uint32_t display, int degrees);

// Read-only: zero means the system reports orientation capability, not verified hardware success.
int ODRotationCapability(uint32_t display);
