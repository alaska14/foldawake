<div align="center">
  <img src="docs/assets/FoldAwake-Cover-1280x720.png" alt="FoldAwake Banner" width="800">
  <br><br>
  
  [![Get it on Gumroad](https://img.shields.io/badge/Get_it_on_Gumroad-%242.99+-102039?style=for-the-badge&logo=gumroad&logoColor=white)](https://monolabapps.gumroad.com/l/foldawake)
  [![License: MIT](https://img.shields.io/badge/License-MIT-lightgrey?style=for-the-badge)](LICENSE)
  [![AlternativeTo](https://img.shields.io/badge/AlternativeTo-Listed-blue?style=for-the-badge)](https://alternativeto.net/software/foldawake/)
</div>

<br>

# FoldAwake

> **Run your MacBook with the lid closed. Zero bloat, zero heat buildup.**

macOS normally puts your laptop to sleep the moment you shut the lid unless you're plugged into power, an external display, and a mouse. 

**FoldAwake** gives you a lightning-fast, one-click toggle in your menu bar that lets your Mac keep running heavy downloads, 3D slicing, video renders, audio playback, and code tasks with the lid closed—on battery or wall power, with no external display needed.

---

## ✨ Key Features

- ⚡ **True Clamshell Mode:** Shut your MacBook lid while on battery or power without triggering sleep. Keeps tasks alive on the move.
- 🌙 **Smart Auto-Dimming (Screen & Keyboard):** When the lid shuts while active, FoldAwake automatically dims the built-in display and keyboard backlight down to 0%. This eliminates heat buildup and battery drain inside laptop sleeves and bags! Brightness is seamlessly restored the instant you open the lid.
- 🎯 **1-Click Menu Bar Control (Option 1 Design):**
  - **Crisp White Clamshell (100%):** Active (laptop stays awake and working with lid shut).
  - **Dimmed Gray Clamshell (35%):** Inactive (normal macOS sleep when closed).
- ⏏️ **1-Click Safe Disk Ejection:** Right-click the menu bar icon to safely unmount all external USB/Thunderbolt drives before packing your laptop into your bag.
- 🍃 **Native AppKit Engineering:** Written directly in native Objective-C. Event-driven (no polling while clamshell mode is off), ~0% CPU and under 15MB RAM.
- 🔒 **Fail-Safe:** Quitting FoldAwake always restores normal lid sleep, and your on/off choice is remembered across restarts.

---

## 📦 Installation

### Get FoldAwake on Gumroad (recommended)
**[monolabapps.gumroad.com/l/foldawake](https://monolabapps.gumroad.com/l/foldawake)** gives you the ready-to-use app as a DMG, plus future updates. Open the DMG and drag `FoldAwake.app` to `/Applications`.

> **First launch:** MonoLab apps are not notarized by Apple yet. If macOS says the app can't be verified, right-click the app → **Open** (or System Settings → Privacy & Security → **Open Anyway**) once.

### Build from source
FoldAwake is open source (MIT). If you prefer to build it yourself, you need Apple's Command Line Tools (`xcode-select --install`):
```bash
git clone https://github.com/alaska14/foldawake.git
cd foldawake
./build.sh          # creates build/FoldAwake.app
```

## 💬 Feedback & Feature Requests

Have a suggestion, found an edge case, or want to report a bug?
- **[Open an Issue](https://github.com/alaska14/foldawake/issues)** right here on GitHub.
- Bought it on Gumroad? Just reply to your receipt email.

Crafted with care by **MonoLab**.
