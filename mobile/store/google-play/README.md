# Google Play store graphics

Uploaded by hand in Play Console → Grow → Store presence → Main store listing.
`fastlane/Fastfile` deliberately skips images, and `fastlane/metadata/` is
gitignored, so these live here instead.

| File | Play slot | Spec |
|---|---|---|
| `icon-512.png` | App icon | 512 × 512 PNG, no transparency |
| `feature-graphic-1024x500.png` | Feature graphic | 1024 × 500, no alpha channel |
| `feature-graphic-1024x500-pale.png` | Alternative feature graphic | same |

Nothing here is new artwork. The icon is the iOS 1024 px app icon
(`ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png`)
scaled down, so the store and the home screen show the same dog. The feature
graphics are the designer's full lockup from the brand pack
(`~/Projects/mojo-and-co`, High Res PNG), cropped to its artwork and centred:
the Light Green colourway on `#015412` (the dark `tint` role) for the main one,
Dark Green on `#EDFFEE` (`tintWash`) for the pale one. The deep ground is the
main one because Play's own pages are white and the pale one nearly vanishes
against them.

The feature graphic is saved without an alpha channel on purpose — Play
rejects one that has it.
