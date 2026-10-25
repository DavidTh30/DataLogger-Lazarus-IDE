# PLC Data Logger

A compact Lazarus program (normal forms, `.lfm`) that reads PLC values every **500 ms** (adjustable) and writes them to **CSV** files, one per day.

| Feature | How |
|---|---|
| Protocols | **S7 TCP/IP** (S7-1200/1500/300/400), **Modbus TCP/IP**, **Modbus RTU (RS485)** |
| Network config | *Network Config → Settings...*, saved to `DataLogger.ini` next to the exe and **loaded automatically at every start** (with the last tag list) |
| File menu | **Open / Save / Save As** the tag list (`*.dlog`), **Log Folder...** (where the CSV files go, shown in the status bar), **Open Folder** (log folder of the current month), **Exit** |
| Tag menu | **right-click the table** (or main menu **Tags**): **Address helper...** (Ctrl+H), **Display format ▸**, **Cut / Copy / Paste** (Ctrl+X / C / V), Add tag (Ctrl+Ins), Insert row(s) above (Ins), Delete row(s) (Del), Move up / down (Ctrl+Up / Down). The keys work when no cell is being edited |
| Row selection | click the **`#` column** = whole row. **Ctrl+click** adds / removes rows, **Shift+click** or **drag** down the `#` column = a range. Esc or a click on a normal cell ends the selection. Cut / Copy / Delete / Insert work on all selected rows |
| Clipboard | one line per row: `Name <TAB> Address <TAB> Format`, so rows can go to / come from Excel. **Paste** puts the rows at the first selected row (or the `*` row): empty rows there are filled, otherwise the rows are inserted. A line with only one column = an address |
| Empty rows | clearing the **Name** or the **Address** of a tag (Del on the cell, or erase it in the editor) makes the **whole row empty**. Empty rows stay in place, are not read and not in the CSV; typing into one makes a tag again. Empty rows at the end are dropped |
| New tags | the **empty row `*`** at the end of the table is always waiting: type a name or an address into it and the next empty row appears at once (missing name → `TagN`, missing address → the next one). **Add / Insert tag** use the address **right after the tag above** with the same type and format: `M0.7` → `M1.0`, `MW10` → `MW12`, `DB10.DBD0` → `DB10.DBD4`, `40003:REAL` → `40005:REAL`. No tag above → `M0.0` (Modbus: `40001`) |
| Addresses | type them in the grid, or use the **Address helper** (area / table, number, type → finished address + meaning). Every address is checked and explained in the *Meaning* column |
| Display format | per tag, in the *Format* column (drop-down list) or the right-click menu, which shows each format with the current value. Used in the grid **and** the CSV |
| Monitor | read and show the values **without** writing a file |
| Record | blinking red dot + `RECORDING dd-mm-yyyy.csv rows N`. Tags can't be edited while recording |
| Interval | spin box, **5 ms** … 10 min, **default 500 ms**. The schedule is fixed, so it doesn't drift (precise PC clock, see *Speed*) |
| Background | **minimize** or **View → Run in background (tray)**: the window hides, logging continues. Double-click the tray icon to show it again. Closing while recording asks first |
| Status | only the network connection is checked: no PLC clock or CPU state |
| Chart | **LogChart** (`LogChart/`, BGRABitmap): opens the CSV files as a chart. It handles several days, zoom, a cursor with values, statistics, **Live** while recording, and PNG export. See [LogChart/README.md](LogChart/README.md) |

## Speed

| What | How |
|---|---|
| Few requests | tags close together are read as **one block** (S7: holes up to 32 bytes, Modbus: 8 registers / 32 coils). **S7**: several blocks in **one request** (multi-item read, up to 20 items per PDU). **Modbus**: one request per block (max 125 registers / 2000 coils) |
| Bad tags | if the PLC refuses a block, its tags are read one by one from then on, so only the bad tag shows an error |
| Precise timing | schedule from `QueryPerformanceCounter`, waits with 1 ms resolution (`timeBeginPeriod`), time stamps from `GetSystemTimePreciseAsFileTime` (`Now` only changes every ~16 ms) |
| CSV | the file stays **open while recording** (one write per row, no open / close each time). Excel can still open it (read-only). Every row is handed to Windows at once, so a crash of the program loses nothing |
| TCP | `TCP_NODELAY` (no Nagle delay) for S7 and Modbus TCP |
| Status line | `1 req  1.6 ms  100.0 /s` = requests per cycle, time of one cycle (read + CSV), cycles per second |

