# Third-Party Notices — Sonar

New code in this repo is MIT (c) 2026 Sonar Contributors (see LICENSE).

## Upstream sources

### kmikiy/SpotMenu — MIT 2016 kmikiy
- URL: https://github.com/kmikiy/SpotMenu
- Upstream SHA at import: a114819310db63ba1a8b3f88b7c223eec8cf1873 (master, 2026-01-29, `chore: gitignore updated`)
- Used: menu UI, prefs, Spotify controller as fork base (Spotify-only strip, UI identical).
- Imported verbatim: `SpotMenu/`, `SpotMenu.xcodeproj`, `Sparkle/` (upstream `Sparkle/` contains `appcast.xml`; Sparkle framework itself resolves via SPM) + root `ISSUE_TEMPLATE.md` (required: referenced as a Resources build file by `SpotMenu.xcodeproj`; without it `xcodebuild` fails on `CpResource`). Sonar `LICENSE` (MIT 2026 Sonar Contributors) covers new code; upstream MIT text preserved below.
- Full upstream MIT text (`LICENSE` @ a114819310db63ba1a8b3f88b7c223eec8cf1873):

```
MIT License

Copyright (c) 2016 kmikiy

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### yasinozmeen/smartpause — MIT 2026 Yasin Özmen
- URL: https://github.com/yasinozmeen/smartpause
- Upstream SHA: TBD
- Used: poll detector + ownership patterns, verbatim with headers kept.
- Full MIT text to be appended at port.

### mattwong05/FlowSound — NO LICENSE (all rights reserved)
- URL: https://github.com/mattwong05/FlowSound
- Policy: ideas-only. No verbatim copy. Tap/ducking reimplemented from Apple docs:
  - https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps
  - https://developer.apple.com/documentation/coreaudio/catapdescription
- Do not vendor FlowSound files without written permission.
