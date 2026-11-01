# Modular Instrument Stack -- System Design Document

**Author:** Edd Buggins / Encal Ltd  
**Date:** June 2026  
**Status:** Concept -- pre-schematic  
**Related project:** Angus FPGA Combustion Analyser (github.com/eddnshoulders/Angus)

---

## 1. Vision

A professional-grade, open-source modular embedded instrument platform targeting:

- Engine combustion analysis (successor to Angus on PYNQ-Z2)
- Hardware-in-the-loop (HiL) stimulus and measurement for ECU development
- High-speed / high-accuracy data logging
- General embedded instrumentation

Intended as a genuine open-hardware alternative to proprietary systems such as Speedgoat Performance Target, AVL IndiCom, NI CompactRIO, and Rotec RT-Flex -- at a fraction of the cost and without vendor lock-in.

**Licensing intent:** CERN Open Hardware Licence. No liability. Use at own risk. Commercial support and customisation available through Encal Ltd.

---

## 2. Top-Level Architecture

The system consists of a stack of independent instrument bricks. Each brick is a self-contained PCB inside a machined aluminium enclosure. Bricks mate vertically via high-density mezzanine connectors and are mechanically secured by corner screws. The stack can be extended by adding bricks.

### 2.1 Brick types

| Brick | Function | Key ICs |
|---|---|---|
| SoM (foundation) | Processing, control, comms | Trenz TE0720 (Zynq XC7Z020) |
| ADC | 8ch simultaneous analogue input | AD7606C-18 |
| DAC (low voltage) | 8-32ch analogue output 0-5V | DAC80508 x1-4 |
| DAC (high voltage) | 16ch high-voltage analogue output | DAC81416 x1 + DAC80508 x1 |
| DIO | 16+ digital IO with selectable level shifting | TBD |

Additional brick types anticipated: high-speed ADC, high-speed DAC, isolated CAN, isolated power.

---

## 3. SoM Brick

### 3.1 Module selection

**Trenz TE0720** -- selected on the following basis:

- XC7Z020 (same silicon as PYNQ-Z2, Angus development platform -- direct port)
- 4x5cm form factor with Samtec LSHM mezzanine connectors
- On-module: DDR3, QSPI flash, GbE PHY, USB PHY, power management
- Well-documented upgrade path to TE0820 (Zynq UltraScale+ ZU2EG/ZU3EG) -- same 4x5cm footprint, mechanically compatible, largely electrically compatible per Trenz 4x5 Integration Guide
- UK-accessible supply, Western support, active community
- No eMMC required -- SD card on baseboard sufficient for 1-off/low volume use

### 3.2 Zynq architecture

- **PL (programmable logic):** all timing-critical, deterministic functions -- crank/cam decode, simultaneous ADC sampling, DAC update timing, DIO edge capture
- **PS (processing system):** data pipeline, Python/Flask/React GUI, logging, Ethernet comms
- This division of labour is the key architectural advantage over MCU-based designs (e.g. STM32H723) where the MCU becomes a bottleneck for high-speed digital signals

### 3.3 SoM brick front panel

- RJ45 Ethernet jack
- USB Type-C
- JTAG header (programming without disassembly)
- DC power input
- UART debug access

---

## 4. IO Brick Architecture

### 4.1 ADC brick -- AD7606C-18

- 8 channels, simultaneous sampling, 18-bit, 1MSPS per channel
- Input range: ±10V differential
- Interface: parallel (via FMC on Zedboard phase; direct PL parallel on custom baseboard)
- Analogue Devices reference HDL available for Xilinx targets
- INL: ±2 LSB typical
- SNR: ~98dB (18-bit)
- Front panel: 8x SMA inputs

**Sample rate / RPM headroom:**
At 0.1 degree crank angle resolution: 3600 samples/rev
1MSPS / 3600 = 277.8 rev/sec = 16,667 RPM maximum
Adequate for all anticipated engine applications.

### 4.2 DAC brick -- low voltage variant

