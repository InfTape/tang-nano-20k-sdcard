/*
 * Private BL616 <-> FPGA link on the Tang Nano 20K.
 *
 * Tang Nano 20K v3923 private link:
 * GPIO0 CS (board net SPI_DIR), GPIO1 SCLK, GPIO27 MOSI, GPIO30 MISO.
 * The BL616 is a mode-0 bit-banged master.
 */
#include <stdbool.h>
#include <stddef.h>

#include "bflb_gpio.h"
#include "FreeRTOS.h"
#include "semphr.h"
#include "task.h"

#include "fpga_link.h"

#define LINK_MAGIC_REQUEST  0xa5
#define LINK_MAGIC_RESPONSE 0x5a

#define LINK_CMD_INFO        0x01
#define LINK_CMD_STATUS      0x02
#define LINK_CMD_READ_START  0x03
#define LINK_CMD_READ_DATA   0x04
#define LINK_CMD_WRITE_DATA  0x05

#define LINK_DELAY_ITERATIONS          8u
#define LINK_SHORT_RESPONSE_WAIT     256u
#define LINK_BLOCK_RESPONSE_WAIT    3000u

#define GPIO_SET   (1u << 25)
#define GPIO_CLEAR (1u << 26)
#define GPIO_READ  (1u << 28)

static volatile uint32_t *const reg_cs   = (volatile uint32_t *)0x200008c4;
static volatile uint32_t *const reg_clk  = (volatile uint32_t *)0x200008c8;
static volatile uint32_t *const reg_mosi = (volatile uint32_t *)0x20000930;
static volatile uint32_t *const reg_miso = (volatile uint32_t *)0x2000093c;

static struct bflb_device_s *gpio;
static SemaphoreHandle_t link_mutex;
static volatile uint8_t last_exchange_error;
static volatile uint32_t last_diagnostic;

/*
 * The FPGA samples this link at 48 MHz through a three-stage synchronizer.
 * Eight volatile loop iterations plus the GPIO bus accesses leave ample
 * setup/hold margin while avoiding the very conservative original 40-iteration
 * delay.  Keep this function inlined: a call/return on every half-bit is a
 * measurable part of the transfer time.
 */
static inline __attribute__((always_inline)) void link_delay(void)
{
    for (volatile unsigned i = 0; i < LINK_DELAY_ITERATIONS; i++)
        __asm__ volatile("nop");
}

static inline __attribute__((always_inline)) uint8_t transfer_bit(uint8_t value)
{
    *reg_mosi |= value ? GPIO_SET : GPIO_CLEAR;
    link_delay();
    *reg_clk |= GPIO_SET;
    link_delay();
    value = (*reg_miso & GPIO_READ) ? 1u : 0u;
    *reg_clk |= GPIO_CLEAR;
    return value;
}

static uint8_t transfer_byte(uint8_t value)
{
    uint8_t received = 0;

    for (unsigned bit = 0; bit < 8; bit++) {
        received = (uint8_t)((received << 1) |
                             transfer_bit((value & 0x80) != 0));
        value <<= 1;
    }
    return received;
}

static uint32_t crc32_update(uint32_t crc, uint8_t value)
{
    crc ^= value;
    for (unsigned i = 0; i < 8; i++)
        crc = (crc >> 1) ^ ((crc & 1u) ? 0xedb88320u : 0u);
    return crc;
}

static uint32_t load_le32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void store_le32(uint8_t *p, uint32_t value)
{
    p[0] = (uint8_t)value;
    p[1] = (uint8_t)(value >> 8);
    p[2] = (uint8_t)(value >> 16);
    p[3] = (uint8_t)(value >> 24);
}

