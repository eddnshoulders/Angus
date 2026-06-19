# avg_direct.vhd functional summary

## Purpose

`avg_direct.vhd` produces a realtime averaged crank-angle profile for plotting. It is intended to sit beside `pack.vhd`, not after it:

```text
tdc/adc/di sample bus
    |-- pack.vhd        -> raw DMA stream / saved data
    `-- avg_direct.vhd  -> averaged realtime DMA stream
```

The saved data path keeps the original `tdc_deg` on every sample. The averaging path is therefore allowed to be resilient rather than perfect: it keeps running where possible and exposes error counters when input framing is imperfect.

## Input interface

The module consumes direct sample signals:

```vhdl
sample_valid : in  std_logic;
sample_ready : out std_logic;
tdc_deg      : in  unsigned(ADDR_W - 1 downto 0);
adc_ch0      : in  unsigned(11 downto 0);
di_in        : in  std_logic_vector(7 downto 0);
avg_n        : in  unsigned(1 downto 0);
```

`tdc_deg` is the authoritative accumulation address. The internal expected-bin counter is used only to validate sequence continuity and to count errors.

## Output format

The output AXI stream is compatible with the two-word sample format used by `pack.vhd`:

```text
word0 = bin index / tdc_deg as 32-bit unsigned
word1 = DI[31:24] | 0x00[23:16] | adc_avg[15:4] | 0x0[3:0]
```

`tlast` is asserted on word1 of the final bin.

## Averaging behaviour

`avg_n` means `2^avg_n` complete input frames per averaged output frame:

```text
avg_n = 0 -> 1 frame
avg_n = 1 -> 2 frames
avg_n = 2 -> 4 frames
avg_n = 3 -> 8 frames
```

`avg_n = 0` still uses the binning path. There is deliberately no bypass path. This keeps one input parser, one bank manager, one output packetiser and one DMA timing behaviour.

The averaged pressure is calculated as:

```text
adc_avg = sum >> latched_avg_n
```

`avg_n` is latched only when a new accumulation bank is claimed. Changing `avg_n` during an active averaging window does not affect the current window.

## Binning and resynchronisation policy

The write address is always `tdc_deg`, not an internal counter. This prevents a missed sample from shifting all subsequent data.

The expected-bin counter checks the input sequence:

```text
if tdc_deg = expected_bin:
    normal sample

if tdc_deg > expected_bin:
    one or more samples were missed
    missed_sample_count += tdc_deg - expected_bin
    write the current sample to tdc_deg anyway
    resync expected_bin to tdc_deg + 1

if tdc_deg < expected_bin:
    this is normally a frame wrap
    if tdc_deg /= 0, increment out_of_order_count
    write the current sample to tdc_deg anyway
    resync expected_bin to tdc_deg + 1
```

Bad data should be visible, not contagious. A missed sample causes a local under-sampled bin in the realtime average, and the counter records that it happened. It does not corrupt the angular alignment of later bins.

## Buffering

The design uses two ping-pong banks. One bank accumulates incoming samples while the other can be streamed and cleared.

Bank lifecycle:

```text
EMPTY -> ACCUM -> FULL -> STREAM -> CLEAR -> EMPTY
```

If an averaging window completes but the other bank is not empty, `bank_overrun_count` increments.

## Error/status counters

The module exposes counters intended for AXI-lite registers:

```vhdl
frames_in_count
frames_out_count
samples_in_count
missed_sample_count
out_of_order_count
bank_overrun_count
dropped_sample_count
out_stall_count
```

`dropped_sample_count` increments if `sample_valid` is asserted when `sample_ready` is low. At the intended 20,000 rpm, 0.1 degree maximum rate, samples arrive at 2.4 MS/s. At 100 MHz this gives about 41 clocks per sample, while the accumulator takes only a few clocks per sample, so this counter should remain zero in normal operation.

## Testbench

`avg_direct_tb.vhd` instantiates the module with a small bin count for fast simulation. It checks:

1. reset;
2. `avg_n=0` through the binning path;
3. `avg_n=1` latching at the start of a new accumulation cycle;
4. missed-sample counter behaviour.

The testbench uses the same ready/valid protocol as the module and waits for AXI output handshakes before checking each word.
