# LPDDR5 Controller Specification (lpddr5c)

**Version:** 1.0  
**Date:** 2026-03-16  
**Target:** ASIC/FPGA Implementation

---

## 1. Overview

### 1.1 Features
- **Protocol Support:** LPDDR5/JEDEC209-5 compliant
- **Data Rate:** Up to 6400 Mbps (LPDDR5) / 8533 Mbps (LPDDR5X)
- **Architecture:** Dual Channel, x16 per channel
- **DFI Interface:** DFI 5.0 compliant
- **Low Power Modes:** Power-Down, Self-Refresh, Deep Sleep
- **Reliability:** ECC support, Parity checking, Data scrubbing
- **Training:** CA Training, Read Training, Write Training, Gate Training

### 1.2 Architecture Block Diagram

```
+------------------+     +------------------+
|   DFI Interface  |<--->|  System Bus (AXI)|
+--------+---------+     +------------------+
         |
+--------v---------+     +------------------+
|  Command         |     |   Register       |
|  Scheduler       |<--->|   Configuration  |
+--------+---------+     +------------------+
         |
    +----v----+----+
    |         |    |
+---v---+  +--v----+  +--------+
|Read   |  |Write  |  |Training|
|Data   |  |Data   |  |Control |
|Path   |  |Path   |  |        |
+---+---+  +---+---+  +--------+
    |          |
+---v----------v---+
|   PHY Interface  |
|   (LPDDR5 Pins)  |
+------------------+
```

---

## 2. Interface Specification

### 2.1 DFI 5.0 Interface

#### 2.1.1 Command Interface
| Signal | Width | Direction | Description |
|--------|-------|-----------|-------------|
| dfi_reset_n | 1 | Input | DFI reset, active low |
| dfi_clk | 1 | Input | DFI clock |
| dfi_cs_n | 2 | Output | Chip select per channel |
| dfi_cke | 2 | Output | Clock enable per channel |
| dfi_ca | 12 | Output | Command/address bus |
| dfi_rw | 1 | Output | Read/Write indicator |

#### 2.1.2 Data Interface
| Signal | Width | Direction | Description |
|--------|-------|-----------|-------------|
| dfi_rddata | 64/128 | Input | Read data bus |
| dfi_rddata_valid | 1 | Input | Read data valid |
| dfi_wrdata | 64/128 | Output | Write data bus |
| dfi_wrdata_mask | 8/16 | Output | Write data mask |
| dfi_wrdata_en | 1 | Output | Write data enable |

#### 2.1.3 Training Interface
| Signal | Width | Direction | Description |
|--------|-------|-----------|-------------|
| dfi_phymstr_req | 1 | Input | PHY master request |
| dfi_phymstr_ack | 1 | Output | PHY master acknowledge |
| dfi_phymstr_cs | 1 | Output | PHY master chip select |
| dfi_rdlvl_req | 1 | Input | Read leveling request |
| dfi_rdlvl_en | 1 | Output | Read leveling enable |
| dfi_wrlvl_req | 1 | Input | Write leveling request |
| dfi_wrlvl_en | 1 | Output | Write leveling enable |

### 2.2 Register Configuration Interface (APB/AXI-Lite)

| Register Name | Offset | Access | Description |
|--------------|--------|--------|-------------|
| CTRL_REG0 | 0x00 | RW | Main control: enable, reset |
| CTRL_REG1 | 0x04 | RW | Timing: tRCD, tRP, tRAS |
| CTRL_REG2 | 0x08 | RW | Timing: tRC, tRFC, tREFI |
| CTRL_REG3 | 0x0C | RW | Mode: BL, CL, RL, WL |
| STATUS_REG0 | 0x10 | RO | Status: init done, training done |
| STATUS_REG1 | 0x14 | RO | Error flags |
| STATUS_REG2 | 0x18 | RO | Temperature sensor |
| DFI_REG0 | 0x20 | RW | DFI timing parameters |
| ECC_REG0 | 0x30 | RW | ECC enable, scrub interval |
| LP_REG0 | 0x40 | RW | Low power mode config |
| TRAIN_REG0 | 0x50 | RW | Training control |
| TEST_REG0 | 0xF0 | RW | BIST/TEST mode |

