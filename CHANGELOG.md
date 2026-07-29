# Changelog

The `## [x.y.z]` section for a version is what customers read on the App Store.
`tools/appstore_release.py` lifts the text between that heading and the next one
and posts it as "What's New in This Version", so write it for Jess's clients,
not for whoever is reading the diff. Apple caps it at 4000 characters.

A release will not start unless the version being tagged has a section here.

## [1.10.0] - unreleased

Getting back into your account no longer means starting again.

- Forgotten your password? There's now a link on the sign-in screen. Mojo and Co
  will send you a way to set a new one.
- Sign in with your email address as well as your username — whichever you
  remember, in whatever capitalisation.
- Unlock the app with Face ID or your fingerprint instead of typing a password
  every time. Turn it on from the account menu; it's per account, so you can
  lock one and not another.
- Creating an account now asks for your password twice, so a typo can't leave
  you locked out of an account you just made.

## [1.9.13]

The last version released before this changelog was started. Earlier history is
in the git log.
