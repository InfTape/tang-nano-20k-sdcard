`timescale 1ns/1ps
`default_nettype none

// Tang Nano 20K rPLL: 27 MHz -> 48 MHz.
// PFD = 27 / 9 = 3 MHz, CLKOUT = 27 * 16 / 9 = 48 MHz,
// VCO = 48 * 16 = 768 MHz.
module pll_48m (
    input  wire clkin,
    output wire clkout,
    output wire lock
);
    wire clkoutp_unused;
    wire clkoutd_unused;
    wire clkoutd3_unused;
    wire ground = 1'b0;

    rPLL pll_i (
        .CLKOUT(clkout),
        .LOCK(lock),
        .CLKOUTP(clkoutp_unused),
        .CLKOUTD(clkoutd_unused),
        .CLKOUTD3(clkoutd3_unused),
        .RESET(ground),
        .RESET_P(ground),
        .CLKIN(clkin),
        .CLKFB(ground),
        .FBDSEL(6'b000000),
        .IDSEL(6'b000000),
        .ODSEL(6'b000000),
        .PSDA(4'b0000),
        .DUTYDA(4'b0000),
        .FDLY(4'b0000)
    );

    defparam pll_i.FCLKIN = "27";
    defparam pll_i.DEVICE = "GW2AR-18C";
    defparam pll_i.DYN_IDIV_SEL = "false";
    defparam pll_i.IDIV_SEL = 8;
    defparam pll_i.DYN_FBDIV_SEL = "false";
    defparam pll_i.FBDIV_SEL = 15;
    defparam pll_i.DYN_ODIV_SEL = "false";
    defparam pll_i.ODIV_SEL = 16;
    defparam pll_i.PSDA_SEL = "0000";
    defparam pll_i.DYN_DA_EN = "false";
    defparam pll_i.DUTYDA_SEL = "1000";
    defparam pll_i.CLKOUT_FT_DIR = 1'b1;
    defparam pll_i.CLKOUTP_FT_DIR = 1'b1;
    defparam pll_i.CLKOUT_DLY_STEP = 0;
    defparam pll_i.CLKOUTP_DLY_STEP = 0;
    defparam pll_i.CLKFB_SEL = "internal";
    defparam pll_i.CLKOUT_BYPASS = "false";
    defparam pll_i.CLKOUTP_BYPASS = "false";
    defparam pll_i.CLKOUTD_BYPASS = "false";
    defparam pll_i.DYN_SDIV_SEL = 2;
    defparam pll_i.CLKOUTD_SRC = "CLKOUT";
    defparam pll_i.CLKOUTD3_SRC = "CLKOUT";
endmodule

`default_nettype wire