- Up to 4x DAC80508 (8ch each = up to 32ch total, board size permitting)
- Output range: 0-5V (primary use case for ECU sensor simulation)
- Settling time: ~4.5us
- Effective update rate: ~220kHz per channel (SPI limited, well above analogue settling)
- 16-bit resolution
- SPI interface to PL
- Front panel: SMA outputs per channel

**Rationale for DAC80508 as primary:**
Real-world ECU HiL work (validated on Metier Vehicle Ltd programme) required only 0-5V range. The DAC80508 is significantly cheaper (~£8-10 vs ~£63 for DAC81416), faster settling, and lower risk during PCB assembly. 32 channels of 0-5V covers the vast majority of automotive sensor simulation requirements.

### 4.3 DAC brick -- high voltage variant

- 1x DAC81416 (16ch, ±20V/±10V/±5V/±2.5V/40V/20V/10V/5V per channel, independently configurable)
- 1x DAC80508 (8ch, 0-5V)
- Settling time: 12us (DAC81416), 4.5us (DAC80508)
- Effective update rate: ~80kHz (DAC81416, settling-time limited)
- Internal 2.5V reference (no external reference required)
- INL: ±1 LSB
- 25mA source/sink per channel
- SPI interface to PL
- Front panel: SMA outputs per channel

**Note:** The two DAC brick variants share a near-identical PCB layout -- designed in parallel as BOM variants of a single KiCad project. The DAC81416 layout block is already validated (MiniHiL DAC24 module v1.0).

**Waveform generation:** Implemented in PL BRAM using Xilinx DDS Compiler IP. No need for integrated DDS DAC parts -- the Zynq PL provides equivalent capability with full programmability from the PS.

---

## 5. Inter-brick Interface

### 5.1 Mezzanine connector

- Samtec LSHM series (same family as Trenz TE0720 SoM connectors)
- High pin density -- sufficient ground pins to minimise crosstalk
- Male protrudes from bottom surface of each brick
- Female recessed into top surface of each brick
- Connector mating controlled by corner screws -- defined, repeatable mating force
- Short vertical signal paths -- superior signal integrity vs side-by-side board-to-board over long runs (lesson from MiniHiL design)

### 5.2 Signal assignment principles

- Dense ground pin interleaving throughout
- Power distribution: local regulation per brick (not distributed from SoM)
- I2C for brick identification / presence detection
- High-speed signals (parallel ADC, parallel DAC) assigned to PL-connected pins
- SPI for slower DAC channels
- Layer addressing: resistor-strapped I2C ID per brick type

---

## 6. Mechanical Design

### 6.1 Brick enclosure

- Material: machined aluminium (6061), anodised
- External dimensions: approximately 100 x 100 x 30mm per brick
- Two machined half-shells clamping a connector end-plate block at the front face
- Connector block: machined aluminium or Delrin, mounted to PCB before connector soldering (acts as soldering jig for edge-mount SMA connectors, guarantees perpendicularity)
- Connector block carries all mechanical load from connector mating/unmating -- PCB pads are stress-relieved
- SMA connectors on front panel (not BNC -- size constraint); SMA-BNC adapter leads used where needed

### 6.2 Stack assembly

- Card-cage inspired insertion: bricks slide into the stack from one end along guide channels
- Alignment: dowel pins or chamfered guide features locate bricks before mezzanine connectors engage -- screws do clamping only, not alignment
- Separation: captive jack screws in case wall provide controlled parallel separation of mated bricks
- SoM brick: installed first, mates thermally and mechanically with case interior

### 6.3 Thermal management

- SoM brick mounts component-side down -- Zynq package conducts directly into the case floor (primary thermal mass)
- Case acts as heatsink via thermal interface material pad between Zynq lid and machined pocket in case floor
- High-dissipation IO bricks (DAC81416 in high-voltage mode) heatsink individually via their own case

### 6.4 Prototype progression

