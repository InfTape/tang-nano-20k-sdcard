/*
 * Private BL616 <-> FPGA link on the Tang Nano 20K.
 *
 * Tang Nano 20K v3923 private link:
 * GPIO0 CS (board net SPI_DIR), GPIO1 SCLK, GPIO27 MOSI, GPIO30 MISO.
 * The BL616 is a mode-0 SPI0 master with software-controlled chip select.
 */
#include <stdbool.h>
#include <stddef.h>

#include "bflb_gpio.h"
#include "bflb_mtimer.h"
#include "bflb_spi.h"
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

#define LINK_READ_STATUS_TIMEOUT_US   1000000u
#define LINK_WRITE_STATUS_TIMEOUT_US  5000000u

#ifndef FPGA_LINK_USE_HW_SPI
#define FPGA_LINK_USE_HW_SPI 1
#endif

#ifndef FPGA_LINK_SPI_FREQUENCY
#define FPGA_LINK_SPI_FREQUENCY 6000000u
#endif

#if FPGA_LINK_USE_HW_SPI
#define LINK_SHORT_RESPONSE_WAIT_US       5u
#define LINK_BLOCK_RESPONSE_WAIT_US      35u
#define LINK_SPI_IDLE_TIMEOUT_US       20000u
#else
#define LINK_DELAY_ITERATIONS          8u
#define LINK_SHORT_RESPONSE_WAIT     256u
#define LINK_BLOCK_RESPONSE_WAIT_PER_SECTOR 5000u

#define GPIO_SET   (1u << 25)
#define GPIO_CLEAR (1u << 26)
#define GPIO_READ  (1u << 28)

static volatile uint32_t *const reg_cs   = (volatile uint32_t *)0x200008c4;
static volatile uint32_t *const reg_clk  = (volatile uint32_t *)0x200008c8;
static volatile uint32_t *const reg_mosi = (volatile uint32_t *)0x20000930;
static volatile uint32_t *const reg_miso = (volatile uint32_t *)0x2000093c;
#endif

static struct bflb_device_s *gpio;
#if FPGA_LINK_USE_HW_SPI
static struct bflb_device_s *spi0;
#endif
static SemaphoreHandle_t link_mutex;
static SemaphoreHandle_t operation_mutex;
static volatile uint8_t last_exchange_error;
static volatile uint32_t last_diagnostic;

#if FPGA_LINK_USE_HW_SPI
static int wait_spi_idle(void)
{
    uint64_t deadline =
        bflb_mtimer_get_time_us() + LINK_SPI_IDLE_TIMEOUT_US;

    while (bflb_spi_isbusy(spi0)) {
        if (bflb_mtimer_get_time_us() >= deadline)
            return -1;
    }
    return 0;
}

static uint8_t transfer_byte(uint8_t value)
{
    return (uint8_t)bflb_spi_poll_send(spi0, value);
}

static int transfer_buffer(const uint8_t *tx_data, uint8_t *rx_data,
                           size_t length)
{
    return bflb_spi_poll_exchange(spi0, tx_data, rx_data, length);
}

static int link_begin(void)
{
    if (wait_spi_idle())
        return -1;
    bflb_gpio_reset(gpio, GPIO_PIN_0);
    bflb_mtimer_delay_us(1);
    return 0;
}

static int link_end(void)
{
    int result = wait_spi_idle();
    bflb_gpio_set(gpio, GPIO_PIN_0);
    return result;
}

static void wait_for_response(uint16_t rx_capacity)
{
    if (rx_capacity >= 512) {
        unsigned sectors = (unsigned)rx_capacity / 512u;
        bflb_mtimer_delay_us(sectors * LINK_BLOCK_RESPONSE_WAIT_US);
    } else {
        bflb_mtimer_delay_us(LINK_SHORT_RESPONSE_WAIT_US);
    }
}
#else
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

static int transfer_buffer(const uint8_t *tx_data, uint8_t *rx_data,
                           size_t length)
{
    for (size_t i = 0; i < length; i++) {
        uint8_t received = transfer_byte(tx_data ? tx_data[i] : 0xff);
        if (rx_data)
            rx_data[i] = received;
    }
    return 0;
}

