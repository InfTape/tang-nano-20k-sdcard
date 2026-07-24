/*
 * Tang Nano 20K native-SD USB mass-storage reader.
 */
#include "board.h"
#include "bflb_mtimer.h"
#include "usbd_core.h"
#include "FreeRTOS.h"
#include "task.h"

#include "fpga_link.h"
#include "msc_bridge.h"
#include "dirtyjtag.h"
#include "jtag_gpio.h"

extern void usb_descriptors_init(uint8_t busid, bool reader_mode);

static bool reader_mode;

static void usbd_event_handler(uint8_t busid, uint8_t event)
{
    (void)busid;
    if (event == USBD_EVENT_CONFIGURED && !reader_mode)
        dirtyjtag_start();
}

int main(void)
{
    uint32_t blocks;

    board_init();

    /*
     * With a ready SD card, boot as the mass-storage reader. With the card
     * removed (or an FPGA image needing recovery), expose DirtyJTAG so the
     * FPGA configuration flash can be updated through the same USB socket.
     */
    fpga_link_init();
    reader_mode = false;
    /*
     * A large card can take several seconds to finish a cold native-SD
     * initialization.  Keep S2 asserted for this whole window when recovery
     * mode is wanted; otherwise prefer the reader once the FPGA is ready.
     */
    for (unsigned retry = 0; retry < 500; retry++) {
        if (fpga_link_get_capacity(&blocks) == 0 && blocks != 0) {
            reader_mode = true;
            break;
        }
        bflb_mtimer_delay_ms(10);
    }

    usb_descriptors_init(0, reader_mode);
    if (reader_mode) {
        xTaskCreate(msc_bridge_probe_task, "fpga-probe", 1024,
                    NULL, 16, NULL);
        msc_bridge_usb_init(0);
    } else {
        jtag_gpio_init();
        dirtyjtag_init(0);
    }
    usbd_initialize(0, 0x20072000, usbd_event_handler);

    vTaskStartScheduler();

    while (1) {}
}
