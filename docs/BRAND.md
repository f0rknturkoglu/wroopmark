# wroopmark brand

## Name

- Always lowercase: **wroopmark**, also at the start of a sentence and in titles.
- One word. Not "Wroopmark", "WroopMark" or "wroop mark".
- In Turkish it takes suffixes with an apostrophe: wroopmark'a, wroopmark'ta, wroopmark'ı.

## Promise

**Your saved posts, videos and pages — offline, searchable, on your own devices.**

Three ideas carry every message, in this order:
1. **Yours**: no account, no server, no tracking; the archive lives on your devices.
2. **Whole**: the post is kept with its pictures, videos, thread and replies, not just a link.
3. **Findable**: text, pictures, speech and meaning are searchable.

## Voice

- Plain and concrete. Say what happens ("the pictures are downloaded to your
  phone"), not adjectives ("powerful", "seamless", "revolutionary").
- Short sentences, active voice, second person ("you save", "your archive").
- Never overclaim. The iPhone does not download videos from websites (App Store
  rule 5.2.3): say the videos come from your Mac or from files you add.

## Colours

| Role | Hex | Use |
|---|---|---|
| Accent | `#784AED` | buttons, links, tint (the apps' `accent`) |
| Gradient top | `#8C61F0` | store images, social preview |
| Gradient bottom | `#542EBD` | store images, social preview |
| Icon top | `#C9B2FA` | the app icon only |
| Ink on purple | `#FFFFFF` | headlines on the gradient |

Text on the gradient is white; keep it on the darker half when it is small.

## Type

- SF Pro (the system font) everywhere: Bold for headlines, Medium for sub-lines,
  Regular for body text. The reader lets you pick serif or sans for articles.

## Icon

- A white bookmark with a download arrow in front of a lighter one, on the purple
  gradient. Source files: `apple/Resources/AppIcon.icns`,
  `apple/iOS/Wroopmark/Assets.xcassets/AppIcon.appiconset`, `docs/logo.png` (512 px).
- Do not recolour, outline, or put it on a busy picture.

## Images

- `swift apple/scripts/store-images.swift` turns the app screenshots
  (`apple/iOS/Screenshots/{en,tr}/…`, taken from a demo library) into App Store
  images (`apple/iOS/Screenshots/store/`, not in git), README images
  (`docs/images/*.jpg`) and the GitHub social preview (`docs/images/social-preview.png`).
- Screenshots never show a real person's archive. The demo library uses
  Wikipedia articles; credit them as "Wikipedia, CC BY-SA 4.0".
- Status bar: 9:41, full battery (`xcrun simctl status_bar … override`).
