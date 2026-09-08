# iCESugar v1.5 Wiring

Target FPGA: Lattice iCE40UP5K-SG48. Board connector names below follow the
iCESugar v1.5 schematic, **not generic PMOD numbering**. Disconnect power
before changing connections.

The 16-pin Arducam module labels supplied for the tested hardware are:

```text
VCC XCLK D1  D2   D3   TRIG INT GND
VCC SCL  SDA VSYNC HREF PCLK D0  GND
```

Use the module's signal labels to identify pins. This text is not a guarantee
of header orientation or odd/even numbering when viewed from the back.

| Camera label | iCESugar connector | FPGA SG48 pin |
| --- | --- | ---: |
| D0 | P1_1 | 10 |
| D1 | P2_1 | 46 |
| D2 | P1_3 | 3 |
| D3 | P1_4 | 48 |
| PCLK | P3_1 | 34 |
| VSYNC | P3_2 | 31 |
| HREF | P3_3 | 27 |
| INT | P3_4 | 25 |
| XCLK | P3_9, FPGA input only | 23 |
| TRIG | P3_10, held low | 26 |
| SCL | P3_11, open drain | 28 |
| SDA | P3_12, open drain | 32 |
| Both VCC | Board 3.3 V supply | Not GPIO |
| Both GND | Board GND | Not GPIO |

Constraints: [camera.pcf](../constraints/camera.pcf). Built-in iCELink UART uses
FPGA RX pin 4 and TX pin 6. Fit both UART jumpers and leave P1_2 / P1_11 free
of camera signals. In particular, do not connect camera D1 to P1_2.

## Voltage And Clock

The UC-805/B0315 schematic matching this module has:

- 3.3 V module supply, with sensor I/O internally regulated to 2.8 V.
- SCL/SDA pull-ups of 4.7 kohm to 2.8 V. Do not add 3.3 V pull-ups.
- A 24 MHz oscillator directly connected to XCLK through R1 (0 ohms).

**Never drive the module's XCLK from the FPGA.** `rtl/top.v` makes that port
input-only. SCL/SDA are driven low or released, not driven high. TRIG is held
low because this project uses I2C-controlled streaming. INT is observed but
not used to trigger frame capture. Keep wires short and provide a common ground.

Different Arducam module revisions can have different clock/power circuits.
Verify their schematics rather than applying this mapping by sensor name alone.

## Primary Sources

- [iCESugar v1.5 schematic](https://github.com/wuxx/icesugar/blob/master/schematic/iCESugar-v1.5.pdf)
- [Board pin constraints](https://github.com/wuxx/icesugar/blob/master/src/common/io.pcf)
- [Arducam UC-805 schematic](https://www.uctronics.com/download/Schematic/UC-805_SCH.pdf)
- [Arducam module documentation](https://docs.arducam.com/Arduino-SPI-camera/Legacy-SPI-camera/Pico/Camera-Module/Arducam-HM01B0-QVGA-Camera-Module/)
