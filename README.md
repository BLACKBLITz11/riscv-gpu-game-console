# RISC-V GPU Game Console

A hobby game console built from scratch: a custom RV32I CPU and a custom 32-core GPU, running a swarm shooter demo. Everything works in simulation (Icarus Verilog + Python).

## Folders
- cpu/  : RV32I CPU (rtl, tb, sw with the assembler and game.asm)
- gpu/  : 32-core GPU (rtl, tb, sw with the assembler and entity_update.asm)
- sim/  : Python tools and simulation servers

## Run the demo (from the sim folder)
    python cpu_host.py
    python test_shots.py
    python game_cpu.py --headless --bot --frames 400
    python game_cpu.py

Requires Icarus Verilog (iverilog/vvp) and Python 3.

Run all GPU testbenches from the repo root: powershell -ExecutionPolicy Bypass -File .\run_tests.ps1
