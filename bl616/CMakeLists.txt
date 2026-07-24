cmake_minimum_required(VERSION 3.15)

set(CONFIG_FREERTOS 1)
set(CONFIG_CHERRYUSB 1)
set(CONFIG_CHERRYUSB_DEVICE 1)
set(CONFIG_CHERRYUSB_DEVICE_MSC 1)
set(CONFIG_CHERRYUSB_OSAL "freertos")

find_package(bouffalo_sdk REQUIRED HINTS $ENV{BL_SDK_BASE})

sdk_add_include_directories(. src)
sdk_add_compile_definitions(-DCONFIG_USB_HS)

target_sources(app PRIVATE
    src/usb_descriptors.c
    src/dirtyjtag.c
    src/jtag_gpio.c
    src/fpga_link.c
    src/msc_bridge.c
)

sdk_set_main_file(src/main.c)

project(bl616_dirtyjtag)