static int exchange(uint8_t command, uint32_t lba,
                    const uint8_t *tx_data, uint16_t tx_len,
                    uint8_t *rx_data, uint16_t rx_capacity,
                    uint8_t *response_status, uint16_t *response_len)
{
    uint8_t header[9];
    uint8_t response[5];
    uint8_t check = 0;
    uint32_t crc = 0xffffffffu;
    uint8_t response_scan = 0xff;
    unsigned found = 0;
    bool mutex_locked = false;
    int result = -2;

    last_exchange_error = 0;

    /*
     * The MSC capacity callback runs while USB is constructed, before the
     * scheduler has started. A FreeRTOS mutex cannot be owned until there is a
     * current task, so only use it for later runtime sector transactions.
     */
    if (link_mutex && xTaskGetSchedulerState() == taskSCHEDULER_RUNNING) {
        if (xSemaphoreTake(link_mutex, pdMS_TO_TICKS(1000)) != pdTRUE)
            return -1;
        mutex_locked = true;
    }

    header[0] = LINK_MAGIC_REQUEST;
    header[1] = command;
    store_le32(&header[2], lba);
    header[6] = (uint8_t)tx_len;
    header[7] = (uint8_t)(tx_len >> 8);
    for (unsigned i = 0; i < 8; i++)
        check ^= header[i];
    header[8] = check;

    *reg_clk |= GPIO_CLEAR;
    *reg_cs |= GPIO_CLEAR;
    *reg_mosi |= GPIO_SET;
    link_delay();

    for (unsigned i = 0; i < sizeof(header); i++)
        transfer_byte(header[i]);
    for (unsigned i = 0; i < tx_len; i++) {
        transfer_byte(tx_data[i]);
        crc = crc32_update(crc, tx_data[i]);
    }
    if (tx_len) {
        crc ^= 0xffffffffu;
        for (unsigned i = 0; i < 4; i++)
            transfer_byte((uint8_t)(crc >> (i * 8)));
    }

    /*
     * A 512-byte response CRC takes 1024 FPGA clocks (about 21.4 us) to
     * precompute. Short replies need only a few dozen clocks. The original
     * unconditional 30000-iteration wait penalized every command and every
     * status poll.
     */
    unsigned response_wait = rx_capacity >= 512 ?
        LINK_BLOCK_RESPONSE_WAIT : LINK_SHORT_RESPONSE_WAIT;
    for (volatile unsigned i = 0; i < response_wait; i++)
        __asm__ volatile("nop");

    /*
     * The FPGA samples SCLK through a synchronizer. Search the returned
     * bitstream rather than assuming that its first driven bit is aligned to
     * the first byte clocked here.
     */
    for (unsigned i = 0; i < 64; i++) {
        response_scan = (uint8_t)((response_scan << 1) | transfer_bit(1));
        if (response_scan == LINK_MAGIC_RESPONSE) {
            response[0] = response_scan;
            found = 1;
            break;
        }
    }
    if (!found) {
        last_exchange_error = 1;
        goto done;
    }

    for (unsigned i = 1; i < sizeof(response); i++)
        response[i] = transfer_byte(0xff);
    check = response[0] ^ response[1] ^ response[2] ^ response[3];
    if (check != response[4]) {
        last_exchange_error = 2;
        goto done;
    }

    *response_status = response[1];
    *response_len = (uint16_t)response[2] |
                    ((uint16_t)response[3] << 8);
    if (*response_len > rx_capacity) {
        last_exchange_error = 3;
        goto done;
    }

    crc = 0xffffffffu;
    for (unsigned i = 0; i < *response_len; i++) {
        rx_data[i] = transfer_byte(0xff);
        crc = crc32_update(crc, rx_data[i]);
    }
    if (*response_len) {
        uint8_t crc_bytes[4];
        for (unsigned i = 0; i < 4; i++)
            crc_bytes[i] = transfer_byte(0xff);
        if ((crc ^ 0xffffffffu) != load_le32(crc_bytes)) {
            last_exchange_error = 4;
            goto done;
        }
    }
    result = 0;

done:
    *reg_cs |= GPIO_SET;
    *reg_clk |= GPIO_CLEAR;
    *reg_mosi |= GPIO_SET;
    if (mutex_locked)
        xSemaphoreGive(link_mutex);
    return result;
}

