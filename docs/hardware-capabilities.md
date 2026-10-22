# U60 Pro hardware capabilities

Inspected on the attached EU/Poland U60 Pro on 2026-10-21. Driver interfaces are
distinguished from capabilities that have actually been exercised.

| Capability | Evidence and usable boundary |
| --- | --- |
| ARM64 compute | Four online CPU cores; maximum clock 2.208 GHz. Linux reports 1,628,400 KiB of usable RAM. Suitable for lightweight local network services. |
| Storage | eMMC exposes 15,147,008 512-byte sectors. `/data` is about 1.8 GiB, with about 1.8 GiB available at inspection. Do not repurpose firmware/A-B partitions. |
| Dual-band Wi-Fi | Live `wlan2` managed uplink at 5 GHz/160 MHz and `wlan0` AP at 2.4 GHz/40 MHz. Repeater/NAT is already exercised; this is not transparent Ethernet bridging. |
| USB data | DWC3 reports a SuperSpeedPlus maximum and a current SuperSpeed connection. USB networking and ADB are exercised. Type-C advertises host/device and source/sink roles. |
| USB expansion | USB mass-storage/UAS, CDC Ethernet and RTL8152 drivers exist. Host-mode operation with an external drive or Ethernet adapter still needs a physical peripheral test. No role switch was made during inspection. |
| Power | Battery, charger, Type-C and reverse-power interfaces expose current, voltage, power, temperature, charge limits and cycle count. The battery's design charge is 10,214,000 microamp-hours. Current negotiated input is not the maximum charging capability. |
| Thermal/SAR | CPU/modem/PMIC/battery/USB thermal zones and an AW9610x SAR driver are present. SAR is radio-proximity support, not proof of a general gesture or motion sensor. |
| Display/input | Existing 320x480 RGB565 touchscreen, power key and adjustable backlight are exercised by the native UI. |
| Audio | ALSA exposes AUXPCM playback/capture and vendor audio helpers exist. A real SIM call must establish the cellular audio route; device nodes alone do not establish a microphone, speaker or working voice bridge. |
| NFC | Official specifications support Android Wi-Fi quick connection and the vendor SDK exports NFC settings. Rewriting a connection payload has not been verified on this unit. |
| Bluetooth/GNSS/camera | No active Bluetooth adapter, GNSS class device or `/dev/video*` endpoint was found. Generic kernel class directories and chipset-family capabilities do not establish usable hardware. |

Official specifications identify the Snapdragon X75 platform, dual-band Wi-Fi 7,
a 10,000 mAh battery and up to 64 Wi-Fi clients. The official manual specifies
27 W charging input and 18 W reverse-power output; actual power depends on the
peer device, cable and negotiation. This corrects the older repository table's
15 W value, which is not the hardware maximum.

Sources: [ZTE product specifications](https://www.ztedevices.com/en/products/mobile-internet/5g-mbb/u60-pro.html),
[ZTE manual](https://oss.ztedevices.com/prod/cn/2025/03/2025040970.pdf),
and the live numeric/sysfs metadata described above.
