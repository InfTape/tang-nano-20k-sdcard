create_clock -name clk_27m -period 37.037 -waveform {0 18.518} [get_ports {clk}]
create_clock -name spi_sclk -period 50.000 -waveform {0 25.000} [get_ports {spi_sclk}]
set_clock_groups -asynchronous -group [get_clocks {clk_27m}] -group [get_clocks {spi_sclk}]
