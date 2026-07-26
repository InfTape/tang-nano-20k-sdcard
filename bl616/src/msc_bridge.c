#include <stdint.h>
#include <stdbool.h>
#include <string.h>

#include "usbd_core.h"
#include "usbd_msc.h"
#include "FreeRTOS.h"
#include "semphr.h"
#include "task.h"

#include "fpga_link.h"
#include "msc_bridge.h"

#define MSC_IN_EP  0x81
#define MSC_OUT_EP 0x02
#define FALLBACK_BLOCKS 4096u
#define DIAGNOSTIC_BLOCKS_BASE 0x00d00000u
#define PREFETCH_BLOCKS 32u
#define PREFETCH_BYTES (PREFETCH_BLOCKS * 512u)
#define PREFETCH_SLOT_COUNT 3u

enum prefetch_state {
    PREFETCH_EMPTY = 0,
    PREFETCH_FILLING,
    PREFETCH_READY,
};

struct prefetch_slot {
    uint32_t lba;
    uint32_t generation;
    uint8_t block_count;
    uint8_t state;
    uint8_t data[PREFETCH_BYTES] __attribute__((aligned(4)));
};

static struct usbd_interface msc_interface;
static volatile uint32_t cached_blocks = FALLBACK_BLOCKS;
static volatile bool backend_ready;
static uint8_t probe_blocks[16384] __attribute__((aligned(4)));
static struct prefetch_slot prefetch_slots[PREFETCH_SLOT_COUNT];
static SemaphoreHandle_t prefetch_mutex;
static TaskHandle_t prefetch_task_handle;
static uint32_t prefetch_generation;
static uint32_t next_prefetch_lba;
static bool prefetch_enabled;

static void prefetch_notify(void)
{
    if (prefetch_task_handle)
        xTaskNotifyGive(prefetch_task_handle);
}

static void prefetch_cancel(void)
{
    if (!prefetch_mutex)
        return;
    xSemaphoreTake(prefetch_mutex, portMAX_DELAY);
    prefetch_generation++;
    prefetch_enabled = false;
    for (unsigned i = 0; i < PREFETCH_SLOT_COUNT; i++)
        prefetch_slots[i].state = PREFETCH_EMPTY;
    xSemaphoreGive(prefetch_mutex);
}

static void prefetch_restart(uint32_t lba)
{
    if (!prefetch_mutex)
        return;
    xSemaphoreTake(prefetch_mutex, portMAX_DELAY);
    prefetch_generation++;
    next_prefetch_lba = lba;
    prefetch_enabled = lba < cached_blocks;
    for (unsigned i = 0; i < PREFETCH_SLOT_COUNT; i++)
        prefetch_slots[i].state = PREFETCH_EMPTY;
    xSemaphoreGive(prefetch_mutex);
    prefetch_notify();
}

static int prefetch_take(uint32_t lba, uint8_t *buffer,
                         uint8_t block_count)
{
    if (!prefetch_mutex || !prefetch_task_handle)
        return -1;

    for (unsigned retry = 0; retry < 2000; retry++) {
        bool matching_fill = false;

        xSemaphoreTake(prefetch_mutex, portMAX_DELAY);
        for (unsigned i = 0; i < PREFETCH_SLOT_COUNT; i++) {
            struct prefetch_slot *slot = &prefetch_slots[i];
            if (slot->lba != lba ||
                slot->block_count != block_count)
                continue;
            if (slot->state == PREFETCH_READY) {
                memcpy(buffer, slot->data,
                       (size_t)block_count * 512u);
                slot->state = PREFETCH_EMPTY;
                xSemaphoreGive(prefetch_mutex);
                prefetch_notify();
                return 0;
            }
            if (slot->state == PREFETCH_FILLING)
                matching_fill = true;
        }
        xSemaphoreGive(prefetch_mutex);

        if (!matching_fill)
            return -1;
        vTaskDelay(pdMS_TO_TICKS(1));
    }
    return -1;
}

