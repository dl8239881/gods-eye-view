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
  unavailable instead of throwing a parse error.
  `render.yaml` is a free-tier blueprint; install steps are in
  `docs/IOS.md` (#1).
