# CAN FD CANHack — Status, Fixes and Hardware Test Plan

This note records the result of an audit of the CAN FD extension of the CANHack toolkit
(branch `canfd`, the 2024 re-port of Fynn Denecke's thesis work onto MicroPython v1.22.2),
the fixes applied, and a bring-up procedure for validating on real hardware
(PEAK PCAN-USB FD as the counterpart, Siglent SDS1104X-E as the scope).

Fixed bit rates throughout: **500 kbit/s arbitration, 2 Mbit/s data** (4× switch via BRS).
A fully Classical-CAN-equivalent feature set for CAN FD is *not* expected to be reachable with
software bit-banging; the goals below are the maximum realistically achievable.

## TL;DR

* The **CAN FD frame builder is correct.** The CRC-17/CRC-21, the stuff-count (SBC) field and
  the fixed/dynamic stuff-bit handling were verified byte-for-byte against an independent
  receiver-side implementation for 9 frame configurations (standard/extended, 8/16/20/64-byte
  payloads, all-zero and all-ones data). The `"problems w/ crc according to PCAN Diag"` noted in
  the last commit is therefore **not** a frame-construction bug.
* The remaining risk is in the **transmit timing**: the 2 Mbit/s data phase gives only
  125 CPU cycles per bit, and the 250 MHz overclock was running at the RP2040's default core
  voltage, which is marginal. A glitching CPU corrupts individual data-phase bits, which a
  receiver reports as a CRC/form error. **Fix applied: raise the core voltage to 1.20 V before
  the overclock** (see below). This is the most likely cause of the PCAN CRC reports.
* One real logic bug was found and fixed in the BRS variant of the error/double-receive/freeze
  attack (`=- 1` → `-= 1`).

## What was verified (and how)

The builder (`canhack_set_frame`, `do_crc`/`do_crc17`/`do_crc21`, `add_bit`, `add_raw_bit`) is
pure portable C with no hardware dependency. It was extracted and compiled on a host, used to
build frames, and the resulting on-wire bit streams were checked by an independent Python
reimplementation of the CAN FD receiver CRC:

* CRC-17 polynomial `0x1685B`, CRC-21 polynomial `0x102899`, both with the CAN FD non-zero
  initialisation (`1 << (n-1)`). (The source stores them as `0x3685B`/`0x302899`; the extra
  high bit is shifted out and masked away each step, so the effective polynomials are correct.)
* CRC input = SOF … end-of-data **including dynamic stuff bits** + the 4-bit stuff count,
  **excluding all fixed stuff bits** — matching ISO 11898-1:2015.
* Stuff count = (number of dynamic stuff bits) mod 8, 3-bit Gray coded + even parity.

All 9 test frames produced a transmitted CRC that matches the independent calculation, and an
independent dynamic-stuff count that matches the emitted SBC. Conclusion: the bytes the
firmware intends to put on the wire form a valid CAN FD frame.

## Fixes applied on this branch

1. **`CANPico/firmware/src/main.c` — core-voltage boost before the 250 MHz overclock.**
   `vreg_set_voltage(VREG_VOLTAGE_1_20); sleep_ms(2);` is now done before
   `set_sys_clock_khz(250000, true)` (both still guarded by `#ifdef CANHACK_FD`). The RP2040 is
   not reliably stable at 250 MHz on the default 1.10 V core; the hand-timed FD bit stream is
   exactly the kind of workload that exposes CPU glitches, and a single corrupted data-phase bit
   makes the receiver reject the frame as a CRC error. This is the prime suspect for the PCAN
   observation and costs nothing to apply.

2. **`CANPico/firmware/src/canis/canhack.c` — `=- 1` typo in `canhack_error_attack`.**
   For BRS frames the EOF match/mask are 4× expanded for the fast phase by shifting a single set
   bit to position `4·N`; the code then wrote `eof_mask_brs =- 1;` / `eof_match_brs =- 1;`, which
   C parses as *assign* `-1`, wiping out the computed value. Changed to `-= 1;`, which turns the
   single bit into the intended run of `4·N` ones. Affects the Double-Receive and Freeze-Doom-Loop
   attacks **on BRS CAN FD frames only**; classical-CAN and non-BRS behaviour were unaffected by
   the bug.

3. **`CANPico/firmware/README.txt` — documented the `CANHACK_FD` build module.** It was present in
   `CMakeLists.txt` but never written up, so the FD firmware could not be built from the docs
   alone. The build recipe for a plain Pico + transceiver is now included.

Nothing was changed in the transmit timing logic itself (`send_bits`): its structure is sound and
any change there needs a scope to validate, so it is left for hardware bring-up.

## Known limitations / still open (need hardware)

* **Janus attack on CAN FD** is inherently marginal: in the 2 Mbit/s phase the sync→split window
  is only ~47 cycles, below what the thesis already found unreliable. Expect occasional
  error-flagged Janus frames in the data phase. The classical-CAN Janus attack is unaffected.
* **Data-phase execution headroom.** Even at 1.20 V / 250 MHz the `send_bits` fast loop must do
  `SET_CAN_TX` + bookkeeping within 125 cycles. The nested-loop structure already minimises this;
  if the scope shows jitter on data-phase edges, that is the limit being hit.
* **BRS attack masks beyond 32 bits.** The Freeze-Doom-Loop uses a 9-bit nominal EOF mask; its 4×
  expansion (36 bits) is truncated to the 32-bit `bitstream32`. The attack still roughly detects
  the recessive run but the match is not exact; harmless for the common attacks (error/double
  receive) whose masks fit in 32 bits.

## Hardware bring-up / test plan

Counterpart: PEAK PCAN-USB FD set to **500 kbit/s nominal, 2 Mbit/s data**, on a bus with two
120 Ω terminations. Scope: Siglent SDS1104X-E on CAN_H/CAN_L (or on the Pico CAN_TX pin, GP22 /
physical pin 29, which is cleaner to trigger on).

1. **Flash & clock check.** Flash the `CANHACK_FD` build. On the REPL:
   ```python
   import machine
   print(machine.freq())        # expect 250000000
   import rp2
   ch = rp2.CANHack(500)        # 500 kbit/s arbitration -> 2 Mbit/s data
   ```
2. **Builder sanity (no bus needed).**
   ```python
   ch.set_frame(0x123, data=bytes(range(8)), fd=True, brs=True)
   ch.print_frame()             # inspect fields / stuff bits
   ```
3. **Scope the bit times.** `ch.send_frame()` in a loop (e.g. `while True: ch.send_frame()`), or
   use `ch.send_raw()`. Verify on the scope:
   * arbitration bit time = **2.0 µs** (500 kbit/s),
   * data bit time = **0.5 µs** (2 Mbit/s) starting one bit after BRS,
   * the BRS bit is long-start/short-end and the CRC delimiter short-start/long-end,
   * clean single edges (no double-toggles) through the whole data phase.
4. **PEAK reception.** With the PCAN on the bus, `ch.send_frame()`. Success = PCAN logs the frame
   with the right ID/DLC/data and **no CRC/form error**, and (because the firmware drives a
   dominant ACK) the frame is accepted. Try payloads 8, 16, 20, 64 bytes and both `brs=True`
   and `brs=False`.
5. **If PCAN still reports CRC errors:** it is a timing/electrical issue, not the CRC maths.
   * Confirm `machine.freq()` really is 250 MHz and the board is not brown-ing out.
   * Scope the first ~10 data-phase bits right after BRS and the CRC delimiter; look for an edge
     that lands early/late by ~one bit — that points at the BRS/CRC-delimiter switch timing in
     `send_bits` (`SAMPLE_TO_BIT_END_FD` handling) rather than the payload.
   * As a cross-check, send with `brs=False` (whole frame at 500 kbit/s): if that is accepted but
     `brs=True` is not, the fault is specifically the fast-phase timing.
6. **Attacks.** Validate `error_attack`, `double_receive_attack`, `freeze_doom_loop_attack` and
   `spoof_frame` against a PEAK-sourced FD frame once plain sending is clean.

## Branch layout

* `master` — upstream Canis Labs firmware (no CAN FD).
* `canfd` — this CAN FD extension on MicroPython v1.22.2 (CANPico/firmware layout). **Base for this
  work.**
* `classic2` — the original thesis-era implementation on MicroPython v1.18 (pico/micropython
  layout) plus the thesis PDF in `docs/`. The frame builder there is identical to `canfd`.
