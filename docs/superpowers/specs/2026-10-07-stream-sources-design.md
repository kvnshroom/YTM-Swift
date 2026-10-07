# Stream sources: visionOS first, account for Premium, token as fallback

Date: 2026-10-07 · Status: approved design, not yet implemented · Fork-only document (not part of upstream PRs)

## Goal

Playback that works for everyone with the most native, lightest path available, and the best quality the
account is entitled to:

- **Free / signed-out users**: no WebKit, no JavaScript, AVPlayer only (visionOS client, AAC up to 128 kbps).
- **Premium users**: 256 kbps AAC (itag 141) through the signed-in WEB_REMIX client without a PO token,
  i.e. upstream's current path, which keeps working for Premium accounts.
- **Fallbacks** that heal on their own when a path stops working, and settings for users who want control.
- Built on top of upstream `master` so the maintainer can take it as small, independent pull requests.
  Quality comes first; upstream's style (structure, naming, Swift Testing) is followed.

## Background and evidence

- googlevideo cuts WEB_REMIX streams without a valid GVS PO token after ~1 MB (403) for free accounts.
  yt-dlp marks `web_music` HTTPS/DASH as `required=True, not_required_for_premium=True`; innertubex marks the
  same rule `premiumMayBypass = true`. Upstream works for its maintainer, who has Premium.
- The visionOS client (`VISIONOS`, client name 101, version 1.02) serves complete AAC/Opus streams with plain
  URLs: no signature or `n` solving, no PO token. Needs a `visitorData` (first request answers
  `LOGIN_REQUIRED` with a fresh one). Verified live on 2026-10-07 for music videos and audio-only tracks;
  17+ tracks played in the app. Max AAC is itag 140 (~128 kbps). yt-dlp added it in 2026-07 after
  `android_vr` started requiring tokens, so it may close some day.
