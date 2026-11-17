# Vibechar app icon

Art selected **Graphite** on 2026-11-17: a softly beveled graphite tile, warm ivory
`V` and peach-orange cursor. The opaque tile sits inside a transparent square
canvas. Its padding and rounded corners are part of the master, so the Dock gets
the silhouette rather than a rectangular studio backdrop.

`AppIcon.icon/Assets/Graphite.png` is the selected 1254×1254 RGBA master, generated with the built-in
`image_gen.imagegen` tool. Exact generation/refinement prompts are recorded in
`generation.json`. The other concepts were exploratory previews; this is the
selected app identity.

`bash scripts/build-mac.sh` invokes `scripts/build-icon.sh` to export both a native
Icon Composer asset catalog and a legacy iconset. Xcode 26+ supplies `actool`.

`AppIcon.icon/icon.json` uses the selected artwork at its native size on a solid
graphite fill, with extra glass, translucency, specular and group shadows disabled
to preserve the chosen appearance. The system supplies the modern enclosure. This
avoids the extra gray backplate/inset seen when macOS 26+ loads a legacy bitmap alone.
`actool` compiles this into `Assets.car`; `CFBundleIconName` selects `AppIcon`.

The legacy macOS iconset includes 16, 32, 128, 256 and 512 pt, each at 1× and 2×,
up to 1024 px, with the selected tile's original transparency and margins.
`sips` resamples the selected image with its alpha intact; `iconutil` packages the
ten representations. The resulting `AppIcon.icns` lives in the bundle's Resources
and is referenced by `CFBundleIconFile` before code signing. Both resources are
packaged before signing. No runtime icon
generation, network access, extra resource loading or user-data migration is needed.

To export the icon alone:

```sh
bash scripts/build-icon.sh
```

Outputs: `dist/AppIcon.icns` and `dist/Assets.car`. Intermediate iconsets and compiled
catalog workspaces are disposable and cleaned up.
The master is the source of truth; do not regenerate it on ordinary app builds.

References: [Apple iconset format](https://developer.apple.com/library/archive/documentation/Xcode/Reference/xcode_ref-Asset_Catalog_Format/IconSetType.html),
[bundle icon declaration](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html),
[Icon Composer](https://developer.apple.com/icon-composer/).
