#ifndef MSC_BRIDGE_H
#define MSC_BRIDGE_H

#include <stdint.h>

void msc_bridge_usb_init(uint8_t busid);
void msc_bridge_probe_task(void *argument);

#endif