static int link_begin(void)
{
    *reg_clk |= GPIO_CLEAR;
    *reg_cs |= GPIO_CLEAR;
    *reg_mosi |= GPIO_SET;
    link_delay();
    return 0;
}

static int link_end(void)
{
    *reg_cs |= GPIO_SET;
    *reg_clk |= GPIO_CLEAR;
    *reg_mosi |= GPIO_SET;
    return 0;
}

static void wait_for_response(uint16_t rx_capacity)
{
    unsigned response_wait = rx_capacity >= 512 ?
        ((unsigned)rx_capacity / 512u) *
            LINK_BLOCK_RESPONSE_WAIT_PER_SECTOR :
        LINK_SHORT_RESPONSE_WAIT;
    for (volatile unsigned i = 0; i < response_wait; i++)
        __asm__ volatile("nop");
}
#endif

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
                    const uint8_t *tx_data, uint16_t request_length,
                    uint8_t *rx_data, uint16_t rx_capacity,
                    uint8_t *response_status, uint16_t *response_len)
{
    uint8_t header[9];
    uint8_t response[5];
    uint8_t check = 0;
    uint32_t crc = 0xffffffffu;
#if !FPGA_LINK_USE_HW_SPI
    uint8_t response_scan = 0xff;
#endif
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
    header[6] = (uint8_t)request_length;
    header[7] = (uint8_t)(request_length >> 8);
    for (unsigned i = 0; i < 8; i++)
        check ^= header[i];
    header[8] = check;

    if (link_begin()) {
        last_exchange_error = 5;
        goto done;
    }
    if (transfer_buffer(header, NULL, sizeof(header))) {
        last_exchange_error = 5;
        goto done;
    }
    if (tx_data) {
        for (unsigned i = 0; i < request_length; i++)
            crc = crc32_update(crc, tx_data[i]);
        if (transfer_buffer(tx_data, NULL, request_length)) {
            last_exchange_error = 5;
            goto done;
        }
        crc ^= 0xffffffffu;
        uint8_t crc_bytes[4];
        store_le32(crc_bytes, crc);
        if (transfer_buffer(crc_bytes, NULL, sizeof(crc_bytes))) {
            last_exchange_error = 5;
            goto done;
        }
    }

    wait_for_response(rx_capacity);

    /* Clocks stop while the FPGA prepares its response. */
#if FPGA_LINK_USE_HW_SPI
    /* Hardware SPI must find the response on an eight-bit frame boundary. */
    for (unsigned i = 0; i < 8; i++) {
        response[0] = transfer_byte(0xff);
        if (response[0] == LINK_MAGIC_RESPONSE) {
            found = 1;
            break;
        }
    }
#else
    /*
     * The synchronized bit-bang path can start between byte boundaries, so
     * retain its original bitwise response-magic search.
     */
    for (unsigned i = 0; i < 64; i++) {
        response_scan = (uint8_t)((response_scan << 1) | transfer_bit(1));
        if (response_scan == LINK_MAGIC_RESPONSE) {
            response[0] = response_scan;
            found = 1;
            break;
        }
    }
#endif
    if (!found) {
        last_exchange_error = 1;
        goto done;
    }

    if (transfer_buffer(NULL, &response[1], sizeof(response) - 1)) {
        last_exchange_error = 5;
        goto done;
    }
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
    if (*response_len &&
        transfer_buffer(NULL, rx_data, *response_len)) {
        last_exchange_error = 5;
        goto done;
    }
    for (unsigned i = 0; i < *response_len; i++)
        crc = crc32_update(crc, rx_data[i]);
    if (*response_len) {
        uint8_t crc_bytes[4];
        if (transfer_buffer(NULL, crc_bytes, sizeof(crc_bytes))) {
            last_exchange_error = 5;
            goto done;
        }
        if ((crc ^ 0xffffffffu) != load_le32(crc_bytes)) {
            last_exchange_error = 4;
            goto done;
        }
    }
    result = 0;

done:
    if (link_end() && result == 0) {
        last_exchange_error = 5;
        result = -2;
    }
    if (mutex_locked)
        xSemaphoreGive(link_mutex);
    return result;
}

