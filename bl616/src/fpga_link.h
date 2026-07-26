#ifndef FPGA_LINK_H
#define FPGA_LINK_H

#include <stdint.h>

enum fpga_link_status {
    FPGA_STATUS_OK = 0,
    FPGA_STATUS_BUSY = 1,
    FPGA_STATUS_READ_READY = 2,
    FPGA_STATUS_NOT_READY = 3,
    FPGA_STATUS_BAD_REQUEST = 4,
    FPGA_STATUS_IO_ERROR = 5,
    FPGA_STATUS_CRC_ERROR = 6,
};

void fpga_link_init(void);
int fpga_link_get_capacity(uint32_t *block_count);
int fpga_link_read_sector(uint32_t lba, uint8_t *data);
int fpga_link_read_blocks(uint32_t lba, uint8_t *data,
                          uint8_t block_count);
int fpga_link_read_two_batches(uint32_t first_lba, uint8_t *first_data,
                               uint8_t first_block_count,
                               uint32_t second_lba, uint8_t *second_data,
                               uint8_t second_block_count);
int fpga_link_write_sector(uint32_t lba, const uint8_t *data);
int fpga_link_write_blocks(uint32_t lba, const uint8_t *data,
                           uint8_t block_count);
uint32_t fpga_link_last_diagnostic(void);

#endif
