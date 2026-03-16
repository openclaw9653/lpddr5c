# LPDDR5 Controller - Simulation Guide

## 📋 目录结构

```
project/lpddr5c/
├── rtl/              # RTL源代码
├── testbench/        # Testbench
├── sim/             # 仿真脚本
│   ├── Makefile      # 仿真Makefile
│   └── run_sim.sh   # 仿真运行脚本
└── docs/            # 文档
```

---

## 🚀 快速开始

### 方式 1: 使用脚本（推荐）

```bash
cd project/lpddr5c

# 用 VCS 仿真
./sim/run_sim.sh vcs

# 用 Xcelium 仿真
./sim/run_sim.sh xcelium

# 用 Verilator 仿真（开源）
./sim/run_sim.sh verilator

# 查看波形
./sim/run_sim.sh waves

# 清理
./sim/run_sim.sh clean
```

### 方式 2: 使用 Makefile

```bash
cd project/lpddr5c/sim

# VCS
make vcs

# Xcelium
make xcelium

# Verilator
make verilator

# 只编译
make comp SIMULATOR=vcs

# 只仿真
make sim SIMULATOR=vcs

# 查看波形
make waves

# 清理
make clean
```

---

## 🔧 环境变量配置

```bash
# 选择仿真器
export SIMULATOR=vcs      # 或 xcelium, verilator

# 启用波形
export WAVES=1

# 运行
./sim/run_sim.sh
```

---

## 📊 支持的仿真器

| 仿真器 | 状态 | 说明 |
|--------|------|------|
| **VCS (Synopsys)** | ✅ 完全支持 | 推荐，性能最好 |
| **Xcelium (Cadence)** | ✅ 完全支持 | 另一个商业选项 |
| **Verilator** | ✅ 开源支持 | 免费，适合快速验证 |

---

## 📝 Testbench 说明

### `tb_lpddr5c_top.sv` 包含的测试：

1. **Test 1: 基本寄存器读写**
   - 验证 APB 接口
   - 读写测试

2. **Test 2: 时序寄存器配置**
   - 配置 tRCD, tRP, tRAS, tRC 等
   - LPDDR5-6400 默认值

3. **Test 3: 模式寄存器配置**
   - 配置 CL, CWL, BL 等

4. **Test 4: 初始化检查**
   - 等待初始化完成

5. **Test 5: AXI 读写（简化版）**
   - 基础 AXI 事务验证

---

## 🎯 自定义测试

### 添加新测试到 Testbench：

```systemverilog
// 在 tb_lpddr5c_top.sv 的 initial 块中添加：

$display("\n[TEST 6] My Custom Test");
begin
    // 你的测试代码
    apb_write(16'h0000, 32'h12345678);
    
    if (condition) begin
        $display("[PASS] My test");
        test_passed++;
    end else begin
        $display("[FAIL] My test");
        test_failed++;
    end
end
```

---

## 👀 波形查看

### VCS + Verdi：
```bash
make waves
# 或
verdi -ssf waves/tb_lpddr5c_top.vcd
```

### Verilator + GTKWave：
```bash
gtkwave waves/tb_lpddr5c_top.vcd
```

### 推荐查看的信号：
- 时钟和复位：`sys_clk`, `sys_rst_n`
- APB 接口：`paddr`, `pwdata`, `prdata`, `pwrite`
- AXI 接口：`axi_aw*`, `axi_w*`, `axi_b*`, `axi_ar*`, `axi_r*`
- DFI 接口：`dfi_cs_n`, `dfi_cke`, `dfi_ca`, `dfi_rddata`, `dfi_wrdata`
- 状态信号：`test_passed`, `test_failed`, `error_count`

---

## 🐛 调试技巧

### 1. 增加日志详细度：
在 testbench 中添加：
```systemverilog
$display("[DEBUG] Signal value: %0h", signal_name);
```

### 2. 检查初始化：
```bash
# 查看前 1000 个周期
grep "INIT" sim/logs/sim.log
```

### 3. 波形 debug：
```systemverilog
// 在关键位置添加标记
initial begin
    $dumpfile("waves/debug.vcd");
    $dumpvars(0, tb_lpddr5c_top.u_dut);
end
```

---

## 📈 覆盖率收集（可选）

### VCS 覆盖率：
```bash
# 在 Makefile 中添加：
VCS_FLAGS += -cm line+cond+fsm+tgl+branch
VCS_FLAGS += -cm_name simv_cov
```

### 运行覆盖率：
```bash
make vcs
urg -dir simv.cm -db merged
```

---

## ⚡ 性能优化

### 快速编译（增量编译）：
```bash
make comp SIMULATOR=vcs  # 只编译变更的文件
make sim                  # 快速运行
```

### 关闭波形加速仿真：
```bash
export WAVES=0
make vcs
```

---

## ❓ 常见问题

### Q: 编译出错怎么办？
A: 检查：
1. 仿真器版本是否兼容
2. SystemVerilog 语法是否正确
3. 文件路径是否正确

### Q: 仿真卡住？
A: 检查：
1. 复位是否正确释放
2. 时钟是否正常
3. 是否有无限循环

### Q: 波形为空？
A: 检查：
1. `WAVES=1` 是否设置
2. `$dumpfile` 和 `$dumpvars` 是否调用
3. 仿真时间是否足够长

---

## 📚 更多资源

- [LPDDR5 Controller SPEC](../docs/LPDDR5_Controller_Spec.md)
- [项目状态报告](../docs/PROJECT_STATUS.md)
- [GitHub 仓库](https://github.com/openclaw9653/lpddr5c)

---

**祝仿真顺利！** 🚀
