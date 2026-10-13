# Build and Run XMRig in Termux (Android)

One script that builds **XMRig** on your Android phone in Termux, asks for your pool and wallet, sizes itself to your phone's hardware, and gives you simple start and stop scripts.

You can build either:

- **Standard XMRig** ([xmrig/xmrig](https://github.com/xmrig/xmrig)): works with any Monero pool. This is the default.
- **MoneroOcean XMRig** ([MoneroOcean/xmrig](https://github.com/MoneroOcean/xmrig)): switches automatically to the most profitable algorithm, but only on the MoneroOcean pool.

Both can be installed side by side. Just run the script twice.

## Quick start

```bash
pkg install -y git
git clone https://github.com/Bitofsin/install-Xmrig-Termux.git
cd install-Xmrig-Termux
chmod +x build_xmrig.sh
./build_xmrig.sh
```

Answer the questions, wait for the build to finish (often 10+ minutes on a phone), then start mining:

```bash
~/startxmrig.sh        # Standard XMRig
~/startxmrig-mo.sh     # MoneroOcean XMRig
```

> Install Termux from **F-Droid** or **GitHub**, not the Play Store. The Play Store version is outdated and its packages may fail to install.

## What you'll be asked

All questions come **before** the build, so the compile can run without you watching it.

| # | Question | Default |
|---|----------|---------|
| 1 | Which miner: Standard XMRig or MoneroOcean XMRig | Standard XMRig |
| 2 | Rebuild? *(only if that miner is already built)* | No (keep the build, just change settings) |
| 3 | Pool: MoneroOcean, SupportXMR, or custom `host:port` | Matches the miner you picked |
| 4 | Use TLS? | No |
| 5 | Wallet address *(checked; you can confirm a non-Monero username for custom pools)* | Script author's wallet ⚠️ |
| 6 | Worker name *(shown on the pool dashboard)* | Your phone's model, e.g. `Pixel_8` |
| 7 | Mining threads | `auto` |
| 8 | RandomX mode: `auto`, `fast` or `light` | `auto` |
| 9 | Start on boot? *(needs the Termux:Boot app)* | No |
| 10 | Summary of your choices, then **Continue?** | Yes |

⏰ **Each question waits 120 seconds.** If you don't answer in time, the default is used.

⚠️ **Set your own wallet.** The default wallet belongs to the script author. If you skip that question or let it time out, **you will be mining to someone else's wallet.** Check the summary before you confirm.

## What the script does

1. Checks that it's running in Termux and shows your phone's CPU, core count and RAM.
2. Asks the questions above.
3. Updates Termux and installs the build tools (`git`, `cmake`, `clang`, `make`, `libuv`, `openssl`).
4. Downloads the **latest tagged release** of the miner you picked.
5. Compiles it, using as many parallel jobs as your free RAM allows, up to 4, so the phone doesn't run out of memory or overheat.
6. Installs it to `~/xmrig` (standard) or `~/xmrig-mo` (MoneroOcean).
7. Creates the start script, a stop script, and optionally a boot script.

## Automatic hardware sizing

When threads and mode are left on `auto`, the start script checks your phone **every time it starts**:

- **Threads:** all cores. On phones with more than 4 cores it leaves one free so the phone stays usable.
- **RandomX mode:** `fast` if at least 3 GB of RAM is free, otherwise `light`. Fast is much quicker but needs about 2.5 GB. Light uses very little memory.

You can override either value for a single run:

```bash
THREADS=4 MODE=light ~/startxmrig.sh
```

## Starting, stopping and the wake lock

The start script turns on a **Termux wake lock** so Android doesn't put the CPU to sleep while mining. The lock is **released automatically** however the miner stops: with Ctrl+C, when the stop script is run, or if XMRig crashes.

| Action | Command |
|--------|---------|
| Start | `~/startxmrig.sh` or `~/startxmrig-mo.sh` |
| Stop | **Ctrl+C**, or run `~/stopxmrig.sh` from another Termux session |
| Show hashrate while running | press **h** |
| Pause / resume | press **p** / **r** |

`~/stopxmrig.sh` stops either miner, including one started at boot, and releases any wake lock left behind.

## Start on boot

If you answer yes to *Start on boot*:

1. Install the **Termux:Boot** app from the same place you got Termux (F-Droid or GitHub).
2. Open Termux:Boot **once** so Android allows it to run at startup.
3. After a reboot the miner starts by itself. Its output goes to `~/xmrig.log` or `~/xmrig-mo.log`.

Only one miner is set to start on boot at a time. Enabling one removes the other, so they don't compete for the same cores.

## Changing settings later

Run the script again, pick the same miner, and answer **No** to *Rebuild?*. You'll go straight to the pool and wallet questions and skip the compile.

## Skipping the questions

Settings can be passed in up front. This is handy when setting up several phones:

```bash
VARIANT=moneroocean POOL=gulf.moneroocean.stream:10128 \
WALLET=<your_wallet> WORKER=phone2 ./build_xmrig.sh
```

| Variable | Values |
|----------|--------|
| `VARIANT` | `upstream` (standard) or `moneroocean` |
| `POOL` | `host:port` |
| `TLS` | `y` or `n` |
| `WALLET` | your wallet address or pool username |
| `WORKER` | worker name |
| `XMRIG_VERSION` | a specific release tag, e.g. `v6.26.0` |

## Tips

- **Heat and battery:** mining runs the CPU flat out. Keep the phone cool and preferably plugged in. If it gets hot, lower the thread count.
- **Android killing the miner:** switch to `MODE=light`, or turn off battery optimization for Termux in Android settings.
- **32-bit phones:** these build and run, but RandomX is much slower than on 64-bit (`aarch64`).

## Release of Liability

By using this script, you acknowledge and agree to the following:

1. The script is provided on an "as-is" basis, without any warranties or guarantees of any kind, express or implied.
2. The script creator shall not be held responsible or liable for any misuse, damage (including damage to your device from heat or battery wear), loss of data, or any other harm caused by the use of this script.
3. You assume all responsibility and liability for the usage of this script.
4. It is your sole responsibility to ensure that you have the necessary authorization and comply with all applicable laws and regulations before engaging in cryptocurrency mining. Only mine on devices you own or have permission to use.
5. The script creator disclaims any and all liability for any actions, damages, or losses resulting from the use or misuse of this script.