1. Design in Fusion 360 (parametric, GD&T-lite)
2. Prototype in Delrin on Carvera Air -- validate fit, connector alignment, insertion/extraction
3. Iterate until design is proven
4. Submit to JLCCNC or equivalent Chinese 5-axis CNC service for aluminium production
   - Estimated cost: £15-50 per brick at low volume
   - Precedent: complex H2 fuel rail (6-cyl, PFI injector seats, cross-drillings) manufactured for £700 shipped in 7 weeks

---

## 7. Software Architecture

- **OS:** PetaLinux / Yocto (Scarthgap 5.0 LTS) on Zynq PS
- **PL firmware:** VHDL, Vivado 2024.1
- **Application layer:** Python (numpy, scipy), Flask REST API
- **GUI:** React frontend
- **Data pipeline:** AXI DMA (S2MM), AXI4-Stream FIFO (4096 word), AXI4-Lite register map
- **Development environment:** Ubuntu 22.04 VM, GHDL/GTKWave for simulation, VSCodium

---

## 8. Development Roadmap

### Phase 1 -- PYNQ-Z2 (current)
- Angus core validation: XADC pressure input, crank/cam decode, DMA pipeline
- Flask/React GUI
- Peak detector validation
- PLL tuning validation

### Phase 2 -- Zedboard
- PetaLinux/Yocto migration
- AD7606C-18 FMC module integration (EVAL-AD7606CFMCZ on LPC connector)
- Migration from XADC to AD7606C-18

### Phase 3 -- Custom SoM baseboard
- Trenz TE0720 baseboard design
- DAC brick (low voltage variant first)
- DIO brick
- Card-cage enclosure design and Delrin prototype

### Phase 4 -- High voltage and expansion
- DAC brick high voltage variant
- Additional brick types as required
- Aluminium production enclosures

---

## 9. Key Design Decisions Log

| Decision | Rationale |
|---|---|
| Zynq 7020 not ZU+ | Sufficient headroom for all anticipated workloads; ZU+ cost/complexity not justified |
| Trenz TE0720 not Enclustra/MYIR | UK accessible, documented upgrade path, LSHM connector compatibility |
| No eMMC on SoM | SD card adequate for 1-off/low volume; easier image swapping in development |
| Mezzanine stack not side-by-side | Shorter signal paths, higher ground density, better signal integrity |
| Individual brick enclosures not monolithic card cage | User-serviceable, EMC per brick, controlled connector mating, no bare PCB handling |
| DAC80508 as primary DAC | Real-world validation shows 0-5V sufficient for ECU HiL; faster settling, lower cost, lower assembly risk than DAC81416 |
| DAC81416 as high-voltage variant | Unique voltage range flexibility (±20V per channel independently configurable) for non-automotive sensor simulation |
| Waveform generation in PL | Zynq DDS Compiler IP superior to integrated DDS DAC parts -- fully programmable, free |
| SMA not BNC | Size constraint; adapter leads used where BNC required |
| Connector block as SMA soldering jig | Guarantees connector perpendicularity; carries mechanical load away from PCB pads |
| CERN OHL licence | Standard open hardware licence with clear liability disclaimer |

---

## 10. Reusable Design Blocks (from MiniHiL programme)

- DAC81416 PCB layout (validated, MiniHiL DAC24 Module v1.0)
- Ethernet PHY and jack layout
- 3x isolated CAN transceiver block with isolated DC/DC

---

## 11. References

- Angus repo: github.com/eddnshoulders/Angus (branch: v3_dev)
- Trenz TE0720 TRM: wiki.trenz-electronic.de/display/PD/TE0720+TRM
- Trenz 4x5 Integration Guide: wiki.trenz-electronic.de/display/PD/4+x+5+SoM+Integration+Guide
- AD7606C-18 datasheet: analog.com
- DAC81416 datasheet: ti.com/product/DAC81416
- DAC80508 datasheet: ti.com/product/DAC80508
- CERN OHL: ohwr.org/project/cernohl
