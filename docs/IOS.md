# God's Eye View on iOS

The iPhone app is the existing web client inside a Capacitor shell. It boots
from the files in the IPA: bundled assets load from `capacitor://localhost`.
WKWebView cannot register `https` as that scheme. iOS cannot run the Node
server, so live `/api` data needs a copy of this repo that you host. Provider
keys stay on that server. The `.ipa` from GitHub Actions is unsigned;
[Sideloadly](https://sideloadly.io/) re-signs it with your Apple ID. A paid
Apple Developer team and a provisioning profile are not required.

## 1. Host the backend on Render

[`render.yaml`](../render.yaml) is a Render blueprint for the free web tier. It
builds the repo [`Dockerfile`](../Dockerfile). That image runs the Vite server,
which serves the client and every `/api` proxy.

1. Push this repo to GitHub and, in the Render dashboard, create a Blueprint
   from `render.yaml` (or a Docker web service pointed at the Dockerfile).
2. Set `GEV_ALLOWED_HOSTS` to the hostname Render gives the service, for
   example `gods-eye-view.onrender.com`. IP addresses and `localhost` are
   always allowed; other names are not. Render also sets
   `RENDER_EXTERNAL_HOSTNAME`, and the server allows that name when it is
   present.
3. Add provider keys as environment variables on the service (`OPENAI_API_KEY`,
   `GOOGLE_MAPS_SERVER_API_KEY`, and the others in [`.env.example`](../.env.example)).
   Do not prefix server keys with `VITE_`. Set quotas and billing alerts at
   each provider before you do this.
4. Leave `GEV_TRUST_NATIVE_CLIENTS` at `1` if the iPhone app should use keyed
   routes (voice, places, news, traffic, Mapillary) through Render's proxy.
   Render adds `X-Forwarded-*` headers, and those routes refuse proxied
   requests unless this is set. The flag is not a password: the public URL
   can spend keys for anyone who can reach it, under the app's per-IP limits.
   Set it to `0` to refuse those proxied calls. Keyless globe data (flights,
   ships, earthquakes, terrain, satellites, CCTV catalogs, and the other
   routes that do not check forwarding headers) works either way.
5. `GEV_KEY_SETUP_TRUSTED_PEERS=none` keeps the POWER UP key editor off the
   public URL. Change keys in the Render dashboard, not in the phone app.

The free instance sleeps when idle. The first request after a sleep can take
half a minute.

CORS allows only `capacitor://localhost` and `ionic://localhost`, which is the
installed app's origin. A normal website cannot send that `Origin`.

## 2. Point the app at the server

The client calls `/api/...` on its own origin unless a base is set.

- **Build time.** Repository variable or Actions secret `VITE_API_BASE`, for
  example `https://gods-eye-view.onrender.com` (no trailing `/api`). The iOS
  workflow injects it when it runs `npm run build`. An empty value leaves the
  app same-origin until you set the uplink below. `npm run dev` and the web
  build stay same-origin when the variable is unset.
- **On the phone.** Open **UPLINK** (the chip on a phone or in the installed
  app, and the same control inside POWER UP on the dev server). Paste the
  server URL and save. The page reloads and later `/api` calls go there. Clear
  restores the build-time value. The choice is stored on the device.

`https://` is the right scheme for a public server. The iOS shell allows plain
`http://` as well, so a LAN server works, but do not put a public server on
`http://`.

## 3. Download the IPA

The workflow [`.github/workflows/ios-ipa.yml`](../.github/workflows/ios-ipa.yml)
runs on a push to `cursor/ios-capacitor-ipa-482f` and from the Actions tab
(**Run workflow**). It uses Node 24.22.2, `npm ci`, `vite build`,
`npx cap sync ios`, then `xcodebuild archive` with `CODE_SIGNING_ALLOWED=NO`
and `CODE_SIGNING_REQUIRED=NO`. The artifact is **GodsEyeView.ipa** (a zip of
`Payload/App.app`).

On the workflow run, open **Artifacts** and download `GodsEyeView.ipa`.

## 4. Install with Sideloadly

1. Install Sideloadly on a Mac or Windows PC and connect the iPhone.
2. Drag `GodsEyeView.ipa` into Sideloadly. Sign in with your Apple ID.
   Sideloadly re-signs the unsigned archive; you do not need a paid team.
3. On a free Apple ID the signature lasts **7 days**. Install again after it
   expires. A paid developer account lasts longer; Sideloadly still does the
   signing.
4. On iOS 16 and later, enable Developer Mode: Settings → Privacy & Security →
   Developer Mode, then restart. The app will not launch until you do.
5. If iOS asks you to trust the developer: Settings → General → VPN & Device
   Management → trust your Apple ID.

The bundle id is `com.dylanlang.godseyeview`. The name on the home screen is
God's Eye View. Portrait and landscape are both supported.

## What is limited on iOS

- **No local server and no POWER UP key saving.** Paste keys into the hosted
  service's environment. The phone never sees server-side keys.
- **Photorealistic 3D tiles and Cesium ion** need `GOOGLE_MAPS_API_KEY` and
  `CESIUM_ION_TOKEN`. Those two are client-side by design (see SECURITY.md).
  The IPA workflow does not bake them in, so a stock artifact starts on the
  keyless imagery. Add them as build-time environment variables only if you
  accept them shipping inside the app, and restrict them at the provider.
- **Keyed proxies on Render** need `GEV_TRUST_NATIVE_CLIENTS=1`. Without it,
  voice, Google Places, news, TomTom traffic and Mapillary return 403 because
  Render is a reverse proxy.
- **ChatGPT OAuth / Codex sign-in** runs a local CLI on the server and answers
  only on loopback. It does not work from the phone. Use `OPENAI_API_KEY` for
  voice.
- **Local RTL-SDR and local ADS-B receivers** are hardware on the machine
  running the server, not on the phone.
- **Microphone** is used for voice control. **Location** is used to tune
  nearby radio and to center the globe. iOS asks the first time each is used.
- WebGL, inline video and the globe run in WKWebView. A free Render instance
  can be slow to wake, and a phone GPU will not match a desktop for dense
  layers.