---

## 3. Functional Specification

### 3.1 Initialization Sequence

```
Power On
    |
    v
Release Reset (dfi_reset_n = 1)
    |
    v
PHY Initialization (wait for dfi_init_complete)
    |
    v
DRAM Initialization (MRW commands)
    |
    v
Training Sequence:
  - CA Training
  - Read Training (Gate + DQ)
  - Write Training
    |
    v
Normal Operation Mode
```

### 3.2 Command Scheduler

#### 3.2.1 Command Priority
1. **Refresh** (highest - must meet tREFI)
2. **Read/Write** (based on age and bank availability)
3. **Mode Register** (configuration)
4. **Power Down Entry/Exit**

#### 3.2.2 Scheduling Algorithm
```python
while True:
    # Check for refresh requirement
    if refresh_counter >= tREFI:
        schedule_refresh()
        continue
    
    # Get ready commands from queue
    ready_cmds = get_bank_idle_commands()
    
    # Age-based priority
    oldest_cmd = get_oldest(ready_cmds)
    
    # Check timing constraints (tRCD, tRP, tRAS, etc.)
    if check_timing_constraints(oldest_cmd):
        issue_command(oldest_cmd)
```

### 3.3 Data Path

#### 3.3.1 Read Path
```
DFI rddata -> CDC FIFO -> ECC Check/Correct -> Reorder Buffer -> AXI Read Data
```

#### 3.3.2 Write Path
```
AXI Write Data -> Reorder Buffer -> ECC Generation -> CDC FIFO -> DFI wrdata
```

### 3.4 Training

#### 3.4.1 CA Training
- Purpose: Center CA signals in eye
- Method: Sweep CA delay and check for correct command response

#### 3.4.2 Read Training
- **Gate Training**: Align DQS gate with valid data window
- **Read DQ**: Center DQ in DQS eye per bit

#### 3.4.3 Write Training
- Center DQ/DM in DQS eye
- Adjust per-bit delays for timing closure

### 3.5 Low Power Management

| Mode | Entry Condition | Exit Condition | Latency | Power Savings |
|------|-----------------|----------------|---------|---------------|
| Power-Down | Idle > threshold | Any command | ~tXP | Moderate |
| Self-Refresh | Idle > long threshold | Explicit exit | ~tXSR | High |
| Deep Sleep | System sleep | Wake interrupt | ~tDPD | Maximum |

---

## 4. Performance Specifications

### 4.1 Timing Parameters

| Parameter | DDR-6400 | DDR-8533 | Description |
|-----------|----------|----------|-------------|
| tCK (ns) | 0.3125 | 0.2344 | Clock period |
| CL (cycles) | 24 | 32 | CAS Latency |
| CWL (cycles) | 18 | 26 | CAS Write Latency |
| tRCD (ns) | 18.75 | 18.75 | RAS to CAS delay |
| tRP (ns) | 18.75 | 18.75 | Row precharge time |
| tRAS (ns) | 45 | 45 | Row active time |
| tRC (ns) | 63.75 | 63.75 | Row cycle time |
| tRFC (ns) | 350 | 350 | Refresh cycle time |
| tREFI (ns) | 3900 | 3900 | Refresh interval |

### 4.2 Bandwidth Calculation

```
Bandwidth = Data_Rate × Bus_Width × Channels

For LPDDR5-6400:
- Data Rate: 6400 MT/s (3200 MHz DDR)
- Bus Width: 16 bits per channel
- Channels: 2 (dual channel)
- Transfer Size: 2 bytes per channel per clock

Bandwidth = 6400 × 10^6 × 2 bytes × 2 channels
         = 25.6 GB/s per LPDDR5 device
```

### 4.3 Efficiency Factors

