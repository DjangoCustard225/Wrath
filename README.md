<p align="center">
  <img src="AppIcon.png" width="112" alt="Wrath app icon">
</p>

<h1 align="center">Wrath</h1>

Wrath is a native media downloader for iOS, powered by yt-dlp, FFmpeg and gallery-dl. Paste a link, choose your options and save the file to your device.

Download the unsigned IPA from [the latest release](https://github.com/DjangoCustard225/Wrath/releases/latest) and sign it with your preferred sideloading tool. Choose `ios17+` for iOS 17 or later, or `ios26+` for the Liquid Glass interface on iOS 26 or later. Both versions use the same app ID, so installing one replaces the other.

## Screenshots

<picture>
  <source media="(max-width: 600px)" srcset="docs/screenshots/readme-mobile.png">
  <img src="docs/screenshots/readme-desktop.png" width="1050" alt="Wrath’s Downloads, media preview, options, download progress, and Library screens">
</picture>

## About

Wrath doesn’t host or provide any content. It’s simply a native wrapper around yt-dlp, FFmpeg and gallery-dl; downloads come from the links you provide.

Credit goes to the developers and contributors behind:

- [yt-dlp](https://github.com/yt-dlp/yt-dlp) for media extraction and website support.
- [FFmpeg](https://ffmpeg.org/) for media processing.
- [gallery-dl](https://github.com/mikf/gallery-dl) for photo galleries.

Wrath’s source is [MIT licensed](LICENSE). Bundled components retain their [own licenses](Wrath/Resources/Licenses).
