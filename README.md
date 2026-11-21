# Immich Gallery for KOReader

Turn a Kindle or Kobo into a picture frame for an [Immich](https://immich.app) share. When the
device sits idle, this [KOReader](https://koreader.rocks) plugin shows a random photo from the share
full screen and changes it every few seconds. A tap brings you back to KOReader.

- **Any Immich share link.** Album or individual photos, with or without a password.
- **Made for E-Ink.** Every photo is cropped once to your screen and dithered to the 16 grey levels
  of the display. Landscape photos are rotated so that the long edge fills the screen.
- **Works offline.** Photos are stored on the device and synced in the background while Wi-Fi is
  on. Removed photos disappear with the next complete sync.
- **Its own settings page.** Share URL, password, extra headers for a reverse proxy, connection
  test, sync interval, idle time and picture intervals, without editing files.
- **Screensaver.** Optionally the same photos appear when the device goes to sleep, without
  KOReader's "Sleeping" message on top.
- **15 languages.** English, German, French, Spanish, Italian, Portuguese, Polish, Romanian, Dutch,
  Greek, Simplified Chinese, Japanese, Hindi, Bengali and Indonesian. The plugin follows
  KOReader's language setting and falls back to English.

## Installation

**With Storefront or the AppStore:** install
[Storefront](https://github.com/ultimatejimmy/storefront.koplugin) or
[appstore.koplugin](https://github.com/omer-faruq/appstore.koplugin), search for "immich-gallery"
and install.

**By hand:** download `immich-gallery.koplugin-vX.Y.Z.zip` from the [releases](../../releases),
copy the folder `immich-gallery.koplugin` into `koreader/plugins/` and restart KOReader.

The plugin can also update itself without a computer: Tools › Immich Gallery › Check for updates
looks for a new release in this repository. A fork can enter its own repository under Settings ›
Updates.

## Setup

1. In Immich, share an album (or a few photos) and copy the link. A password is optional.
2. On the device: Tools › Immich Gallery › Settings.
3. Enter the share URL, the password if any, and extra headers if your server sits behind a
   proxy that wants a key. **Test** signs in and counts the photos.
4. **Sync now** downloads the photos. After that, the plugin syncs on its own while Wi-Fi is on.

| Setting | Default |
|---|---|
| Sync automatically | every 30 minutes while Wi-Fi is on |
| Start after idle time | 5 minutes (under 10, so the device does not fall asleep first) |
| Next picture when charging | 1 minute |
| Next picture on battery | 5 minutes |
| Landscape pictures | rotate left |

## While the frame runs

- The device stays awake and the frontlight is off. A longer interval on battery only saves the
  page refreshes, so keep the device on a charger.
- A tap or any key ends the frame. It starts again after the idle time.
- Tools › Immich Gallery › Show picture frame now starts it right away.

## Security

- HTTPS connections verify the certificate chain against KOReader's CA bundle and check the host
  name. KOReader itself does neither for plugin requests.
- The plugin does not follow redirects, so the password and extra headers never reach another
  host.
- Password and header values are stored in plain text in `koreader/settings/immich-gallery.lua`
  on the device and never written to a log. Use a share with only the photos you want on the
  frame, and revoke the link if the device gets lost.
- After an "access denied" (403) answer the plugin pauses syncing for 15 minutes, so tools like
  fail2ban in front of your server do not lock it out.

## Translations

Texts live in `immich-gallery.koplugin/immichgallery/l10n/<language>.lua`. The keys are the
German texts from the code; `en.lua` holds every key with its English text. To add a language, copy
it to the KOReader language code (for example `sv.lua`), translate the values, keep `%1`, `%2` …,
and run the checks below.

## Development

```sh
luajit tests/test_logic.lua   # share URLs, certificate names, cropping, rotation, errors
luajit tests/check_l10n.lua   # every language: complete, placeholders, plural forms
```

A release is made by pushing a tag `vX.Y.Z`; the version must already be in
`immich-gallery.koplugin/_meta.lua`.

## License

[Mozilla Public License 2.0](LICENSE). You may use, change and share the plugin, also as part of a
larger work. Changes to its files stay under the MPL and have to be shared as source code.
