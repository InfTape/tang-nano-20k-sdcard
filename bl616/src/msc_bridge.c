#include <stdint.h>
#include <stdbool.h>
#include <string.h>

#include "usbd_core.h"
#include "usbd_msc.h"
#include "FreeRTOS.h"
#include "task.h"

#include "fpga_link.h"
#include "msc_bridge.h"

#define MSC_IN_EP  0x81
#define MSC_OUT_EP 0x02
#define FALLBACK_BLOCKS 4096u
#define DIAGNOSTIC_BLOCKS_BASE 0x00d00000u

static struct usbd_interface msc_interface;
static volatile uint32_t cached_blocks = FALLBACK_BLOCKS;
static volatile bool backend_ready;
static uint8_t probe_sector[512] __attribute__((aligned(4)));

void msc_bridge_probe_task(void *argument)
{
    uint32_t blocks;
    (void)argument;

    for (;;) {
        if (fpga_link_get_capacity(&blocks) == 0 && blocks != 0) {
            int result = 0;
            for (uint32_t sector = 0; sector < 8; sector++) {
                result = fpga_link_read_sector(sector, probe_sector);
                if (result != 0)
                    break;
            }
            if (result == 0) {
                cached_blocks = blocks;
                backend_ready = true;
                vTaskDelete(NULL);
                return;
            } else {
                cached_blocks = DIAGNOSTIC_BLOCKS_BASE |
                                (fpga_link_last_diagnostic() & 0x000fffffu);
                backend_ready = false;
                vTaskDelete(NULL);
                return;
            }
        } else {
            cached_blocks = FALLBACK_BLOCKS;
            backend_ready = false;
            vTaskDelay(pdMS_TO_TICKS(50));
        }
    }
}

void msc_bridge_usb_init(uint8_t busid)
{
    usbd_add_interface(busid, usbd_msc_init_intf(
        busid, &msc_interface, MSC_OUT_EP, MSC_IN_EP));
}

void usbd_msc_get_cap(uint8_t busid, uint8_t lun,
                      uint32_t *block_num, uint32_t *block_size)
{
    (void)busid;
    (void)lun;
    /*
     * SCSI commands must never wait for the FPGA. The independent probe task
     * keeps this value current; the patched READ CAPACITY paths call us again
     * after initial USB configuration.
     */
    *block_num = cached_blocks;
    *block_size = 512;
}

int usbd_msc_sector_read(uint8_t busid, uint8_t lun, uint32_t sector,
                         uint8_t *buffer, uint32_t length)
{
    (void)busid;
    (void)lun;
    if ((length & 511u) || sector >= cached_blocks)
        return -1;

    /*
     * Keep the Windows disk stack alive while diagnosing the private FPGA
     * link. A zero-filled sector is a valid unformatted medium response and
     * lets the reported capacity reveal whether the INFO exchange succeeded.
     */
    if (!backend_ready) {
        memset(buffer, 0, length);
        return 0;
    }

    for (uint32_t offset = 0; offset < length; offset += 512, sector++) {
        if (sector >= cached_blocks)
            return -1;
        if (fpga_link_read_sector(sector, buffer + offset) != 0) {
            memset(buffer + offset, 0, 512);
        }
    }
    return 0;
}

int usbd_msc_sector_write(uint8_t busid, uint8_t lun, uint32_t sector,
                          uint8_t *buffer, uint32_t length)
{
    (void)busid;
    (void)lun;
    if (!backend_ready || (length & 511u) || sector >= cached_blocks)
        return -1;
    for (uint32_t offset = 0; offset < length;) {
        uint32_t remaining_blocks = (length - offset) / 512u;
        uint8_t block_count = remaining_blocks > 8u ?
            8u : (uint8_t)remaining_blocks;
        if (sector + block_count > cached_blocks ||
            fpga_link_write_blocks(sector, buffer + offset,
                                   block_count) != 0)
            return -1;
        offset += (uint32_t)block_count * 512u;
        sector += block_count;
    }
    return 0;
}
