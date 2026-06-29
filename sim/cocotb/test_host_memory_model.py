# SPDX-License-Identifier: MIT
"""Unit tests for the reusable host memory / DMA visibility model."""

from bfm import HostMemoryError, HostMemoryModel, PatternKind
from bfm.pcie_bfm import PcieTlp, PcieTlpType


def expect_host_memory_error(fn, text):
    try:
        fn()
    except HostMemoryError as exc:
        assert text in str(exc)
        return
    raise AssertionError(f"expected HostMemoryError containing {text!r}")


def test_allocate_aligned_dma_buffer():
    mem = HostMemoryModel(base_addr=0x8000_0000, size=4096)
    buf = mem.allocate(128, alignment=256, name="sq")
    assert buf.dma_addr == 0x8000_0000
    assert buf.dma_addr % 256 == 0
    assert buf.size == 128
    assert buf.name == "sq"

    second = mem.allocate(64, alignment=256)
    assert second.dma_addr == 0x8000_0100


def test_initial_data_write_and_readback():
    mem = HostMemoryModel(size=4096)
    buf = mem.allocate(16, init=b"hello")
    assert mem.read(buf.dma_addr, 16) == b"hello" + bytes(11)
    mem.write(buf.dma_addr + 5, b"!")
    assert mem.read(buf.dma_addr, 6) == b"hello!"


def test_service_dut_dma_read_from_allocated_memory():
    mem = HostMemoryModel(size=4096)
    buf = mem.allocate(16, init=b"abcdefghijklmnop")
    tlp = PcieTlp(PcieTlpType.MEM_READ, address=buf.dma_addr + 2, length=5, tag=7, requester_id=0x10)
    completion = mem.service_pcie_tlp(tlp)
    assert completion is not None
    assert completion.tag == 7
    assert completion.data == b"cdefg"
    assert completion.byte_count == 5
    tx = mem.assert_dma_read(buf.dma_addr + 2, 5)
    assert tx.tag == 7


def test_accept_dut_dma_write_and_verify_memory_contents():
    mem = HostMemoryModel(size=4096)
    buf = mem.allocate(8, pattern=PatternKind.CONSTANT)
    tlp = PcieTlp(PcieTlpType.MEM_WRITE, address=buf.dma_addr, data=b"RDMA", length=4, tag=3, first_be=0xF)
    assert mem.service_pcie_tlp(tlp) is None
    assert mem.read(buf.dma_addr, 4) == b"RDMA"
    tx = mem.assert_dma_write(buf.dma_addr, 4)
    assert tx.data == b"RDMA"
    assert tx.tag == 3


def test_partial_write_with_byte_enables_updates_selected_bytes_only():
    mem = HostMemoryModel(size=4096)
    buf = mem.allocate(8, init=b"abcdefgh")
    mem.dma_write(buf.dma_addr + 2, b"WXYZ", byte_enable=0b0101)
    assert mem.read(buf.dma_addr, 8) == b"abWdYfgh"
    tx = mem.assert_dma_write(buf.dma_addr + 2, 4)
    assert tx.byte_enable == (True, False, True, False)


def test_out_of_range_and_unallocated_dma_accesses_report_clear_errors():
    mem = HostMemoryModel(base_addr=0x1000, size=128)
    buf = mem.allocate(16)
    expect_host_memory_error(lambda: mem.dma_read(buf.dma_addr + 8, 16), "unallocated")
    expect_host_memory_error(lambda: mem.dma_write(0x2000, b"x"), "out of range")


def test_transaction_history_records_reads_and_writes_in_order():
    mem = HostMemoryModel(size=4096)
    buf = mem.allocate(16, init=b"0123456789abcdef")
    mem.dma_read(buf.dma_addr, 4, tag=1)
    mem.dma_write(buf.dma_addr + 4, b"ABCD", tag=2)
    mem.dma_read(buf.dma_addr + 4, 4, tag=3)
    history = mem.history
    assert [tx.kind for tx in history] == ["read", "write", "read"]
    assert [tx.order for tx in history] == [1, 2, 3]
    assert [tx.tag for tx in history] == [1, 2, 3]


def test_reset_clears_outstanding_state_and_respects_memory_policy():
    mem = HostMemoryModel(size=4096, clear_on_reset=False)
    buf = mem.allocate(8, init=b"12345678")
    mem.dma_read(buf.dma_addr, 2)
    mem.reset(clear_allocations=False)
    assert mem.history == ()
    assert mem.read(buf.dma_addr, 8) == b"12345678"

    mem.reset(clear_memory=True, clear_allocations=False)
    assert mem.read(buf.dma_addr, 8) == bytes(8)

    mem.reset(clear_allocations=True)
    assert mem.buffers == ()


def test_free_reuses_region_deterministically():
    mem = HostMemoryModel(size=4096)
    first = mem.allocate(128, alignment=64)
    mem.free(first)
    second = mem.allocate(64, alignment=64)
    assert second.dma_addr == first.dma_addr


def test_deterministic_pattern_generation_and_digest():
    mem = HostMemoryModel(size=4096)
    p0 = mem.pattern_bytes(32, PatternKind.RANDOM, seed=99)
    p1 = mem.pattern_bytes(32, PatternKind.RANDOM, seed=99)
    assert p0 == p1
    assert mem.pattern_bytes(4, PatternKind.INCREMENTING) == b"\x00\x01\x02\x03"
    assert mem.pattern_bytes(4, PatternKind.WALKING_BIT) == b"\x01\x02\x04\x08"

    buf = mem.allocate(32, init=p0)
    assert mem.digest(buf.dma_addr, 32) == mem.digest(buf.dma_addr, 32)


def test_compare_helpers_report_readable_mismatch_and_masked_success():
    mem = HostMemoryModel(size=4096)
    buf = mem.allocate(4, init=b"abcd")
    mem.compare(buf.dma_addr, b"abcd")
    mem.compare_masked(buf.dma_addr, b"aXcX", 0b0101)
    try:
        mem.compare(buf.dma_addr, b"abXd")
    except AssertionError as exc:
        assert "memory mismatch" in str(exc)
        assert "0x" in str(exc)
    else:
        raise AssertionError("expected compare mismatch")


def run_all():
    tests = [
        test_allocate_aligned_dma_buffer,
        test_initial_data_write_and_readback,
        test_service_dut_dma_read_from_allocated_memory,
        test_accept_dut_dma_write_and_verify_memory_contents,
        test_partial_write_with_byte_enables_updates_selected_bytes_only,
        test_out_of_range_and_unallocated_dma_accesses_report_clear_errors,
        test_transaction_history_records_reads_and_writes_in_order,
        test_reset_clears_outstanding_state_and_respects_memory_policy,
        test_free_reuses_region_deterministically,
        test_deterministic_pattern_generation_and_digest,
        test_compare_helpers_report_readable_mismatch_and_masked_success,
    ]
    for test in tests:
        test()


if __name__ == "__main__":
    run_all()
    print("host memory model unit tests passed")

