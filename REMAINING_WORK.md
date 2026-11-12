# Angus DMA and API handoff

Status as of 12 November 2026, based on the current local source and the last board logs shared in the project. The current bitstream has not been retested for this handoff.

## 1. Resolve DMA1 startup and framing

- **DMA0 raw** improved after adding the `RAW_STREAM_RESET` pulse. The last report was that startup had hardly any stale frames. Recheck actual packet lengths and `RAW_DROPPED_PACKETS` during a sustained raw capture.
- **DMA1 averaged** remains the hardware blocker. Before `AVG_RESET`, the test drained two queued outputs and then timed out while `AVG_DROPPED_SAMPLES` rose. With `--avg-reset --avg-n 0`, the avg counters showed one output, zero bank overruns and zero stalls, but the first S2MM transfer ended with `DMAIntErr` (`0x5011`). The exact cause is still open. `IOC` alongside an error and a length readback of `57600` do not establish where TLAST landed or how many bytes reached memory.
- Use the ILA at the **DMA1 S2MM input**. Count accepted bytes (`TVALID && TREADY`, using `TKEEP` if present) between packet boundaries. Check that the final accepted beat carries `TLAST`, and that the stream holds `TDATA`, `TLAST`, and any `TKEEP` stable during stalls. For a full-width stream, expect 14,400 accepted 32-bit beats or 7,200 accepted 64-bit beats per packet. Also verify DMA1's HWH configuration, including stream width, simple versus Micro DMA mode, and the buffer length register width.
- Check both `AVG_N=0` and `AVG_N=1`, sustained capture, and restart after stopping the stimulus. Compare `AVG_FRAMES_IN`, `AVG_FRAMES_OUT`, `AVG_BANK_OVERRUN`, `AVG_DROPPED_SAMPLES`, and `AVG_OUT_STALL` before and after each run. If output dries up after a stall, inspect avg bank release and whether input acceptance resumes.

## 2. Make the board test report actual lengths

The intended format is one 720-degree engine cycle per packet at `DMA_BUFFER_SIZE=1`, with fixed 0.1-degree spacing, 7,200 samples, and two little-endian 32-bit words per sample (57,600 bytes). Lower-resolution views can be derived in software.

- `count_s2mm_frames.py` already reads `reported_bytes` on successful completion, but its per-frame output prints the requested byte, word, and sample counts. Print both expected and actual bytes and flag any completion that is short or is not aligned to an 8-byte sample. Update the script's opening description accordingly.
- In standard direct-register S2MM mode, writing `S2MM_LENGTH` arms the receive buffer with a byte capacity. The packet ends at `TLAST`, and successful completion updates the register with actual bytes written. The fixed 57,600-byte frame is an Angus contract to check in software. AMD specifies exact length matching for Micro DMA. [AMD PG021 direct register mode](https://docs.amd.com/r/en-US/pg021_axi_dma/Direct-Register-Mode-Simple-DMA), [S2MM_LENGTH register](https://docs.amd.com/r/en-US/pg021_axi_dma/S2MM_LENGTH-S2MM-DMA-Buffer-Length-Register-Offset-58h).
- Validate reset semantics against the loaded bitstream. The counter writes `1` before arming and `0` after writing `S2MM_LENGTH`. The map describes `RAW_STREAM_RESET` as a one-clock pulse, so the final write cannot hold or release the internal reset across the arm operation. `AVG_RESET` was described as rising-edge triggered, while the map also mentions holding reset across arm. Confirm the actual PL behavior and capture-enable ordering before reusing this sequence in the server.

Current isolated board tests, with the server stopped so each test owns its DMA channel:

```bash
sudo -E python count_s2mm_frames.py --dma-name axi_dma_0 --configure --samples 7200 --raw-stream-reset --regs-every 10
sudo -E python count_s2mm_frames.py --dma-name axi_dma_1 --configure --samples 7200 --avg-n 0 --avg-reset --regs-every 10
sudo -E python count_s2mm_frames.py --dma-name axi_dma_1 --configure --samples 7200 --avg-n 1 --avg-reset --regs-every 10
```

## 3. Bring the API and clients up to date

- Replace the removed `AVG_FRAME_COUNT` and old beat/TLAST counter lookups in `server.py` with named reads from `angus_regs.py`. Keep the API's `frame_count` field backed by `AVG_FRAMES_OUT` so existing plot clients can still read it. Correct the stale labels in startup snapshots and `test_direct_s2mm.py` as well.
- Make `AVG_N` an exponent throughout the API and GUI. The register description specifies `0..3` for windows of 1, 2, 4, and 8 input frames. The server and PyQt still allow `0..255` and default to `7`, and the counter currently clamps to the four-bit field width. Apply the supported range consistently and update `API.md`, including the old bypass examples.
- Once the board tests pass, carry the verified per-stream reset/arm sequence into the server. Validate completed lengths before forwarding buffers. Give each DMA channel a single receive owner and coordinate recovery with outstanding receives so reconnects and reconfiguration cannot arm the same channel concurrently.
- If the browser GUI is still in use, update its 14,400-sample default and explicit stream selection to match the current API. Verify `/plot/config`, `/dma/status`, and the PyQt display for the hardware window and output-frame count. Then exercise raw and avg WebSockets through startup reconfiguration and a stimulus stop/restart.

## Deferred logging work

Implement and benchmark PS-side receive buffering, the in-memory pre-trigger cycle history, post-trigger capture, and incremental HDF5 writing and review. Keep the SD card for capture files. At 20,000 RPM the current two-word format implies about 167 raw frames/s and 9.6 MB/s of raw payload before file overhead. Qualify the DMA and writer at that rate before treating sustained logging as ready.