static int wait_for_status(uint8_t wanted, uint8_t diagnostic_stage)
{
    uint8_t payload[8];
    uint8_t status = 0xff;
    uint16_t length;

    for (unsigned retry = 0; retry < 500; retry++) {
        if (exchange(LINK_CMD_STATUS, 0, NULL, 0, payload,
                     sizeof(payload), &status, &length) == 0) {
            if (status == wanted)
                return 0;
            if (status != FPGA_STATUS_BUSY) {
                last_diagnostic = ((uint32_t)diagnostic_stage << 16) |
                                  ((uint32_t)status << 8) | payload[1];
                return -1;
            }
        }
    }
    last_diagnostic = ((uint32_t)diagnostic_stage << 16) |
                      ((uint32_t)status << 8) | last_exchange_error;
    return -2;
}

void fpga_link_init(void)
{
    gpio = bflb_device_get_by_name("gpio");
    bflb_gpio_init(gpio, GPIO_PIN_0,
                   GPIO_OUTPUT | GPIO_PULLUP | GPIO_SMT_EN | GPIO_DRV_2);
    bflb_gpio_init(gpio, GPIO_PIN_1,
                   GPIO_OUTPUT | GPIO_PULLDOWN | GPIO_SMT_EN | GPIO_DRV_2);
    bflb_gpio_init(gpio, GPIO_PIN_27,
                   GPIO_OUTPUT | GPIO_PULLUP | GPIO_SMT_EN | GPIO_DRV_2);
    bflb_gpio_init(gpio, GPIO_PIN_30,
                   GPIO_INPUT | GPIO_PULLUP | GPIO_SMT_EN | GPIO_DRV_2);

    *reg_cs |= GPIO_SET;
    *reg_clk |= GPIO_CLEAR;
    *reg_mosi |= GPIO_SET;
    link_mutex = xSemaphoreCreateMutex();
}

int fpga_link_get_capacity(uint32_t *block_count)
{
    uint8_t payload[8];
    uint8_t status;
    uint16_t length;

    if (exchange(LINK_CMD_INFO, 0, NULL, 0, payload, sizeof(payload),
                 &status, &length) || status != FPGA_STATUS_OK || length != 8)
        return -1;
    *block_count = load_le32(payload);
    return (*block_count != 0) ? 0 : -1;
}

int fpga_link_read_sector(uint32_t lba, uint8_t *data)
{
    uint8_t status = 0xff;
    uint16_t length = 0;

    last_diagnostic = 0;
    if (exchange(LINK_CMD_READ_START, lba, NULL, 0, NULL, 0,
                 &status, &length) || status != FPGA_STATUS_OK) {
        last_diagnostic = (1u << 16) | ((uint32_t)status << 8) |
                          last_exchange_error;
        return -1;
    }
    if (wait_for_status(FPGA_STATUS_READ_READY, 2))
        return -2;
    if (exchange(LINK_CMD_READ_DATA, 0, NULL, 0, data, 512,
                 &status, &length) || status != FPGA_STATUS_OK ||
        length != 512) {
        last_diagnostic = (3u << 16) | ((uint32_t)status << 8) |
                          last_exchange_error;
        return -3;
    }
    return 0;
}

int fpga_link_write_sector(uint32_t lba, const uint8_t *data)
{
    return fpga_link_write_blocks(lba, data, 1);
}

int fpga_link_write_blocks(uint32_t lba, const uint8_t *data,
                           uint8_t block_count)
{
    uint8_t status;
    uint16_t length;

    if (block_count == 0 || block_count > 8)
        return -1;
    if (exchange(LINK_CMD_WRITE_DATA, lba, data,
                 (uint16_t)block_count * 512u, NULL, 0,
                 &status, &length) || status != FPGA_STATUS_OK)
        return -1;
    return wait_for_status(FPGA_STATUS_OK, 4);
}

uint32_t fpga_link_last_diagnostic(void)
{
    return last_diagnostic;
}