| Factor | Typical Value | Impact |
|--------|---------------|--------|
| Bank Conflicts | 5-15% penalty | Serialization |
| Refresh Overhead | ~2% | Periodic blocking |
| Page Miss | ~40ns penalty | tRCD + tRP |
| Bus Turnaround | 2-4 cycles | Read/Write switching |
| Write Recovery | 2-4 cycles | tWR timing |

**Typical Efficiency:** 70-85% of theoretical peak bandwidth

---

## 5. Verification & Testing

### 5.1 Test Coverage

| Test Category | Coverage Target | Method |
|---------------|-----------------|--------|
| Functional | 100% | Directed + Constrained Random |
| Protocol | 100% | Formal verification |
| Performance | 90% | Traffic generators |
| Power | 80% | Power aware simulation |
| DFT | 100% | Scan/MBIST insertion |

### 5.2 Key Test Scenarios

1. **Initialization & Training**
   - Power-on sequence
   - All training modes (CA, Read, Write)
   - Training failure recovery

2. **Command Scheduling**
   - Bank interleaving
   - Read/write merging
   - Priority inversion handling
   - Refresh scheduling

3. **Data Integrity**
   - ECC error injection/correction
   - Parity checking
   - Data scrambling

4. **Low Power**
   - Power-down entry/exit
   - Self-refresh
   - Deep sleep

5. **Error Handling**
   - DFI error responses
   - Training failures
   - Timeout handling

### 5.3 Simulation Environment

```
+-----------------+        +-----------------+
|  Testbench      |        |  LPDDR5 DRAM    |
|  (UVME/VMM)     |<------>|  Model (VIPs)   |
+--------+--------+        +-----------------+
         |
         v
+-----------------+
|  DUT            |
|  LPDDR5         |
|  Controller     |
+-----------------+
         |
         v
+-----------------+
|  Scoreboard     |
|  & Checker      |
+-----------------+
```

---

## 6. Implementation Notes

### 6.1 Synthesis Guidelines

| Parameter | Recommendation |
|-----------|------------------|
| Clock Domain | Separate controller clock (1/2 or 1/4 DRAM clock) |
| Reset Strategy | Async assert, sync deassert |
| CDC Method | FIFO or handshaking for all cross-clock paths |
| Timing Closure | Register all outputs, avoid combo logic on IO |
| Power Gating | Per-channel isolation for dual-channel configs |

### 6.2 Floorplan Considerations

```
+------------------------------------------+
|         IO Ring (LPDDR5 Pins)            |
|  +------------------------------------+  |
|  |                                    |  |
|  |      PHY Hard Macros             |  |
|  |      (DFI <-> LPDDR5)            |  |
|  |                                    |  |
|  +------------------------------------+  |
|  |                                    |  |
|  |   Controller Digital Logic         |  |
|  |   - Command Scheduler              |  |
|  |   - Data Path                      |  |
|  |   - Training Control               |  |
|  |                                    |  |
|  +------------------------------------+  |
|         System Interface (AXI/APB)       |
+------------------------------------------+
```

### 6.3 Debug & Observability

| Feature | Implementation |
|---------|----------------|
| Transaction Logger | Trace buffer for last N commands |
| Performance Counters | Bandwidth, latency, bank utilization |
| Error Injection | Configurable fault injection for testing |
| Eye Monitor | Per-bit timing margin visibility |
| Thermal Sensor | Die temperature monitoring |

---

## 7. References

### 7.1 Standards & Specifications

1. JEDEC JESD209-5 - LPDDR5 Standard
2. JEDEC JESD209-5B - LPDDR5X Addendum
3. DFI 5.0 Specification - DDR PHY Interface
4. AMBA AXI4 Protocol Specification

### 7.2 Application Notes

1. "LPDDR5 System Design Guide" - [Vendor]
2. "High-Speed DRAM Interface Design" - [Reference]
3. "Low Power Design Techniques for Mobile DRAM" - [Reference]

---

## Revision History

| Version | Date | Author | Description |
|---------|------|--------|-------------|
| 1.0 | 2026-03-16 | Digital IC Engineer | Initial specification for LPDDR5 Controller |

---

*End of Specification*
