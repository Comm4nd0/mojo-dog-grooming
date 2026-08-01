# Jess's paper cards

Transcribed from the three PDFs attached to "Fwd: Data input", 28 July 2026. These are the
forms Mojo and Co ran on paper before the app, and they are the specification the online forms
are being brought up to. Fields are listed in the order they appear on the card.

The originals live on that email. They are not in the repo — the transcription is what the code
is written against, and it diffs.

---

## 1. Grooming Booking Card

Two pages. Page 1 is the card, page 2 is the policies sheet reproduced below. Filled in once,
by a **new client**, before the first groom. This is what `/intake/<token>/` replaces.

### The dog

| Field | Notes |
|---|---|
| Dog's name | |
| Sex | Male / Female |
| Date of birth | |
| Breed | |
| Colour | |
| Neutered | Yes / No |
| Microchip number | |
| What vaccine's & when | |
| Any allergies of the dog | Yes (state below) / No |
| Any medications the dog is on | Yes (state below) / No |
| Any known medical issues | Yes (state below) / No |
| Vet's name | |
| Vet's number | |
| Vet's address | |
| What was your last vet trip for | |
| What grooming do you carry out yourself for your dog, and how often | |
| What you're expecting of your dog's groom | "please include any particular styles of trim/head/feet/tail" |

### The owner

| Field |
|---|
| Your name |
| Your contact number |
| Your email address |
| Your home address |
| Additional contact name and number (ICE) |

### The sketch

A dog silhouette. "On the below sketch please highlight any of the following" —

- sensitive skin issues
- if they are unhappy with touching
- any past procedures carried out on your dog
- any problem areas on the dog

### The disclaimers

"These need to each be signed and dated that you agree" — six of them, individually:

1. Please read and agree with our Policies When Grooming, attached with this document, and our
   Private Policy for how we use and store your data.
2. The information filled out on this card is to the best of my knowledge and it is my
   responsibility to update Mojo and Co with any changes.
3. If we feel a dog has detrimental matting we will take the whole coat off where required.
4. Any dogs that are un-cooperative for any part of the grooming may have a collar/muzzle put on
   for safety, this may affect the final groom of your dog.
5. Do you give permission for photos of your dog to be used on our website and social media
   pages?
6. In an emergency/accident your/a local vet will be contacted. If your dog has be taken in or
   treated, this will be at your cost.

Number 5 is the only one phrased as a question rather than a statement — it is genuinely
optional, and the other five are conditions of being groomed at all.

### Page 2 — Policies When Grooming your dog at Mojo and Co

> - The dog's health and welfare comes first (Animal Welfare Act 2007). We will only complete
>   the groom to suit the comfortably, health and welfare of any particular dog in our care,
>   taking extra care and caution for puppies, elderly dogs and those with pre-existing health
>   issues.
> - We are not veterinarians and are unable to diagnose any health issues your dog has, this
>   includes prescribing any veterinarian products
> - We do not permit any unreasonable hairstyle requests, this would include the coat being left
>   too long or too short, or incorrect groom style for the dogs coat
> - If we feel a dog has detrimental matting we will take the whole coat off where required
> - Any dogs that are un-cooperative for any part of the grooming, they may have a collar/muzzle
>   put on for safety, this may effect the final groom of your dog
> - Please note our Private Policy is available on our website
> - In an emergency/accident your/a local vet will be contacted, your dog may be taken in and
>   treated, at your cost
> - If we find a tick or fleas on your dog, we will remove them as best we can, using a tick
>   remover and flea shampoo, following this it should be followed by a vet consultation
> - We will try to fulfil the groom to the best of our ability but we will sometime be unable to
>   complete parts of the groom, please note this is only what we are unable to safely carry out

Reproduced verbatim, typos included — it is a policy document and the wording is Jess's.

---

## 2. Ongoing Record for Dogs

**Not a booking form.** Jess's own record of a groom that has happened, one block per visit,
two visits to a page. The client never sees it. It belongs against the groom session, not
against an intake.

| Field | Notes |
|---|---|
| Date of last visit | |
| How long visit was | |
| Anything found on health check | |
| Matting found — in paws | Y/N |
| Matting found — under armpits | Y/N |
| Matting found — under ears | Y/N |
| Matting found — anywhere else | Y/N |
| Bathing, well behaved | Y/N |
| High velocity dryer used | Y/N |
| Shampoo used | |
| List of equipment used | "Scissors / Clippers / Dryers / Brushes etc." |
| Final body trim | |
| Final feet shape | |
| Final tail | |
| Anything to note about visit | |
| Anywhere dog got didn't want to be touched / fidgety, sensitive etc. | |
| Overall temperament of dog | |
| Dog reference number | |

Note that "final body trim / feet shape / tail" is what was *done*, which is a different thing
from the `pref_body` / `pref_feet` / `pref_tail` the client asked for at intake.

---

## 3. Ongoing Record for Nails / Flee / Ticks

The same shape as the card above, for a **different and much shorter service** — a nails, flea
or tick visit rather than a groom. Nine blocks to a page, four pages.

| Field | Notes |
|---|---|
| Date of last visit | |
| How long visit was | |
| Nails / Flee / Ticks | which of the three the visit was for |
| Overall temperament of dog | |
| Anything to note about visit / anywhere dog got didn't want to be touched / fidgety, sensitive etc. | |
| Dog reference number | |

This card is the only evidence that Mojo and Co sells anything other than a full groom. The
price list Jess sent covers grooms only — there is no nail-clip price anywhere yet.

A tick or flea find can also happen mid-groom rather than as a booked visit; the policies sheet
covers that case.
