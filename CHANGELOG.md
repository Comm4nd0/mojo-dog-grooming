# Changelog

The `## [x.y.z]` section for a version is what customers read on the App Store.
`tools/appstore_release.py` lifts the text between that heading and the next one
and posts it as "What's New in This Version", so write it for Jess's clients,
not for whoever is reading the diff. Apple caps it at 4000 characters.

Add what you change under **Unreleased** as you go. `tools/release.sh` renames
that heading to the version being cut, so there is nothing to remember at
release time — but it refuses to release with nothing under it, because blank
release notes on the App Store are worse than a delayed release.

Mojo and Co has not been released to the App Store yet. Everything below is
either on TestFlight or waiting for the first tag.

## [Unreleased]

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
- Your dog's profile now shows a groom report for every visit: what was done,
  anything that had to wait and why, and how they were on the day.
- When you ask for an appointment, the request form now tells you straight
  away if that time isn't available, so you can pick another rather than
  waiting to hear back.
- If you book more than one dog in at a time, they now go in as one visit with
  one length, so the diary shows how long you'll actually be with us.
- Behind the counter, the groom card can now be filled in while the groom is
  still being timed, so anything found in the health check goes on the record
  the moment it's found rather than at the end.
