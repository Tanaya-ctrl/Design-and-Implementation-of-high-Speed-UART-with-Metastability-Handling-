// ============================================================================
// TOP MODULE - UART_ma
// ============================================================================
module UART_ma #(
    parameter TX_CLOCK_FREQ = 100_000_000,
    parameter RX_CLOCK_FREQ = 100_010_000,
    parameter BAUD_RATE = 4_000_000,
    parameter DATA_BITS = 8,
    parameter PARITY = "even",
    parameter STOP_BITS = 1,
    parameter ENABLE_CDC = 1,
    parameter INJECT_META = 0  // Pass this through to the RX module
)(
    input wire tx_clk,
    input wire rx_clk,
    input wire rst,
    input wire [DATA_BITS-1:0] tx_data,
    input wire tx_enable,
    output wire [DATA_BITS-1:0] rx_data,
    output wire rx_valid,
    output wire rx_parity_error,
    output wire tx_busy
);

    wire serial_line;
    
    uart_tx #(
        .CLOCK_FREQ(TX_CLOCK_FREQ),
        .BAUD_RATE(BAUD_RATE),
        .DATA_BITS(DATA_BITS),
        .PARITY(PARITY),
        .STOP_BITS(STOP_BITS)
    ) tx_inst (
        .clk(tx_clk),
        .rst(rst),
        .data_in(tx_data),
        .tx_enable(tx_enable),
        .serial_out(serial_line),
        .busy(tx_busy)
    );
    
    uart_rx #(
        .CLOCK_FREQ(RX_CLOCK_FREQ),
        .BAUD_RATE(BAUD_RATE),
        .DATA_BITS(DATA_BITS),
        .PARITY(PARITY),
        .STOP_BITS(STOP_BITS),
        .INJECT_META(INJECT_META)  // Control metastability injection
    ) rx_inst (
        .clk(rx_clk),
        .rst(rst),
        .serial_in(serial_line),
        .data_out(rx_data),
        .data_valid(rx_valid),
        .parity_error(rx_parity_error)
    );

endmodule