static void msc_bridge_prefetch_task(void *argument)
{
    (void)argument;

    for (;;) {
        ulTaskNotifyTake(pdTRUE, portMAX_DELAY);

        for (;;) {
            unsigned slot_index[2];
            uint32_t lba[2];
            uint8_t block_count[2];
            uint32_t generation;
            unsigned reserved = 0;
            unsigned empty_slots = 0;
            unsigned wanted = 0;

            xSemaphoreTake(prefetch_mutex, portMAX_DELAY);
            generation = prefetch_generation;
            if (backend_ready && prefetch_enabled) {
                for (unsigned i = 0; i < PREFETCH_SLOT_COUNT; i++)
                    if (prefetch_slots[i].state == PREFETCH_EMPTY)
                        empty_slots++;
                uint32_t remaining =
                    cached_blocks - next_prefetch_lba;
                if (empty_slots >= 2 && remaining > PREFETCH_BLOCKS)
                    wanted = 2;
                else if (empty_slots >= 1 &&
                         remaining <= PREFETCH_BLOCKS)
                    wanted = 1;

                for (unsigned i = 0;
                     i < PREFETCH_SLOT_COUNT && reserved < wanted; i++) {
                    struct prefetch_slot *slot = &prefetch_slots[i];
                    if (slot->state != PREFETCH_EMPTY)
                        continue;
                    if (next_prefetch_lba >= cached_blocks) {
                        prefetch_enabled = false;
                        break;
                    }
                    remaining =
                        cached_blocks - next_prefetch_lba;
                    uint8_t count = remaining > PREFETCH_BLOCKS ?
                        PREFETCH_BLOCKS : (uint8_t)remaining;
                    slot->lba = next_prefetch_lba;
                    slot->block_count = count;
                    slot->generation = generation;
                    slot->state = PREFETCH_FILLING;
                    slot_index[reserved] = i;
                    lba[reserved] = next_prefetch_lba;
                    block_count[reserved] = count;
                    next_prefetch_lba += count;
                    reserved++;
                }
            }
            xSemaphoreGive(prefetch_mutex);

            if (reserved == 0)
                break;

            int result;
            if (reserved == 2) {
                result = fpga_link_read_two_batches(
                    lba[0], prefetch_slots[slot_index[0]].data,
                    block_count[0],
                    lba[1], prefetch_slots[slot_index[1]].data,
                    block_count[1]);
            } else {
                result = fpga_link_read_blocks(
                    lba[0], prefetch_slots[slot_index[0]].data,
                    block_count[0]);
            }

            xSemaphoreTake(prefetch_mutex, portMAX_DELAY);
            for (unsigned i = 0; i < reserved; i++) {
                struct prefetch_slot *slot =
                    &prefetch_slots[slot_index[i]];
                if (slot->generation == generation &&
                    slot->state == PREFETCH_FILLING)
                    slot->state = result == 0 ?
                        PREFETCH_READY : PREFETCH_EMPTY;
            }
            if (result != 0 && generation == prefetch_generation)
                prefetch_enabled = false;
            xSemaphoreGive(prefetch_mutex);

            if (result != 0)
                break;
        }
    }
}

void msc_bridge_probe_task(void *argument)
{
    uint32_t blocks;
    (void)argument;

    for (;;) {
        if (fpga_link_get_capacity(&blocks) == 0 && blocks != 0) {
            uint8_t probe_count = blocks >= 32 ? 32 : (uint8_t)blocks;
            int result = fpga_link_read_blocks(0, probe_blocks, probe_count);
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
    prefetch_mutex = xSemaphoreCreateMutex();
    if (prefetch_mutex &&
        xTaskCreate(msc_bridge_prefetch_task, "msc-prefetch", 1536,
                    NULL, 12, &prefetch_task_handle) != pdPASS)
        prefetch_task_handle = NULL;
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

    for (uint32_t offset = 0; offset < length;) {
        uint32_t remaining_blocks = (length - offset) / 512u;
        uint8_t block_count = remaining_blocks > 32u ?
            32u : (uint8_t)remaining_blocks;
        uint32_t transfer_length = (uint32_t)block_count * 512u;
        if (sector >= cached_blocks ||
            block_count > cached_blocks - sector)
            return -1;
        int result = -1;
        if (block_count == PREFETCH_BLOCKS)
            result = prefetch_take(sector, buffer + offset,
                                   block_count);
        if (result != 0) {
            prefetch_cancel();
            result = fpga_link_read_blocks(sector, buffer + offset,
                                           block_count);
            if (result == 0 && block_count == PREFETCH_BLOCKS)
                prefetch_restart(sector + block_count);
        }
        if (result != 0)
            memset(buffer + offset, 0, transfer_length);
        offset += transfer_length;
        sector += block_count;
    }
    return 0;
}

int usbd_msc_sector_write(uint8_t busid, uint8_t lun, uint32_t sector,
                          uint8_t *buffer, uint32_t length)
{
    (void)busid;
    (void)lun;
    prefetch_cancel();
    if (!backend_ready || (length & 511u) || sector >= cached_blocks)
        return -1;
    for (uint32_t offset = 0; offset < length;) {
        uint32_t remaining_blocks = (length - offset) / 512u;
        uint8_t block_count = remaining_blocks > 32u ?
            32u : (uint8_t)remaining_blocks;
        if (sector >= cached_blocks ||
            block_count > cached_blocks - sector ||
            fpga_link_write_blocks(sector, buffer + offset,
                                   block_count) != 0)
            return -1;
        offset += (uint32_t)block_count * 512u;
        sector += block_count;
    }
    return 0;
}
