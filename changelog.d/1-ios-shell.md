- The iOS shell is a Capacitor app (`com.dylanlang.godseyeview`) that loads
  the built client. `/api` calls stay on this page's origin unless
  `VITE_API_BASE` or the UPLINK control names a hosted server. The server
  allows `capacitor://localhost` and `ionic://localhost`, and
  `GEV_TRUST_NATIVE_CLIENTS=1` admits that app through a reverse proxy.
  Phone-width and coarse-pointer landscape screens use the bottom-sheet
  shell. Bundled scene assets load from `capacitor://localhost` and
  `ionic://localhost`, so the app boots with no server configured. With no
  uplink, the installed app reads CelesTrak, adsb.lol, OpenSky, Launch
  Library and the keyless NSW, TfL and Caltrans camera catalogs directly.
  Routes that need a server answer `Needs server, set UPLINK` instead of
  the page HTML. On the phone, submarine cables draw as thinned polylines
  and a capped set of landing points, not a ground-clamped entity per
  segment, and local infrastructure GeoJSON skips ground clamping and
  stays under a feature budget. A bad cable file sets the layer
  unavailable instead of throwing a parse error. The phone UI is a
  SwiftUI tab bar (Globe, Layers, Cameras, Search, Settings) around the
  full-screen globe. Web chrome stays hidden there. Layers, camera
  stills, place search, UPLINK and quality go through `gevShell`, and a
  tap on a flight, satellite or camera opens a native sheet. Page pinch
  is locked on the web view so the globe's own pinch keeps working. A
  one-finger drag rotates the globe: the web view's pan recognizer is
  disabled, so it cannot cancel that drag or bounce the page. The globe
  view stays attached while another tab is open, and a drag keeps
  requesting frames so a torn frame cannot sit on screen. IntelKit is
  linked into the app as a local package. The Intel tab lists people,
  places, events, and organizations, draws their links, fetches GDELT,
  and imports CSV or JSON. Entities with coordinates are pins on the
  globe.
  `render.yaml` is a free-tier blueprint; install steps are in
  `docs/IOS.md` (#1).
