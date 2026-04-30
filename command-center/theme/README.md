# MayaOS LESS theme reskin (Phase 11)

STF's UI uses `bower` + `gulp` + `less` and exposes a single root LESS
file (`less/main.less`) you can override. We don't fork the upstream
codebase; we drop a sibling `mayaos.less` that re-defines the brand
colors / logo / favicon and gulp picks it up via STF's `--less-file`
flag (added in 3.7.0).

## Layout

```
command-center/theme/
├── README.md
├── less/
│   ├── mayaos.less           main LESS override file
│   ├── _variables.less       brand colors / type scale
│   └── _components.less      per-component overrides (sidebar, device-card)
└── images/
    ├── mayaos-logo.svg
    ├── mayaos-icon-192.png
    ├── mayaos-favicon.ico
    └── mayaos-bg.png
```

## How it lands in the container

`Dockerfile` (Phase 4) `COPY theme/ /opt/mdf/theme/`. The supervisord
unit for STF passes `--less-file /opt/mdf/theme/less/mayaos.less` and
`--public-dir /opt/mdf/theme/images` so STF's gulp build re-renders
the CSS bundle with our brand on container start.

## Brand tokens

```less
@brand-primary:    #5B41E0;   // MayaOS purple
@brand-secondary:  #00C2A8;   // MayaOS teal
@brand-warn:       #F5A524;
@brand-error:      #E5484D;
@font-family-sans: -apple-system, "SF Pro Text", system-ui, sans-serif;
```

## Reskin scope (rev 5.1 §11)

- App header: replace "STF" with the MayaOS wordmark + version pill
- Sidebar: re-color and re-icon
- Device card: show MayaOS channel badge (stable | canary | dev)
- Device detail: show "MayaOS Galaxy S26 Ultra" pill, Build pill,
  warmpool status
- Empty states + loading skeletons aligned to brand
- Favicon + apple-touch-icon
