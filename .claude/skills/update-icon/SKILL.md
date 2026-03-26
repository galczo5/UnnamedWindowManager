---
name: update-icon
description: Regenerate all app icon sizes from Icon.png and update the asset catalog. Use when the user says they changed/replaced/updated the icon, or asks to regenerate icon sizes.
---

Regenerate all macOS app icon sizes from the source `Icon.png` at the project root.

## Steps

1. Verify `Icon.png` exists at the project root.

2. Use `sips` to generate each required size into the asset catalog:

```bash
for size in 16 32 64 128 256 512 1024; do
  sips -z $size $size Icon.png --out "UnnamedWindowManager/Assets.xcassets/AppIcon.appiconset/icon_${size}x${size}.png"
done
```

3. Report which sizes were generated.

## Notes

- The source icon is always `Icon.png` in the project root.
- The destination is `UnnamedWindowManager/Assets.xcassets/AppIcon.appiconset/`.
- `Contents.json` in that directory already maps all sizes — do not modify it.
- Required sizes: 16, 32, 64, 128, 256, 512, 1024.
