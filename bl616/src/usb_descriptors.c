/* USB descriptors for SD-reader mode or recovery DirtyJTAG mode. */
#include <stdbool.h>
#include "usbd_core.h"
#include "usbd_msc.h"

#define MSC_IN_EP        0x81
#define MSC_OUT_EP       0x02
#define JTAG_OUT_EP      0x01
#define JTAG_IN_EP       0x82

#define USBD_VID         0x1209
#define USBD_PID         0xC0CA
#define USBD_MAX_POWER   100
#define MS_OS_VENDOR_CODE 0x20

#define MSC_CONFIG_SIZE  (9 + MSC_DESCRIPTOR_LEN)
#define JTAG_CONFIG_SIZE (9 + 9 + 7 + 7)

#ifdef CONFIG_USB_HS
#define MSC_MAX_MPS      512
#define JTAG_MAX_MPS     512
#else
#define MSC_MAX_MPS      64
#define JTAG_MAX_MPS     64
#endif

static const uint8_t device_descriptor[] = {
    USB_DEVICE_DESCRIPTOR_INIT(
        USB_2_0, 0x00, 0x00, 0x00,
        USBD_VID, USBD_PID, 0x0300, 0x01),
};

static const uint8_t jtag_device_descriptor[] = {
    USB_DEVICE_DESCRIPTOR_INIT(
        USB_2_0, 0x00, 0x00, 0x00,
        USBD_VID, USBD_PID, 0x0301, 0x01),
};

static const uint8_t msc_config_descriptor[] = {
    USB_CONFIG_DESCRIPTOR_INIT(
        MSC_CONFIG_SIZE, 0x01, 0x01,
        USB_CONFIG_BUS_POWERED, USBD_MAX_POWER),
    MSC_DESCRIPTOR_INIT(0x00, MSC_OUT_EP, MSC_IN_EP, MSC_MAX_MPS, 0x02),
};

static const uint8_t jtag_config_descriptor[] = {
    USB_CONFIG_DESCRIPTOR_INIT(
        JTAG_CONFIG_SIZE, 0x01, 0x01,
        USB_CONFIG_BUS_POWERED, USBD_MAX_POWER),
    USB_INTERFACE_DESCRIPTOR_INIT(
        0x00, 0x00, 0x02, 0xff, 0x00, 0x00, 0x02),
    USB_ENDPOINT_DESCRIPTOR_INIT(
        JTAG_OUT_EP, USB_ENDPOINT_TYPE_BULK, JTAG_MAX_MPS, 0x00),
    USB_ENDPOINT_DESCRIPTOR_INIT(
        JTAG_IN_EP, USB_ENDPOINT_TYPE_BULK, JTAG_MAX_MPS, 0x00),
};

static const uint8_t device_quality_descriptor[] = {
    0x0a,
    USB_DESCRIPTOR_TYPE_DEVICE_QUALIFIER,
    0x00, 0x02,
    0x00, 0x00, 0x00,
    0x40,
    0x00,
    0x00,
};

/*
 * Advertise WINUSB only for the recovery interface.  Windows then binds its
 * in-box WinUSB driver without Zadig or a locally signed INF.  Reader mode
 * deliberately uses a separate descriptor object without this compatibility
 * ID, so its MSC class driver remains untouched.
 */
static const uint8_t msosv1_string_descriptor[] = {
    USB_MSOSV1_STRING_DESCRIPTOR_INIT(MS_OS_VENDOR_CODE),
};

static const uint8_t msosv1_compat_id_descriptor[] = {
    USB_MSOSV1_COMP_ID_HEADER_DESCRIPTOR_INIT(1),
    USB_MSOSV1_COMP_ID_FUNCTION_WINUSB_DESCRIPTOR_INIT(0),
};

static const struct usb_msosv1_descriptor msosv1_descriptor = {
    .string = msosv1_string_descriptor,
    .vendor_code = MS_OS_VENDOR_CODE,
    .compat_id = msosv1_compat_id_descriptor,
    .comp_id_property = NULL,
};

static bool descriptor_reader_mode;
static const char language_id[] = { 0x09, 0x04 };

static const uint8_t *device_descriptor_callback(uint8_t speed)
{
    (void)speed;
    return descriptor_reader_mode ?
        device_descriptor : jtag_device_descriptor;
}

static const uint8_t *config_descriptor_callback(uint8_t speed)
{
    (void)speed;
    return descriptor_reader_mode ?
        msc_config_descriptor : jtag_config_descriptor;
}

static const uint8_t *device_quality_descriptor_callback(uint8_t speed)
{
    (void)speed;
    return device_quality_descriptor;
}

static const char *string_descriptor_callback(uint8_t speed, uint8_t index)
{
    (void)speed;
    switch (index) {
    case 0:
        return language_id;
    case 1:
        return "Sipeed";
    case 2:
        return descriptor_reader_mode ?
            "Tang Nano 20K SD Reader" : "Tang Nano 20K DirtyJTAG";
    case 3:
        return descriptor_reader_mode ?
            "TN20KSD3923" : "TN20KSD3923JTAG";
    default:
        return NULL;
    }
}

static const struct usb_descriptor msc_descriptor = {
    .device_descriptor_callback = device_descriptor_callback,
    .config_descriptor_callback = config_descriptor_callback,
    .device_quality_descriptor_callback = device_quality_descriptor_callback,
    .string_descriptor_callback = string_descriptor_callback,
};

static const struct usb_descriptor jtag_descriptor = {
    .device_descriptor_callback = device_descriptor_callback,
    .config_descriptor_callback = config_descriptor_callback,
    .device_quality_descriptor_callback = device_quality_descriptor_callback,
    .string_descriptor_callback = string_descriptor_callback,
    .msosv1_descriptor = &msosv1_descriptor,
};

void usb_descriptors_init(uint8_t busid, bool reader_mode)
{
    descriptor_reader_mode = reader_mode;
    usbd_desc_register(busid, reader_mode ?
                       &msc_descriptor : &jtag_descriptor);
}
