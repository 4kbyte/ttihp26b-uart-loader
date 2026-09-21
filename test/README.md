# Tests

Run `make` from this directory. The focused suite covers UART timing,
framing, RX FIFO behavior and TX backpressure; SPI initialization, mode, bit
order, address mapping, faults and reset boundaries; every loader command and
error; stream resynchronization; full memory boundaries; response stability;
wrapper pins; host framing, retry, recovery, image parsing, chunking, dump and
verify.
