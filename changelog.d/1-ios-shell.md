- The iOS shell is a Capacitor app (`com.dylanlang.godseyeview`) that loads
  the built client. `/api` calls stay on this page's origin unless
  `VITE_API_BASE` or the UPLINK control names a hosted server. The server
  allows `capacitor://localhost` and `ionic://localhost`, and
  `GEV_TRUST_NATIVE_CLIENTS=1` admits that app through a reverse proxy.
  Phone-width and coarse-pointer landscape screens use the bottom-sheet
  shell. `render.yaml` is a free-tier blueprint; install steps are in
  `docs/IOS.md` (#1).