Measured with `tests/bench` (one request per tag, as before, against `ReadAll`, now):

| Target | Tags | Before | Now |
|---|---|---|---|
| Virtual PLC, 16 tags in DB10 | 16 | 16 requests, 16.6 ms | **1 request, 1.04 ms (16× faster)** |
| Virtual PLC, DB10 + I + M (+ 2 missing addresses) | 24 | 24 requests, 24.5 ms | **1 request, 5.1 ms** |
| `Tools/s7sim.py` (odd sizes, DT / DTL / DATE, DB99 missing) | 9 | 9 requests, 0.94 ms | **1 request, 0.26 ms** |
| `Tools/mbsim.py` Modbus TCP | 12 | 12 requests, 0.92 ms | **4 requests, 0.30 ms** |
| Whole program, Record at **10 ms**, Virtual PLC | 5 | | **100.0 rows/s**, rows 10 ms apart (±1–2 ms), cycle 1.6 ms |

- The Virtual PLC needs about 1 ms per item, so for it, fewer blocks matter most.
- A real S7-1200 over the network needs several ms per request, so there one request for all tags matters most.

```bash
fpc -Mobjfpc -Sh -FuDataLogger -FuCommon DataLogger\tests\bench.lpr
```

```bash
DataLogger\tests\bench.exe s7 127.0.0.1 300
```

## CSV files

```
<Log folder>\mm-yyyy\dd-mm-yyyy.csv        e.g.  Logs\10-2026\25-10-2026.csv
```

- The file name comes from the **PC clock of each row**:
  - **new day** → new file
  - **new month** → new folder `mm-yyyy` + new file
  - **new year** → new folder (`01-2027`) + new file
