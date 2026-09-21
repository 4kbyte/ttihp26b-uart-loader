#!/usr/bin/env python3
"""Compile and run each focused RTL testbench."""

from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "test" / "build"


def run(
    top: str,
    sources: list[str],
    parameters: dict[str, int] | None = None,
    output_name: str | None = None,
) -> None:
    """Compile and run one named testbench."""
    iverilog, vvp = shutil.which("iverilog"), shutil.which("vvp")
    if not iverilog or not vvp:
        raise RuntimeError("iverilog and vvp are required")
    BUILD.mkdir(exist_ok=True)
    output = BUILD / f"{output_name or top}.vvp"
    parameter_arguments = [
        f"-P{top}.{name}={value}" for name, value in (parameters or {}).items()
    ]
    subprocess.run(
        [
            iverilog,
            "-g2012",
            "-Wall",
            "-s",
            top,
            *parameter_arguments,
            "-o",
            output,
            *sources,
        ],
        cwd=ROOT,
        check=True,
    )
    subprocess.run([vvp, output], cwd=ROOT, check=True)


def main() -> None:
    """Run the complete focused RTL suite."""
    run("uart_tb", ["src/uart.v", "test/uart_tb.sv"])
    run("spi_sram_tb", ["src/spi_sram.v", "test/spi_sram_tb.sv"])
    run("uart_loader_tb", ["src/uart_loader.v", "test/uart_loader_tb.sv"])
    run(
        "uart_loader_tb",
        ["src/uart_loader.v", "test/uart_loader_tb.sv"],
        {"MAX_TRANSFER_BYTES": 4},
        "uart_loader_parameter_tb",
    )
    run(
        "project_tb",
        [
            "src/uart.v",
            "src/uart_loader.v",
            "src/spi_sram.v",
            "src/project.v",
            "test/project_tb.sv",
        ],
    )


if __name__ == "__main__":
    main()
