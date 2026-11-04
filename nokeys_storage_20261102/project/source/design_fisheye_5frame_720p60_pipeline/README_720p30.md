# 720p30 five-frame RGB565 design

Open `HDMI_DDR3_OV5640_test_720p30.pds` from the project root. This is a
separate design source; the existing 1080p project is unchanged.

## Current signal path

OV5640 8-bit DVP RGB565 at 1280x720 -> 16-bit pixel packing -> three raw DDR
frame banks -> two source-tile caches and unchanged bilinear interpolator ->
two corrected DDR frame banks -> native 1280x720p30 HDMI. The IMU/UART path
and on-screen CAM/RAW/REN/FPS/LAT counters remain connected.

The display PLL stays at 74.25 MHz. HDMI timing is 3300x750 total pixels,
which is nominally 30.000 Hz. The camera configuration uses 1892x740 sensor
timing and register 0x3036=0x69 (multiplier 105) for the module's 24 MHz
oscillator; the 25 MHz FPGA clock serves register configuration, not sensor
XCLK. See FPS30_FIXED_README.txt. Board throughput must still be remeasured
after loading a newly generated calibrated bitstream.

## Active calibration: 2026-10-02

The active tables in `source/design_fisheye_5frame_720p30/data/` now contain
the calibrated fisheye inverse mapping; they are no longer identity tables.
Calibration uses 8x11 inner corners, 6 mm spacing, and k1/k2/k3 with k4=0.
Fifty of 54 images were retained after iterative fitting; each retained
image has native-720p reprojection RMS strictly below 0.35 px. Overall RMS
is 0.2149984816 px; the largest retained per-image RMS is 0.3347945852 px.
Source PNGs are 1920x1080 full-frame OBS-scaled captures; the user confirmed
uniform 1.5x scaling without cropping, and corners were scaled by 2/3 before
calibration. No original photo was deleted.

`calibration_720p.json` retains full-precision K/D. `crop_config.json` records
the centered projection with output focal scale 0.81. The optical black
border is excluded while output remains 1280x720. Offline validation checks
all 921600 hardware-quantized 2x2 neighborhoods and all 230 ROIs; the largest
ROI is 160x52, within the unchanged 160x56 source cache. This retains a wide
rectilinear field of view; natural perspective stretch near the image edges
is not removed by basic fisheye correction.

Do not use 1080p parameters with this sensor mode. To regenerate this pair
of tables from the installed calibration and crop configuration:

1. Use the installed OpenCV fisheye report `calibration_720p.json` in `data/`.
   It must contain `image_size_width_height: [1280,720]` and
   `calibration.K`, `calibration.D`; the JSON generator currently expects
   `D[3]` to be zero.
2. Keep `crop_config.json` and `source_content_mask.png` with the report;
   if recalibrating, reselect and validate the crop projection. Run
   `python tools/generate_calibrated_tables.py` from any directory.
   Alternatively, export dense inverse `map_x` and `map_y` arrays of shape
   `[720,1280]` to an NPZ, then run
   `python tools/export_calibration_tables.py MAP.npz ../data` from `tools/`.
3. Check `data/table_report.json`, force a fresh compile/synthesis/route and
   generate a new FPGA bitstream, then remeasure
   CAM, RAW, REN and FPS. A calibrated map whose per-tile ROI exceeds
   160x56 needs a larger tile cache or a different tiling strategy.

The lower-level table-write ports exist, but the current top level ties them
off. Replacing the MEM files and rebuilding is the supported calibration path
for this version.

The existing `.sbit` files still contain the old LUT; editing MEM files does
not update an already generated bitstream. This calibration update does not
download to the board or claim hardware-verified image quality/frame rate.
The previous identity tables and generator are preserved in
`calibration_backups/20261002_720p_identity/`. Reports, reprojection errors,
selected-image copies and preview PNGs are in `calibration_20261002/`.

## Storage layout

Each of five DDR slots reserves 2 MiB (2^19 32-bit words). A 720p RGB565
frame occupies 1,843,200 bytes. Raw slots begin at word addresses 0x000000,
0x080000 and 0x100000; corrected slots at 0x180000 and 0x200000. The
reservation totals 10 MiB and does not change the physical DDR3 capacity.
The anchor ROM now contains 3726 entries and the tile ROI ROM 230 entries.

## Checks completed

`validate_720p.py` checks all project source references, DDR slot separation,
and every output pixel against its tile ROI. ModelSim syntax compilation and
Pango compile/synthesis were run on the staged design. Board frame rate,
image orientation, color, and camera timing are still to be confirmed on the
actual module.