- Format (Excel friendly, `.` as decimal point):
  ```
  Date,Time,Status,Counter (40001),Level ABCD (40003:REAL),Pump coil (00001)
  2026-10-25,10:40:27.698,OK,836,7.930021,1
  ```
  - **Status**: `OK`, `TAG ERROR` (one tag refused, its cell stays empty), or `NO CONNECTION` (one row every 2 s while the PLC can't be reached).
- **Safe writing**:
  - The file stays open while recording. Each row goes to Windows at once, so a crash of the program can't lose rows.
  - If writing fails (e.g. disk full, file locked by another program), the rows wait in memory and are written as soon as possible.
  - If the tag list changes, a new header line is written into the same file.

## Display formats

| Type | Formats (first = default) | Example |
|---|---|---|
| BOOL | `0/1` `TRUE/FALSE` `ON/OFF` | `ON` |
| BYTE, INT, UINT, DINT, UDINT | `DEC` `HEX` `BIN` | `IW0` as BIN: `2#0000_0010_0000_0000` (= I0.1), HEX: `16#0200` |
| REAL, REALSW | `AUTO` `0` `0.0` `0.00` `0.000` `0.0000` `SCI` | `7.94`, `1.2346E+04` |
| TIME (DINT ms) | `T#` `MS` `S` `HH:MM:SS.ZZZ` | `T#1h_2m_3s_400ms` |
| TOD (UDINT ms since 00:00) | `HH:MM:SS.ZZZ` `HH:MM:SS` `MS` | `14:35:07.123` |
| DATE (days since 1990-01-01) | `SHORT` `LONG` `ISO` `D#` | `25-10-2026`, `Sunday 25 October 2026`, `2026-10-25` |
| DT (8 bytes BCD), DTL (12 bytes), UNIXTIME (UDINT s since 1970) | `SHORT` `LONG` `ISO` (+ `UNIX` for UNIXTIME) | `25-10-2026 14:35:07`, `Sunday 25 October 2026 14:35:07.123` |

- Day / month names are always English, so the CSV reads the same on every PC.
- The format is stored per tag in the `*.dlog` file (`Format0=BIN`). A format that doesn't fit a new type falls back to the default.

## Addresses

| Protocol | Examples | Default type |
|---|---|---|
| S7 | `I0.1` `Q0.0` `M10.3` (BOOL), `IB0` `MB0` (BYTE), `IW64` `MW20` `DB10.DBW42` (INT), `MD24` `DB10.DBD0` (REAL), `DB10.DBX40.0` (BOOL) | by size; override with `:INT :UINT :DINT :UDINT :REAL`, e.g. `MD24:DINT`. Date / time: `DB5.DBW0:DATE` `MD40:TIME` `MD44:TOD` `DB5.DBB0:DT` `DB5.DBB0:DTL` `MD48:UNIXTIME` (the size letter must fit: W, D, or B for DT / DTL) |
| Modbus | `00001` coil (FC01), `10001` input (FC02), `30001` input register (FC04), `40001` holding register (FC03), 6 digits for > 9999 (`465536`) | registers: INT; override with `:UINT :DINT :UDINT :REAL :REALSW :TIME :TOD :UNIXTIME` (REALSW = low word first) |

- S7 DB addresses need **Optimized block access OFF**.
- The CPU must allow **PUT/GET**.
- Modbus numbers are **Modicon numbers** (40001 = offset 0).

## Files

| File | What |
|---|---|
| `umain.pas/.lfm` | main window, menu, tray |
| `unetform.pas/.lfm` | Network Config dialog |
| `uaddrhelper.pas/.lfm` | Address helper dialog |
| `uaddress.pas` | address parser / formatter / description, data types |
| `uformat.pas` | display formats (DEC / HEX / BIN, date LONG / ISO, T#, ...) |
| `udrivers.pas` | `TS7Driver` (uses `../Common/s7comm.pas`, multi-item read), `TModbusTcpDriver`, `TModbusRtuDriver` (FPC `serial` unit, CRC16), block planning `PlanBlocks` / `ReadAll` |
| `tests/bench.lpr` | speed test: one request per tag against `ReadAll` (S7 or Modbus TCP) |
| `ulogger.pas` | logger thread (Monitor / Record) + `TCsvWriter` (folder / file rollover) |
| `uconfig.pas` | `DataLogger.ini` (network, auto start, last tag list) |
| `uproject.pas` | `*.dlog` (tags, interval, log folder) |
| `Examples/*.dlog` | `S7_VirtualPLC.dlog`, `Modbus_Simulator.dlog`, `S7_DateTime_Test.dlog` (DB20 of `Tools/s7sim.py`) |
| `tests/testcore.lpr` | 98 console tests: Modbus CRC, addresses, next address, block planning, decoding (incl. DATE / TIME / TOD / DT / DTL / UNIXTIME), display formats, **day / month / year rollover** |

## Tests that were run

| Test | Result |
|---|---|
| `tests/testcore` | 98 / 98 OK: CRC `01 03 00 00 00 0A → C5 CD`; rollover 29-11 → 30-11 → `12-2026\01-12-2026` → `01-2027\01-01-2027` |
| S7 against the Virtual PLC (127.0.0.1) | Monitor + Record; rows every 490–506 ms (average 500); a missing DB only gives `TAG ERROR` for that tag |
| Date / time + formats against `Tools/s7sim.py` DB20 | IW0 BIN, DATE LONG, TIME T#, TOD, DT ISO, DTL LONG, UNIXTIME, INT HEX shown and written to the CSV; right-click menu, Format drop-down, Address helper (DTL) OK |
| Modbus TCP against `Tools/mbsim.py` | INT, REAL (ABCD), REALSW (CDAB), DINT, input register, coil OK |
| Background (tray) | window hidden, logging continues (10 rows in 5 s) |
| Hard kill during Record | CSV complete up to the last row |
| Modbus RTU | CRC and framing are unit tested. **Not tested on real RS485** (no COM port on the test PC) |

## Build / try

```bash
C:\lazarus\lazbuild.exe DataLogger\DataLogger.lpi
```

```bash
python Tools\mbsim.py
```

`s7sim.py` also has a read-only **DB20** with live date / time values for `Examples/S7_DateTime_Test.dlog` (start it, then set the host to `127.0.0.2` if the Virtual PLC already uses `127.0.0.1:102`).

`mbsim.py` is a Modbus TCP slave on port 502 for `Examples/Modbus_Simulator.dlog`.
