# Third-party assets

## dog_silhouette.svg

Side-profile dog silhouette used on the problem-area picker, where staff and
owners mark areas of the dog on a 12 × 8 grid.

- **Source:** Pixabay, contributor `gdakaska` (original filename
  `gdakaska-dog-2798805.svg`, Pixabay ID 2798805)
- **Licence:** [Pixabay Content License](https://pixabay.com/service/license-summary/)
  — free for commercial use, no attribution required
- **Modifications:** none; the file is used verbatim. Colour is applied at
  render time with a `ColorFilter`, so the artwork carries no fill of its own.

Attribution is not required by the licence, but is recorded here so the
provenance is traceable if the asset is ever queried.

### Licence caveat for logo use — read before shipping the app icon

The Pixabay Content License lists as a Prohibited Use:

> You cannot use any of the Content as part of a trade-mark, design-mark,
> trade-name, business name or service mark.

Using the silhouette **inside** the app — the problem-area picker, the intake
form — is ordinary UI artwork and is not affected. Using it as the **app icon**
is different: an icon identifies the business's service, which is the kind of
use that clause covers.

`app_icon.svg` is currently built from this silhouette, so it is exposed to
that restriction. Before the app goes anywhere public, either replace the mark
with original artwork or one licensed for trade-mark use, or take advice on
whether the risk is acceptable. This note is a flag, not legal advice.

Replacing the silhouette is a drop-in: swap this file, keeping a single closed
path and a `viewBox` whose aspect matches `kSilhouetteAspect` in
`lib/widgets/dog_silhouette.dart` (or update that constant to match), then
regenerate the goldens with `flutter test --update-goldens`.
