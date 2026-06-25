# SPDX-License-Identifier: MIT
"""Mock/structural checks for BAR2 CSR decode and fabric integration."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PKG = ROOT / "rtl" / "common" / "smartnic_pkg.sv"
DECODE = ROOT / "rtl" / "reg" / "csr_decode.sv"
FABRIC = ROOT / "rtl" / "reg" / "csr_fabric.sv"
TOP = ROOT / "rtl" / "top" / "smartnic_top.sv"


CSR_WINDOWS = {
    "CSR_BLOCK_QP": (0x1000, 0x1000),
    "CSR_BLOCK_CQ": (0x2000, 0x1000),
    "CSR_BLOCK_MR": (0x3000, 0x1000),
    "CSR_BLOCK_AH": (0x4000, 0x1000),
    "CSR_BLOCK_MSIX": (0x5000, 0x1000),
    "CSR_BLOCK_SRIOV": (0x6000, 0x1000),
    "CSR_BLOCK_CONGESTION": (0x7000, 0x1000),
}


def read(path):
    assert path.exists(), f"{path} must exist"
    return path.read_text()


def decode(addr):
    if addr & 0x3:
        return ("CSR_BLOCK_NONE", 0, "CSR_DECODE_MISALIGNED")

    for block, (base, size) in CSR_WINDOWS.items():
        if base <= addr < base + size:
            return (block, addr - base, "CSR_DECODE_OK")

    return ("CSR_BLOCK_NONE", 0, "CSR_DECODE_BAD_OFFSET")


def apply_be(old, new, be):
    value = old
    for lane in range(4):
        if be & (1 << lane):
            mask = 0xFF << (lane * 8)
            value = (value & ~mask) | (new & mask)
    return value


def sv_hex32(value):
    raw = f"{value:08x}"
    return f"32'h{raw[:4]}_{raw[4:]}"


def test_package_defines_csr_windows_and_ids():
    text = read(PKG)
    text_lower = text.lower()
    for block, (base, _size) in CSR_WINDOWS.items():
        suffix = block.removeprefix("CSR_BLOCK_")
        assert f"CSR_{suffix}_BASE" in text
        assert sv_hex32(base) in text_lower
        assert block in text
    assert "csr_block_id_e" in text
    assert "csr_decode_status_e" in text


def test_csr_decode_maps_all_register_windows():
    text = read(DECODE)
    assert "module csr_decode" in text
    assert "CSR_DECODE_MISALIGNED" in text

    for block, (base, size) in CSR_WINDOWS.items():
        assert block in text
        assert decode(base) == (block, 0, "CSR_DECODE_OK")
        assert decode(base + size - 4) == (block, size - 4, "CSR_DECODE_OK")

    assert decode(0x1001)[2] == "CSR_DECODE_MISALIGNED"
    assert decode(0x0800)[2] == "CSR_DECODE_BAD_OFFSET"


def test_csr_fabric_exposes_standard_slave_ports():
    text = read(FABRIC)
    assert "module csr_fabric" in text
    assert "csr_decode u_csr_decode" in text
    assert "csr_req_ready = !csr_rsp_valid || csr_rsp_ready" in text

    for prefix in ["qp", "cq", "mr", "ah", "msix", "sriov", "congestion"]:
        for signal in ["csr_wr_en", "csr_rd_en", "csr_addr", "csr_wdata", "csr_rdata"]:
            assert f"{prefix}_{signal}" in text


def test_single_slave_selection_model():
    for block, (base, _size) in CSR_WINDOWS.items():
        selected = [name for name, (win_base, win_size) in CSR_WINDOWS.items() if win_base <= base < win_base + win_size]
        assert selected == [block]


def test_byte_enable_write_model():
    assert apply_be(0x00000000, 0x11223344, 0b1111) == 0x11223344
    assert apply_be(0xAAAA5555, 0x11223344, 0b0101) == 0xAA225544
    assert apply_be(0xAAAA5555, 0x11223344, 0b0000) == 0xAAAA5555


def test_smartnic_top_connects_csr_fabric():
    text = read(TOP)
    assert "bar2_csr_req_valid" in text
    assert "bar2_csr_rsp_valid" in text
    assert "csr_fabric u_csr_fabric" in text
    assert "qp_csr_control_reg" in text
    assert "congestion_csr_control_reg" in text
    assert "apply_csr_be" in text


def main():
    test_package_defines_csr_windows_and_ids()
    test_csr_decode_maps_all_register_windows()
    test_csr_fabric_exposes_standard_slave_ports()
    test_single_slave_selection_model()
    test_byte_enable_write_model()
    test_smartnic_top_connects_csr_fabric()
    print("[csr-fabric] BAR2 CSR structural checks passed")


if __name__ == "__main__":
    main()
