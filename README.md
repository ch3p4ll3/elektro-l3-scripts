# Elektro-L3 reception & processing scripts

Scripts to automatically receive **Elektro-L3** LRIT/HRIT broadcasts with
[SatDump](https://www.satdump.org) and turn the decoded products into
per-composite image archives and lossless timelapse videos.

```
rtl_tcp (SDR)  ──>  SatDump live decode  ──>  products/<date>/.../product.cbor
                                                  │
                        generate_images.sh  ──────┤
                                                  ▼
                              images/<composite>/<date>.png
                                                  │
                    generate_timelapse.sh  ───────┤
                                                  ▼
                              timelapses/<composite>.mkv + .mp4
```

## Repository layout

```
.
├── README.md
├── install.sh                    # curl | sh installer (see Quick install)
├── receive/                      # automatic reception (run by systemd)
│   ├── l3-lrit.sh                # one LRIT receive slot
│   ├── l3-hrit.sh                # one HRIT receive slot
│   └── systemd/
│       ├── l3-lrit.service       # oneshot unit that runs l3-lrit.sh
│       ├── l3-lrit.timer         # fires at :41 past every 3rd hour (UTC)
│       ├── l3-hrit.service       # oneshot unit that runs l3-hrit.sh
│       └── l3-hrit.timer         # fires at :11 past every 3rd hour (UTC)
└── postprocess/                  # manual scripts, run by you
    ├── generate_images.sh        # product.cbor -> PNG composites
    └── generate_timelapse.sh     # PNG composites -> timelapse .mkv/.mp4
```

## Dependencies

| Tool | Needed by | Purpose |
|---|---|---|
| **SatDump** (CLI `satdump`) | `receive/*.sh`, `generate_images.sh` | live decoding of LRIT/HRIT and processing of `product.cbor` |
| **ffmpeg** (with FFV1 encoder) | `generate_timelapse.sh` | lossless `.mkv` timelapses (FFV1 is built in) |
| **ffmpeg + libx264** (or libopenh264) | `generate_timelapse.sh` | optional phone-friendly `.mp4` |
| **rtl-sdr** (`rtl_tcp`) | `receive/*.sh` | network SDR server the scripts tune via `rtltcp` |
| **bash ≥ 4.3** | all scripts | `wait -n` job control |
| **GNU coreutils / findutils** | all scripts | `find`, `mktemp`, `sort -z`, … |
| **systemd** | `receive/systemd/*` | scheduling the receive slots |

### Fedora

```bash
# rtl-sdr, core tools, and (from RPM Fusion) a full ffmpeg with libx264
sudo dnf install rtl-sdr bash findutils
sudo dnf install https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm
sudo dnf install ffmpeg
```

(If you only have `ffmpeg-free`, FFV1 still works; the phone `.mp4` is then
encoded with `libopenh264` if available, or skipped with a warning.)

### Debian / Ubuntu

```bash
sudo apt update
sudo apt install rtl-sdr bash findutils coreutils ffmpeg
```

### SatDump

SatDump is **not** in the Fedora/Debian repositories. Choose one:

**A. Prebuilt Ubuntu .deb** — download from <https://www.satdump.org/download.htm>
(builds exist for x64 Ubuntu; on other distros prefer B).

**B. Build from source (recommended on Linux)** — follow the official SatDump
documentation: <https://docs.satdump.org/> → *Building / Installing* (distro
dependency one-liners for Debian/Ubuntu, Fedora/RHEL, openSUSE, Alpine,
Gentoo, plus the `cmake`/`make` steps). Building with
`-DCMAKE_INSTALL_PREFIX=/usr` is what puts the resources in
`/usr/share/satdump/` (see *Adding your own composites* below).
The same instructions are in the
[SatDump README](https://github.com/SatDump/SatDump#building--installing).

**C. AppImage / Flatpak** — work fine for the GUI, but the scripts call
`command -v satdump`, so make sure a plain `satdump` ends up on `PATH`
(e.g. symlink the AppImage to `/usr/local/bin/satdump`).

Verify:

```bash
satdump --version
ffmpeg -hide_banner -encoders | grep ffv1
```

---

## Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/ch3p4ll3/elektro-l3-scripts/main/install.sh | sh
# options go after "sh -s --", e.g.:
curl -fsSL https://raw.githubusercontent.com/ch3p4ll3/elektro-l3-scripts/main/install.sh \
  | sh -s -- --home /data/elektro_l3 --enable
```

The installer clones the repo to `~/.local/share/elektro-l3-scripts`, installs
`l3-lrit.sh`, `l3-hrit.sh`, `l3-generate-images` and `l3-generate-timelapse`
to `/usr/local/bin`, installs the systemd units (with `User=` set to you) and
writes `/etc/elektro-l3.conf`. Re-run it to update.

| Option | Meaning |
|---|---|
| `--home DIR` | the elektro_l3 data folder (default `~/Desktop/elektro_l3`) |
| `--enable` | enable and start both timers |
| `--no-systemd` | scripts only, no units |
| `--uninstall` [`--purge`] | remove what was installed (`--purge` also deletes the clone); data is never touched |

The manual steps below do the same thing by hand.

## The data folder (`L3_HOME`)

Everything is stored under one folder, `L3_HOME`:

```
<L3_HOME>/lrit/products   <L3_HOME>/lrit/images   <L3_HOME>/lrit/timelapses
<L3_HOME>/hrit/products
```

Every script resolves it the same way (first match wins):

1. `-d DIR` on the command line (`l3-lrit.sh -d /data/elektro_l3`)
2. the `L3_HOME` environment variable
3. `L3_HOME=...` in `/etc/elektro-l3.conf` (written by `install.sh --home`; this is
   what the systemd services use — edit the file to move the folder later)
4. `~/Desktop/elektro_l3`

## Where to save the files

Clone this repository **anywhere you like** (e.g.
`~/projects/elektro-l3-scripts`); the postprocess scripts are run from the
repo. The receive scripts and systemd units must be installed to fixed
locations, because the unit files reference `/usr/local/bin/...`:

```bash
# 1. Receive scripts -> /usr/local/bin
sudo install -m 755 receive/l3-lrit.sh receive/l3-hrit.sh /usr/local/bin/

# 2. systemd units -> /etc/systemd/system
sudo install -m 644 receive/systemd/l3-*.service receive/systemd/l3-*.timer /etc/systemd/system/

# 3. Enable the schedules
sudo systemctl daemon-reload
sudo systemctl enable --now l3-lrit.timer l3-hrit.timer
```

Postprocess scripts stay in the repo (they are already executable):

```bash
postprocess/generate_images.sh
postprocess/generate_timelapse.sh
```

## Configuration

Paths come from `L3_HOME` (see above). The radio settings are hard-coded in
the receive scripts — edit them before installing / running:

| File | Variable / setting | Default | Meaning |
|---|---|---|---|
| `receive/l3-lrit.sh` | `OUT` | `$L3_HOME/lrit/products/$STAMP` | where LRIT products are written |
| `receive/l3-hrit.sh` | `OUT` | `$L3_HOME/hrit/products/$STAMP` | where HRIT products are written |
| `receive/l3-*.sh` | `--ip_address` / `--port` | `192.168.0.1` / `1234` | rtl_tcp server feeding SatDump |
| `receive/l3-*.sh` | `--frequency` | `1691e6` | Elektro-L3 downlink (1691 MHz) |
| `receive/l3-*.sh` | `--samplerate` | `1.024e6` (LRIT), `2.56e6` (HRIT) | input sample rate |
| `receive/l3-*.sh` | `--gain`, `--bias`, `--timeout` | `32.8`, on, `900` s | tuner gain, bias-tee, slot length |
| `receive/l3-*.sh` | `--http_server` | `0.0.0.0:8080` | SatDump live view in a browser |
| `receive/systemd/l3-*.service` | `User=` | `mattia` | **change to your username** (`install.sh` does this for you) |
| `receive/systemd/l3-*.timer` | `OnCalendar` | `00,03,…,21:11` (HRIT), `…:41` (LRIT) UTC | schedule |
| `postprocess/generate_images.sh` | `PRODUCTS_ROOT` | `$L3_HOME/lrit/products` | input products tree |
| `postprocess/generate_images.sh` | `OUT_ROOT` | `$L3_HOME/lrit/images` | output composites |
| `postprocess/generate_timelapse.sh` | `IMAGES_ROOT` | `$L3_HOME/lrit/images` | input composites |
| `postprocess/generate_timelapse.sh` | `TIMELAPSE_ROOT` | `$L3_HOME/lrit/timelapses` | output videos (must be outside `IMAGES_ROOT`) |

> **Note:** `generate_images.sh` currently points at the *LRIT* products
> folder. To process HRIT acquisitions too, change `PRODUCTS_ROOT` (and
> `OUT_ROOT`) to `$L3_HOME/hrit/...` and run it a second time — or point both
> at a common parent directory.

---

## How it works

### 1. Reception (`receive/`)

Each `l3-lrit.timer` / `l3-hrit.timer` fires systemd every 3 hours
(00, 03, 06, 09, 12, 15, 18, 21 UTC), at **:41 for LRIT** and **:11 for
HRIT** — the Elektro-L3 broadcast schedule. The matching `l3-*.service`
(oneshot) starts `l3-hrit.sh` / `l3-lrit.sh`, which:

1. creates a UTC timestamp folder `<OUT>/../products/<YYYYMMDD_HHMM>`;
2. runs
   `satdump legacy live elektro_lrit|elektro_hrit <OUT> --source rtltcp ... --timeout 900`,
   i.e. connects to `rtl_tcp` on the LAN, tunes to 1691 MHz and decodes the
   downlink live for 900 s (15 min), writing frames and
   `product.cbor` product files into `<OUT>`;
3. exits (`exec`, so the systemd slot ends with the process).

`Persistent=false` means missed slots are **not** replayed after a reboot.
The live view is available on `http://<machine-ip>:8080` while a slot runs.

Manual test without systemd:

```bash
sudo rtl_tcp -a 0.0.0.0 -p 1234 &   # on the machine with the dongle
l3-lrit.sh                            # run one slot in the foreground (-d DIR to pick the data folder)
journalctl -u l3-lrit.service -f      # or inspect the last slot
```

### 2. Images (`postprocess/generate_images.sh`)

```
./generate_images.sh [-d L3_HOME] [-j JOBS] [products date folder]
```

Scans `<PRODUCTS_ROOT>/<date>/IMAGES/ELEKTRO-L3/<date>/.../product.cbor`,
runs `satdump process <folder> <tmpdir>` on every product **in parallel**
(`-j`, default 4), and copies each generated PNG to:

```
<OUT_ROOT>/<composite name>/<date>.png
```

Existing images are overwritten; temporary files live in
`/tmp/elektro_satdump.XXXXXX` and are removed on exit.

```bash
./generate_images.sh                      # everything, 4 jobs
./generate_images.sh -j 8                 # 8 parallel SatDump processes
./generate_images.sh 20261028_1241        # only products/20261028_1241
```

#### Adding your own composites

SatDump builds the Elektro-L3 images from the composites defined for the
MSU-GS instrument. Which composites exist is decided by the instrument
configuration file:

```
/usr/share/satdump/resources/instrument_cfgs/msu_gs.json
```

(If you run SatDump from a source tree or an AppImage, the same file lives
in `resources/instrument_cfgs/msu_gs.json` next to the `satdump` binary.)

To make an extra composite appear as its own output folder in
`<OUT_ROOT>/`:

1. **Back up and edit the file** (root needed for a system install):

   ```bash
   sudo cp /usr/share/satdump/resources/instrument_cfgs/msu_gs.json{,.bak}
   sudoedit /usr/share/satdump/resources/instrument_cfgs/msu_gs.json
   ```

2. **In the composite you want, set or add `"autogen": true`.** Each
   composite is a JSON object; keep its existing keys (channels, colour
   formulas, …) and add the flag inside that object:

   ```json
   "the_composite_you_want": {
       ...its existing definition...,
       "autogen": true
   }
   ```

   `"autogen": true` tells SatDump to generate that composite automatically
   while processing a product — i.e. no need to pick it by hand in the GUI,
   and `generate_images.sh` will pick it up from the CLI as well.

3. **Mind the JSON**: valid comma placement, double quotes, and no trailing
   comma before `}`. Check it with `python3 -m json.tool < msu_gs.json`.

4. **Restart anything that is already running** (the config is read at
   startup), then run:

   ```bash
   postprocess/generate_images.sh
   ```

   A new `<OUT_ROOT>/<composite name>/<date>.png` should appear;
   `generate_timelapse.sh` will then build a timelapse for it like any other
   composite.

Notes:

* The LRIT and HRIT pipelines share the same MSU-GS composite definitions,
  so the new composite becomes available for both after the edit.
* SatDump upgrades replace this file — keep your `.bak` (or a copy in this
  repo) and re-apply the `autogen` flag after updating.
* This is also the place to *remove* composites you don't want: without
  `"autogen": true` they aren't generated automatically.

### 3. Timelapses (`postprocess/generate_timelapse.sh`)

```
./generate_timelapse.sh [-d L3_HOME] [-j JOBS] [-f FPS] [-w WIDTH] [-L] [composite name]
```

For every folder in `<IMAGES_ROOT>` (frames sorted by filename, which sorts
chronologically thanks to the `YYYYMMDD_HHMM` names) it encodes:

* `<TIMELAPSE_ROOT>/<composite>.mkv` — **lossless FFV1**, intra-only: every
  frame is bit-identical to the source PNG (plays in VLC/mpv/ffplay, not in
  browsers);
* `<TIMELAPSE_ROOT>/<composite>.mp4` — high-quality H.264 for phones
  (not lossless; skipped with `-L`, downscaled with `-w 2048`).

```bash
./generate_timelapse.sh                             # all composites, 4 jobs, 10 fps
./generate_timelapse.sh -f 15                       # 15 fps
./generate_timelapse.sh -j 2 msu_gs_Natural_Color   # only one composite
```

At least 2 frames are required per composite.

## Typical day

```bash
# already automated by systemd:
#   l3-hrit.timer  -> 00,03,...,21:11 UTC
#   l3-lrit.timer  -> 00,03,...,21:41 UTC

# afterwards, by hand (or from cron):
postprocess/generate_images.sh -j 4
postprocess/generate_timelapse.sh -f 10
```

## Troubleshooting

```bash
systemctl list-timers 'l3-*'                       # are the timers active?
journalctl -u l3-lrit.service -u l3-hrit.service   # last receive logs
satdump sdr_probe                                  # SDRs visible to SatDump
command -v satdump && ffmpeg -hide_banner -encoders | grep -E 'ffv1|libx264'
```

* `Error: satdump not found in PATH` → SatDump is not installed on `PATH`
  (a Flatpak/AppImage needs a symlink; see Dependencies).
* Empty products → check `rtl_tcp` is running and reachable at the
  `--ip_address`/`--port` in the script, and that the bias-tee/gain suit
  your antenna.
* `no H.264 encoder found` → install ffmpeg with `libx264` (RPM Fusion /
  Debian `ffmpeg`); the lossless `.mkv` is still produced.