static int wait_for_status(uint8_t wanted, uint8_t diagnostic_stage)
{
    uint8_t payload[8];
    uint8_t status = 0xff;
    uint16_t length;
    uint32_t timeout_us = diagnostic_stage == 4 ?
        LINK_WRITE_STATUS_TIMEOUT_US : LINK_READ_STATUS_TIMEOUT_US;
    uint64_t deadline = bflb_mtimer_get_time_us() + timeout_us;

    do {
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

        /*
         * A multi-block SD write can stay busy for hundreds of milliseconds
         * while the card erases or folds flash pages.  Yield between write
         * polls so the USB stack remains responsive.  Reads normally finish
         * in a few milliseconds and retain fine-grained polling.
         */
        if (diagnostic_stage == 4 &&
            xTaskGetSchedulerState() == taskSCHEDULER_RUNNING)
            vTaskDelay(pdMS_TO_TICKS(1));
        else
            bflb_mtimer_delay_us(50);
    } while (bflb_mtimer_get_time_us() < deadline);

    last_diagnostic = ((uint32_t)diagnostic_stage << 16) |
                      ((uint32_t)status << 8) | last_exchange_error;
    return -2;
}

static bool operation_begin(void)
{
    if (!operation_mutex ||
        xTaskGetSchedulerState() != taskSCHEDULER_RUNNING)
        return true;
    return xSemaphoreTake(operation_mutex,
                          pdMS_TO_TICKS(2000)) == pdTRUE;
}

static void operation_end(void)
{
    if (operation_mutex &&
        xTaskGetSchedulerState() == taskSCHEDULER_RUNNING)
        xSemaphoreGive(operation_mutex);
}

void fpga_link_init(void)
{
    gpio = bflb_device_get_by_name("gpio");
    bflb_gpio_init(gpio, GPIO_PIN_0,
                   GPIO_OUTPUT | GPIO_PULLUP | GPIO_SMT_EN | GPIO_DRV_2);
#if FPGA_LINK_USE_HW_SPI
    bflb_gpio_set(gpio, GPIO_PIN_0);
    bflb_gpio_init(gpio, GPIO_PIN_1,
                   GPIO_FUNC_SPI0 | GPIO_ALTERNATE | GPIO_PULLDOWN |
                   GPIO_SMT_EN | GPIO_DRV_2);
    bflb_gpio_init(gpio, GPIO_PIN_27,
                   GPIO_FUNC_SPI0 | GPIO_ALTERNATE | GPIO_PULLUP |
                   GPIO_SMT_EN | GPIO_DRV_2);
    bflb_gpio_init(gpio, GPIO_PIN_30,
                   GPIO_FUNC_SPI0 | GPIO_ALTERNATE | GPIO_PULLUP |
                   GPIO_SMT_EN | GPIO_DRV_2);

    struct bflb_spi_config_s spi_config = {
        .freq = FPGA_LINK_SPI_FREQUENCY,
        .role = SPI_ROLE_MASTER,
        .mode = SPI_MODE0,
        .data_width = SPI_DATA_WIDTH_8BIT,
        .bit_order = SPI_BIT_MSB,
        .byte_order = SPI_BYTE_LSB,
        .tx_fifo_threshold = 0,
        .rx_fifo_threshold = 0,
    };
    spi0 = bflb_device_get_by_name("spi0");
    bflb_spi_init(spi0, &spi_config);
    bflb_spi_feature_control(spi0, SPI_CMD_SET_CS_INTERVAL, true);
#else
    bflb_gpio_init(gpio, GPIO_PIN_1,
                   GPIO_OUTPUT | GPIO_PULLDOWN | GPIO_SMT_EN | GPIO_DRV_2);
    bflb_gpio_init(gpio, GPIO_PIN_27,
                   GPIO_OUTPUT | GPIO_PULLUP | GPIO_SMT_EN | GPIO_DRV_2);
    bflb_gpio_init(gpio, GPIO_PIN_30,
                   GPIO_INPUT | GPIO_PULLUP | GPIO_SMT_EN | GPIO_DRV_2);
    *reg_cs |= GPIO_SET;
    *reg_clk |= GPIO_CLEAR;
    *reg_mosi |= GPIO_SET;
#endif
    link_mutex = xSemaphoreCreateMutex();
    operation_mutex = xSemaphoreCreateMutex();
}

