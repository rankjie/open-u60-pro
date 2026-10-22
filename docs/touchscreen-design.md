# Touchscreen design

The extension shares the factory screen's black canvas, white type and blue
accent. The factory status bar, lock screen, carousel and settings stay in place.
The first Home page uses the factory lock screen's Earth wallpaper, Chinese
24 px heading, 64 px numeric font, yellow upload arrow and green download arrow
when operating as a repeater. The upstream name and connection state replace
the lock's cellular notice, with upload above download at the lock's original
vertical positions. Units remain separate from the numbers. Long network names
are clipped to one line; missing samples show `--` with no invented unit or zero.
The status bar, carousel gestures and page indicator remain factory-owned.
SIM hotspot mode retains the factory Home.
In repeater mode the lock uses the same network name and connection state as
Home. Both use the same opaque status card, including the sampled numeric rates.
On the lock it stops at 378 px so the factory notification and unlock area stays
visible. Its objects do not consume touch or long-press input.
Both screens identify the active broadcast hotspot below the rates. Its name
and enabled state come from a read-only hostapd `STATUS` request to the opposite
radio; no Wi-Fi configuration or keys are read. Disabled and unavailable hotspot
states are explicit. The original lock notice remains unmodified underneath;
switching to SIM hotspot hides the added card. The lock's input, PIN/modal
layers and notification area remain factory-owned.

The Wi-Fi entry and its pages use Simplified Chinese, matching this device's
native menu. Network names, connection strings and addresses retain their exact
values; unexpected backend failures retain their technical details beneath a
Chinese error label. The firmware's active font manager supplies the same
20 px body/title and 16 px supporting fonts as the native Wi-Fi menu. Production
does not load another font file or cache font allocation addresses.
Controls share the native dark gray background, 16 px menu/field rounding,
subdued supporting text and 42 px header. Network rows are 52 px high. Keyboard
keys retain smaller corner radii for their 30 px width. Active bands and the
primary Connect action use blue; disabled Connect uses the neutral surface.

The native Wi-Fi settings list contains a **Wi-Fi 中继** row after the Wi-Fi and
band-steering switches. It uses the factory menu button class and participates in the
same scrolling layout. The row uses the factory chevron image with the same
24 px bounds and right inset as the original rows; the renderer fixture uses
the same image. Back from the repeater page returns to that native list;
Home keeps the original navigation. The repeater page has one header, the current
connection, band selection and scan, then a flat network list. A QR action in
the header opens app connection; Other network remains below the list. Selecting
a network opens its password form and Connect applies it immediately. Back
clears private input. Loading, empty, failed and unavailable states remain
explicit. QR failures hide stale codes and display their cause.
Opening Wi-Fi reuses a successful scan for 30 seconds from completion. The first
visit, an expired result or a band change scans again; Scan always refreshes
immediately. Empty successful results are cached, failures are not, and reopening
during an active scan does not queue another request.
The SIM hotspot action pairs its label with the firmware's mode-switch symbol.
It opens a modal explaining that upstream Wi-Fi will disconnect and the SIM
will supply internet. Only the explicit Switch action applies the mode; Cancel,
Back and locking leave the network unchanged. The modal blocks list interaction
and disables Switch while a Wi-Fi operation is pending.

All extension pages start below the 24 px factory status bar. Navigation and
keyboard targets retain at least 44 px height where screen space permits;
keyboard keys use 30 px width to fit the ten-column layout. Menu rows, fields and
buttons use the same rounded surfaces as the native menu.

The former Upgrade tile is **通话**, using the same native menu class, type and
surface. Its five-row history pages show the caller, direction/outcome and local
time. The neighboring **帮助** tile contains **使用帮助** and **固件升级**;
both dispatch the preserved original entries. Incoming and active calls place
a compact status/caller banner above the Home or lock content. It never consumes
touch and stays hidden on PIN, modal and other factory routes.

Validation uses the pinned factory renderer for interaction, masked input, QR,
redraw and lifetime tests, followed by a bounded device trial, physical input
navigation and screen inspection. The independent recovery guard and immutable
factory executable are unchanged; installer restore returns to the factory UI.
