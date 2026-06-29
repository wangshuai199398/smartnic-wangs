# SPDX-License-Identifier: MIT
"""Unit tests for the reusable PCIe host BFM."""

from bfm.pcie_bfm import (
    PcieBar,
    PcieCompletion,
    PcieCompletionTimeout,
    PcieFunctionIdentity,
    PcieHostBfm,
    PcieTlpType,
)


def test_config_identity_and_command_bits():
    identity = PcieFunctionIdentity(bus=3, device=2, function=1, vendor_id=0x1234, device_id=0x5678)
    bfm = PcieHostBfm(identity=identity)

    assert bfm.cfg_read(PcieHostBfm.CFG_VENDOR_DEVICE) == 0x5678_1234
    assert identity.requester_id == 0x0311

    bfm.enable_memory_and_bus_master()
    command = bfm.cfg_read(PcieHostBfm.CFG_COMMAND_STATUS, size=2)
    assert command & PcieHostBfm.COMMAND_MEMORY
    assert command & PcieHostBfm.COMMAND_BUS_MASTER


def test_bar_size_probe_and_programming():
    bfm = PcieHostBfm(bars=[PcieBar(0, 0x1000), PcieBar(2, 0x2000)])

    assert bfm.probe_bar_size(0) == 0x1000
    assert bfm.probe_bar_size(2) == 0x2000

    bfm.program_bar(0, 0x8000_0000)
    bfm.program_bar(2, 0x9000_0000)
    assert bfm.bars[0].base == 0x8000_0000
    assert bfm.cfg_read(PcieHostBfm.CFG_BAR0) == 0x8000_0000
    assert bfm.bars[2].base == 0x9000_0000


def test_mmio_write_emits_tlp_and_updates_bar_memory():
    seen = []
    bar = PcieBar(0, 0x1000, base=0x8000_0000, sink=seen.append)
    bfm = PcieHostBfm(bars=[bar])

    bfm.mem_write(0x8000_0010, b"\x11\x22\x33\x44")

    assert bar.memory[0x10:0x14] == b"\x11\x22\x33\x44"
    assert len(seen) == 1
    assert seen[0].tlp_type == PcieTlpType.MEM_WRITE
    assert seen[0].address == 0x8000_0010
    assert seen[0].data == b"\x11\x22\x33\x44"


def test_mmio_read_returns_matched_completion_payload():
    bar = PcieBar(0, 0x1000, base=0x8000_0000)
    bar.memory[0x20:0x24] = b"\xaa\xbb\xcc\xdd"
    bfm = PcieHostBfm(bars=[bar])

    assert bfm.mem_read(0x8000_0020, 4) == b"\xaa\xbb\xcc\xdd"


def test_completion_timeout_and_malformed_completion():
    bar = PcieBar(0, 0x1000, base=0x8000_0000)
    bfm = PcieHostBfm(bars=[bar])
    tag = bfm.issue_mem_read_no_completion(0x8000_0040, 4)

    try:
        bfm.wait_for_completion(tag)
        raise AssertionError("expected completion timeout")
    except PcieCompletionTimeout:
        pass

    bfm.push_completion(
        PcieCompletion(
            tag=tag,
            data=b"\x00\x01",
            byte_count=2,
            requester_id=bfm.identity.requester_id,
            completer_id=bfm.identity.requester_id,
        )
    )
    try:
        bfm.wait_for_completion(tag)
        raise AssertionError("expected malformed completion error")
    except RuntimeError as exc:
        assert "malformed" in str(exc)


def test_unexpected_completion_is_rejected():
    bfm = PcieHostBfm()

    try:
        bfm.push_completion(PcieCompletion(tag=7, data=b""))
        raise AssertionError("expected unexpected completion rejection")
    except ValueError as exc:
        assert "unexpected completion tag" in str(exc)


def test_msix_programming_observation_and_masking():
    bfm = PcieHostBfm(msix_vectors=2)

    bfm.program_msix_vector(0, 0xfee0_0000, 0x40, masked=False)
    assert bfm.observe_msix_write(0xfee0_0000, 0x40) == 0
    assert bfm.wait_msix(0) == 0

    bfm.program_msix_vector(1, 0xfee0_1000, 0x41, masked=True)
    assert bfm.observe_msix_write(0xfee0_1000, 0x41) is None
    try:
        bfm.wait_msix(1)
        raise AssertionError("masked vector must not be immediately observed")
    except PcieCompletionTimeout:
        pass
    bfm.unmask_msix_vector(1)
    assert bfm.wait_msix(1) == 1


def test_reset_clears_outstanding_transactions_and_restores_config():
    bar = PcieBar(0, 0x1000, base=0x8000_0000)
    bfm = PcieHostBfm(bars=[bar])
    tag = bfm.issue_mem_read_no_completion(0x8000_0000, 4)
    assert tag in bfm._outstanding

    bfm.enable_memory_and_bus_master()
    assert bfm.cfg_read(PcieHostBfm.CFG_COMMAND_STATUS, size=2) & PcieHostBfm.COMMAND_BUS_MASTER

    bfm.reset()
    assert not bfm._outstanding
    assert bfm.cfg_read(PcieHostBfm.CFG_COMMAND_STATUS, size=2) == 0


def main():
    test_config_identity_and_command_bits()
    test_bar_size_probe_and_programming()
    test_mmio_write_emits_tlp_and_updates_bar_memory()
    test_mmio_read_returns_matched_completion_payload()
    test_completion_timeout_and_malformed_completion()
    test_unexpected_completion_is_rejected()
    test_msix_programming_observation_and_masking()
    test_reset_clears_outstanding_transactions_and_restores_config()
    print("pcie bfm unit tests passed")


if __name__ == "__main__":
    main()