- YT Music lists itag 141 (256 kbps AAC) only for Premium accounts (yt-dlp test: "Requires Premium: has
  format 141 when requested using YTM url").
- Professional projects use a fixed, curated client order, detect Premium as a property of the account
  (yt-dlp: once per run; innertubex: a `premium` flag "independently confirmed" by the caller), prefer
  signed-in clients when Premium and high quality apply (innertubex `premiumHighQuality`), let a manual
  override win (innertubex `playbackClientOverrideId`), and keep only a short failure memory
  (Metrolist `streamClientFailures` with a TTL). No persistent learning or scoring is used in practice.

## Design

### 1. Sources and decision

`StreamSource` has two user-visible cases: `visionOS` and `account`. Whether the account stream needs a
PO token is internal to the account source.

Per track, `StreamResolver`:

1. Starts the WEB_REMIX `player` request at once (history stats URLs, fallback, Premium detection).
2. Determines Premium state for this session:
   - signed out → not Premium;
   - otherwise Premium is a property of the account for the session: once any account response lists
     itag 141 (`offersPremiumAudio`, AVPlayer-compatible), it holds until the signed-in account changes
     or the app relaunches. Single tracks without itag 141 (e.g. some music videos) don't flip it back; a
     rejected token-free stream only switches the account to tokens. (Revised 2026-10-07 after review:
     "latest response decides" could alternate Premium users between 128 kbps and token mints.)
   - First track of a session (state unknown, mode Automatic, signed in): wait for the account response
     for at most **0.5 s**; if it isn't there in time, decide "not Premium" for this track.
3. Builds the order:
   - Automatic, not Premium (or quality Medium/Low): `visionOS, account`
   - Automatic, Premium and quality Auto/High: `account, visionOS`
   - Custom: the user's enabled sources in their order (never empty; see settings).
   Sources excluded by the failure memory (section 2) are skipped.
4. Tries the sources in order:
   - **visionOS**: request with the cached `visitorData` (retry once with a fresh one on
     `LOGIN_REQUIRED`), check playability, select the format (existing `selectAudioFormat`), require a
     plain URL. The stream starts immediately; history stats URLs arrive later via
     `ResolvedStream.lateTracking` from the account response.
   - **account**: check playability, select the format, decipher (JavaScriptCore). Token decision:
     Premium and token-free not rejected this session → probe once per session
     (`streamPlaysPastFirstMegabyte`, ranged GET at 1.5 MB: 206 = token-free works, 403 = needs token,
     else inconclusive → mint this time, probe again next time); otherwise mint a token
     (`PoTokenProvider`, short-lived WKWebView).
5. Returns `ResolvedStream` with URL, duration, loudness (upstream's volume normalization, from both
   sources), history data, and its origin (`source`, `usedToken`, `resolvedAt`). Updates `StreamStatus`.

### 2. Error handling

- **Source fails while resolving** (not playable, cipher-only URL, network, decipher, token): try the next
  source. If all fail, show the last error; in Custom mode with a single enabled source, add
  "Turn on another source in Settings → Streaming to try it as a fallback."
- **Stream dies mid-track**: `PlayerState` reports the failed `ResolvedStream` to the resolver, then reloads
  at the position reached (existing behavior; a second failure without 10 s of progress skips the track).
  The resolver classifies the failure:
  - stream older than 1 hour → expired URL: re-resolve with the same order, no penalty;
  - token-free account stream → mark "account needs a token" for the rest of the session;
  - otherwise → skip that source for that video for 10 minutes (Metrolist-style failure memory).
- Inconclusive probe or a late first account response: take the safe path (mint / visionOS) and decide
  again on the next track.
- Every decision is logged via `PlaybackLog` with its reason, e.g.
  `source order: account, visionOS (premium audio, quality auto)`.
- Nothing is persisted: session state and the 10-minute memory reset on relaunch; Premium state and the
  token flag reset on sign-in change (keyed by SAPISID).

### 3. Settings and status

Playback tab, new section **Streaming** below Audio (upstream layout: General, Playback, Equalizer,
Plugins, Storage).

- `Stream source`: segmented **Automatic | Custom**.
  - Automatic caption: "Picks the best source for each track: visionOS for speed and efficiency, your
    account for uploads and Premium quality."
  - Custom: rows with drag handle, toggle, title and summary:
    - visionOS — "No sign-in · up to 128 kbps · no web view"
    - YouTube Music account — "Signed in · up to 256 kbps with Premium · plays uploads"
    Caption: "Sources are tried from top to bottom. Drag to reorder; turn one off to never use it."
    Reorder by drag and by context menu (Move Up / Move Down). The last enabled source can't be turned
    off (tooltip explains). The custom order is kept while Automatic is selected; stored order is
    normalized on load (no duplicates, new sources appended, one always on).
- `Last stream`: live source and bitrate, e.g. "visionOS · 130 kbps"; with Premium a seal icon in the
  accent color and "· Premium"; with a minted token "· web token".
- Strings in English, Apple style, no internal terms (no "PO token", "WEB_REMIX").
- Not included: a Premium switch, token settings, bitrate in the player bar.

### 4. Integration, pull requests, testing

- Rebuild on upstream `master` (not a merge of the exploratory branch), reusing the proven code.
  Integrate with upstream's volume normalization (`loudnessDb` from both sources) and
  `ProxiedStreamLoader` (works for both sources; failure detection still applies).
- Stacked pull requests, each useful on its own:
  1. visionOS source + Automatic order + Premium detection (+ late history URLs).
  2. Mid-track reload + failure classification and memory.
  3. PO token fallback (`PoTokenProvider`, WebKit/BotGuard) incl. token-free probe for Premium.
  4. Streaming settings (Automatic / Custom) + `Last stream` status.
- Fork: `local/kvn` merges upstream `master`, then the four branches. `feat/visionos-stream` and
  `fix/playback-po-token` stay as archives.
- Tests (Swift Testing, written first): source order, Premium detection per response, the 0.5 s first-track
  deadline, expired-vs-rejected classification, failure memory TTL, session token flag, custom list
  normalization, `PlayerState` reload and late history. Time and network are injected.
- Test runs need a GUI session for `dev` (the hosted test runner can't start over SSH); nothing is reported
  as done without a passing run. Live tests on the user's Mac (free account) via builds in
  `/Users/Shared`; the Premium path is described for the maintainer to verify (expected log lines).
- Final review with the code-review skill before anything is proposed upstream; nothing is pushed or
  opened as a PR without the user's OK.

## Risks

- Premium path untested by us (two independent sources + upstream behavior; fallback limits impact).
- visionOS may close and the Premium token exemption may end; both are handled by the fallback.
- If YouTube forces SABR on these clients, none of the paths work; then web playback or a native SABR
  client would be needed (out of scope).
