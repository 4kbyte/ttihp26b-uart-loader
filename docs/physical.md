# IHP 2x2 physical implementation

The current byte-addressed UART SPI RAM loader was hardened at 50 MHz in the
official 2x2 allocation (`419.52 µm x 313.74 µm`). The flow requested a 70%
placement target. OpenROAD reported that the target was below the minimum
feasible density, then completed placement and routing at 82.026% final
standard-cell utilization.

## Reproducibility

| Input                   | Version                                                                   |
|-------------------------|---------------------------------------------------------------------------|
| Extracted source commit | `b39b061837488728da787811d429c9fdd7830240`                                |
| Allocation              | `2x2`                                                                     |
| Placement target        | `70%`                                                                     |
| tt-gds-action           | `7ef3d03f2ca2e4550306636a7b762fe128b09995`                                |
| tt-support-tools        | `01d5d2814fa9dd61e9d211e0b235a4a592a9316a`                                |
| LibreLane               | `3.0.5`                                                                   |
| Container               | `sha256:ecabd075d0ddf6a2bd1cd4a32109c7dbb861ec007f7e4e423a9a081f8d23b8e2` |
| Hardening PDK           | `c4b8b4e5e7a05f375cca3815d51b3a37721fbf5c`                                |
| Precheck PDK            | `22f43352dd8219f9007eb659e422e0d5fe28c5fb`                                |

## Measured result

The loader placed and routed with 7,488 standard cells, 103,914 µm²
standard-cell area, and 82.026% utilization. Setup slack was `+10.392 ns`
fast, `+9.653 ns` typical, and `+8.384 ns` slow. Worst hold slack was
`+0.114 ns`.

Max-slew and max-capacitance violations, setup and hold violations,
detailed-route DRC, antenna violations, Magic DRC, illegal overlaps, LVS
differences, critical disconnected pins, and power-grid violations were all
zero. Official precheck passed every check, including KLayout SG13G2 DRC,
boundary, pin, layer, cell-name, and netlist syntax checks.

Artifact SHA-256:

- GDS: `6e1584c4a875502d1a0e9bc351cbb635569487eed23c98c08576bc50d59af882`
- flattened netlist: `47135d695e3d39fc45dd509687d188276cced83ab08b43667ac3c64ccb7e6f39`
- DEF: `6c91aee2aaa6cc41584d265b0b2be07b551d0c170f948f9ad0b43171c9358177`

## Warnings

The run reports 53 max-fanout violations per timing corner, primarily
clock-tree loads; extracted timing remains positive and max capacitance is
clean. Fifteen unused wrapper input pins are disconnected, with zero critical
disconnections. The flow also reports unsupported LEF58 enclosure syntax,
while final route DRC, Magic DRC, and official precheck DRC all pass.
Block-level IR-drop results are indicative because package voltage-source
locations are absent.