int fpga_link_get_capacity(uint32_t *block_count)
{
    uint8_t payload[8];
    uint8_t status;
    uint16_t length;

    if (!operation_begin())
        return -1;
    int result = exchange(LINK_CMD_INFO, 0, NULL, 0, payload,
                          sizeof(payload), &status, &length);
    operation_end();
    if (result || status != FPGA_STATUS_OK || length != 8)
        return -1;
    *block_count = load_le32(payload);
    return (*block_count != 0) ? 0 : -1;
}

int fpga_link_read_sector(uint32_t lba, uint8_t *data)
{
    return fpga_link_read_blocks(lba, data, 1);
}

static int read_start(uint32_t lba, uint8_t block_count)
{
    uint8_t status = 0xff;
    uint16_t length = 0;
    uint16_t transfer_length = (uint16_t)block_count * 512u;

    if (exchange(LINK_CMD_READ_START, lba, NULL, transfer_length, NULL, 0,
                 &status, &length) || status != FPGA_STATUS_OK) {
        last_diagnostic = (1u << 16) | ((uint32_t)status << 8) |
                          last_exchange_error;
        return -1;
    }
    return 0;
}

static int read_data(uint8_t *data, uint8_t block_count)
{
    uint8_t status = 0xff;
    uint16_t length = 0;
    uint16_t transfer_length = (uint16_t)block_count * 512u;

    if (exchange(LINK_CMD_READ_DATA, 0, NULL, 0, data, transfer_length,
                 &status, &length) || status != FPGA_STATUS_OK ||
        length != transfer_length) {
        last_diagnostic = (3u << 16) | ((uint32_t)status << 8) |
                          last_exchange_error;
        return -3;
    }
    return 0;
}

int fpga_link_read_blocks(uint32_t lba, uint8_t *data,
                          uint8_t block_count)
{
    int result;

    if (block_count == 0 || block_count > 32 || !operation_begin())
        return -1;
    last_diagnostic = 0;
    result = read_start(lba, block_count);
    if (result == 0 &&
        wait_for_status(FPGA_STATUS_READ_READY, 2))
        result = -2;
    if (result == 0)
        result = read_data(data, block_count);
    operation_end();
    return result;
}

int fpga_link_read_two_batches(uint32_t first_lba, uint8_t *first_data,
                               uint8_t first_block_count,
                               uint32_t second_lba, uint8_t *second_data,
                               uint8_t second_block_count)
{
    int result;

    if (first_block_count == 0 || first_block_count > 32 ||
        second_block_count == 0 || second_block_count > 32 ||
        !operation_begin())
        return -1;

    last_diagnostic = 0;
    result = read_start(first_lba, first_block_count);
    if (result == 0 &&
        wait_for_status(FPGA_STATUS_READ_READY, 2))
        result = -2;
    if (result == 0)
        result = read_start(second_lba, second_block_count);
    if (result == 0)
        result = read_data(first_data, first_block_count);
    if (result == 0 &&
        wait_for_status(FPGA_STATUS_READ_READY, 2))
        result = -2;
    if (result == 0)
        result = read_data(second_data, second_block_count);
    operation_end();
    return result;
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
    int result;

    if (block_count == 0 || block_count > 32 || !operation_begin())
        return -1;
    result = exchange(LINK_CMD_WRITE_DATA, lba, data,
                      (uint16_t)block_count * 512u, NULL, 0,
                      &status, &length);
    if (result == 0 && status != FPGA_STATUS_OK)
        result = -1;
    if (result == 0)
        result = wait_for_status(FPGA_STATUS_OK, 4);
    operation_end();
    return result;
}

uint32_t fpga_link_last_diagnostic(void)
{
    return last_diagnostic;
}
