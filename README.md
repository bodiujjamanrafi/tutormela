# Tutormela

Bangladesh-wide tutor finder using the installed React 19 / Vite 8 framework and the connected Tutormela Supabase project. All project files remain in this folder. Persistent user information uses Supabase Auth, PostgreSQL and Storage; the old SQLite demo API is retired.

## Run locally

Use Node 22.13 or newer:

```sh
npm install
npm run dev
```

Open http://127.0.0.1:5173. The supplied `.env.local` contains the project URL and publishable key. It is excluded from version control. `.env.example` documents required variables. Restart Vite after changing environment values.

The publishable key is intended for browser use. Database row-level security, role restrictions and storage policies protect data. Never put a secret key, service-role key, database password or administrative token in any `VITE_` variable.

## Database SQL

`supabase/schema.sql` is the complete, rerunnable PostgreSQL schema. It preserves existing records and includes tables, indexes, authenticated actions, signup trigger, catalog, approval rules and a private photo bucket. The core schema has been applied to the connected project.

**One permission-only follow-up remains:** run `supabase/permission-hardening.sql` in the Supabase SQL Editor. This removes public execution access to internal helpers and restricts public action functions to authenticated accounts. You chose to apply this file yourself. It changes permissions only, with no changes to tables or user records. Supabase currently flags the legacy signup helper and automatic-RLS helper for broad function execution; this fix resolves those [function permission advisories](https://supabase.com/docs/guides/database/database-linter?lint=0028_anon_security_definer_function_executable). The complete schema also includes this fix for future installations.

## Authentication configuration

In Supabase Authentication → URL Configuration, allow:

- `http://127.0.0.1:5173/**`
- `http://localhost:5173/**`
- Your eventual HTTPS production origin and its callback paths.

Set Site URL to the intended website origin. Registration uses email confirmation; check the email before signing in. Password recovery is connected through Supabase Auth. For public launch, configure custom SMTP for reliable confirmation and recovery mail. No email is sent by the verification scripts.

There are no demo login credentials and no public admin registration. Register a real student or tutor account. An owner can use `supabase/make-admin.sql` in the SQL Editor after replacing the email placeholder to provision a trusted moderator.

## Stored information and permissions

- Supabase Auth stores identities and password credentials. Passwords are never stored in application tables.
- `tm_accounts`: own private name, role, photo reference, optional phone, district, learning goals and search/language preferences.
- `tm_tutor_profiles`: education, subjects, classes, teaching areas, schedule, fees, bilingual descriptions and reviewed teaching photo. Drafts and pending profiles stay private; only approved profiles appear publicly.
- `tm_saved_tutors`: private student/guardian shortlist.
- `tm_contact_requests`: request content, consent, contact details and status. Only the requesting student and receiving tutor can read these records.
- `tm_profile_reviews`: tutor approval feedback for owner and moderators.
- `tm_audit_log`: moderator action history without private contact details.
- `tm_catalog`: the 64 districts and supported subjects, classes, modes and days.
- Private `tm-profile-photos` Storage bucket: device photos, with file references in PostgreSQL. Images are resized and re-encoded to remove location/device metadata. JPEG, PNG and WebP up to 2 MB are accepted. Approved teaching photos are available through short-lived signed URLs; personal account photos remain private.

Account details can be edited from the dashboard. Tutor profiles support saved drafts and approval submission. Editing a published teaching profile requires another review. Students can save tutors and send requests; tutors can accept or decline requests addressed to them. Administrators approve or return profiles with feedback.

Signing out clears private UI state. Sessions are managed by Supabase Auth with refresh support. Only authenticated accounts persist search preferences; unsigned visitors have temporary search state. Static assets, map geometry and fonts remain local files rather than database records. Legacy SQLite data is retained locally for recovery but is no longer used; invented example accounts were not copied into the live project.

## Verify and build

```sh
npm run verify
npm run verify:connection
npm run lint
npm run build
```

Schema verification runs in an isolated PostgreSQL instance and checks reruns, signup, role restrictions, private accounts, approval, shortlists, requests, consent and photo permissions. Connection verification performs read-only checks against the live project. These checks do not create live users or send email. A real confirmation-email and device-upload walkthrough requires signing in with your own verified account.

For a static local production preview:

```sh
npm run build
npm start
```

Open http://127.0.0.1:3001. The server serves the built website; all application data goes to Supabase. No website was published during this update.

## UI and map

Responsive formal typography, transparent frameless division-map marquee, map-only zoom, and all 64 district labels in English/Bengali remain in place. Authentic geoBoundaries geometry shares filter state with tutor search. Map/font licenses and attribution are retained in `src/assets/maps/ATTRIBUTION.md` and asset directories. Monetization, fake reviews and invented statistics are excluded.

## Hero background

The user-selected Pinterest floral reference is embedded once as an optimized WebP data URI in `src/assets/hero/background.css`. It fills only the hero with responsive cover positioning and a light readability overlay. The header, results, dashboards and expanded map keep their existing backgrounds. No external image request is needed. Source resolution is 1200 × 675; the original and provenance are retained in `src/assets/hero/`. An inline image still has normal browser decoding and stylesheet loading costs. Desktop, tablet and 320/390 px mobile previews have no horizontal overflow; map-only zoom remains functional.

## Login illustration

The login illustration is original inline SVG artwork in `src/AuthIllustration.jsx`, built entirely from code. It depicts a person studying with an open book and laptop, with a restrained teal and warm neutral palette. No raster image, embedded bitmap or external image request is used by the login illustration. It remains sharp at any display density. The person has subtle motion; the desk and form remain stationary. Pause/play and reduced-motion support are included. Login fields and authentication handlers remain unchanged. Desktop and 320/390 px mobile layouts were checked with no horizontal overflow or browser errors. The previously used Pinterest asset remains archived locally and is excluded from the production build.

## Social sign-in, verification and teaching updates

Google/Facebook logo-only controls, social account-type onboarding and tutor availability/status publishing are implemented. Statuses are database-backed and public only for approved tutor profiles. Four-digit email verification has a deployed SMTP Edge Function and server-enforced access rules, with attempt limits, expiry, session binding and resend limits. It remains inactive until SMTP configuration is complete; normal email/password login is retained during setup. Provider sign-in requires Google/Meta app configuration. Follow `supabase/AUTH_SETUP.md` for the exact secure setup steps and remaining permission-only SQL files. The complete schema includes this extension, with separate `social-login-and-status.sql` for existing installations.

Final verification for this extension: 65 isolated PostgreSQL schema/workflow/security checks, 14 read-only live connection checks, Deno type-check of the SMTP function, and a successful production build. Social button layouts and status consent controls were checked on desktop and narrow mobile without submitting real posts or sending email.

The login dialog is slightly wider (900 px desktop maximum) and uses an 8 px blurred backdrop. Spacing responds to viewport height, with a compact layout for small/landscape screens. Normal sign-in and registration fit without internal scrolling across the tested 1366×768, 1024×600, 768×1024, 390×844, 375×667, 320×568, 844×390 and 568×320 viewports. Essential inputs and actions are retained; optional illustration/copy yields space on short screens. Overflow remains available as an accessibility fallback for unusually small windows or enlarged text.


Local demo sign-in: when running the development website, the login dialog includes a Demo sign-in tab. Select Tutor or Student / guardian, enter any test email and nonempty test password, then choose Open demo profile. No email is sent, passwords are not stored, and profile edits/status updates are held only in memory until the page is refreshed. Demo contact requests and admin actions cannot reach Supabase. Demo sign-in is disabled in production builds. Real email authentication remains protected by Supabase; email delivery setup is documented in supabase/AUTH_SETUP.md.

Verify demo isolation and behavior with `node scripts/verify-demo.js`.


Tutor community update: apply `supabase/feed-and-profiles.sql` in the SQL Editor on an existing installation. The full `supabase/schema.sql` also includes this update. The live application was cancelled during this task; this feature SQL still needs applying. Tutors explicitly consent to sharing teaching details and photos; shared profiles appear immediately with pending review shown. Private drafts stay private, and admin rejection hides shared content. Email and phone are excluded from feed data. Contact requests remain limited to approved profiles. Reactions require verified sign-in. Post and profile view counts use unique visitors, exclude owners, and keep underlying visitor/reactor identifiers private. Anonymous browser visits are estimates and can be affected by cleared browser storage. No IP address is collected.

The local demo supports sharing a tutor identity, updates, edits and reactions across tutor/student test accounts in the same browser session. All demo data clears on page refresh; no demo passwords or records reach Supabase.

Verification: `node scripts/verify-feed.js`, `node scripts/verify-demo.js`, `npm run verify`, `npm run build`.
