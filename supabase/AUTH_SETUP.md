# Tutormela sign-in setup

## Direct four-digit verification

Email/password sign-in now opens the four-digit verification form directly. New accounts use `email-signup-code` instead of Supabase's native signup confirmation-link email. Existing unconfirmed accounts enter the same flow. Confirmed accounts continue through the authenticated `email-login-code` function.

**Database step pending:** the live execution was cancelled. Run **`supabase/signup-email-code.sql`** once in the project's Supabase SQL Editor. It creates private, server-only challenges and rate limits plus one RPC restricted to `service_role`. It does not change existing accounts, passwords, roles or global email-confirmation settings. The complete `schema.sql` includes this feature for new installations; use the smaller feature file on this existing project.

`email-signup-code` is deployed and active with the direct verified-session fix with JWT gateway verification disabled: this is a public registration endpoint, with its own 256-bit challenge tickets, code verification and server-side rate limits. `email-login-code` is deployed and active at version 4 with gateway JWT verification enabled. The verified-session fix does not require any additional SQL. The user has since reached the live verification step. Keep `deno.json` and `deno.lock` with each function. Both functions use the existing Supabase server-only SMTP and HMAC secrets. No server secrets belong in browser code.

Flow:

1. Enter name/account type/email/password for a new account, or email/password for an existing one.
2. Receive a four-digit email and enter it directly in the website's login box.
3. After successful verification, the email becomes confirmed, a Supabase session is created directly from the verified email, the matching session is marked verified, and the profile opens.

Codes expire after five minutes. Five incorrect attempts lock a challenge. A resend invalidates the previous code; a new sign-in request invalidates older tickets. Resend requires a one-minute wait, with five emails per address/hour and an additional network limit. Tickets and codes are stored only as server-keyed hashes. Existing account passwords are checked before the code is sent. Passwords are cleared from modal memory when the code form opens; they are not stored in the OTP tables or local storage. Existing passwords and account types are never overwritten by registration attempts.

Gmail host `smtp.gmail.com`, port 465, encrypted SMTP and the app password are already stored as private Edge Function secrets. The SMTP sender previously passed encrypted authentication and accepted a delivery-test email. Supabase's built-in password recovery/email-change messages still use its separate custom SMTP configuration.

## Inbox placement

The verification emails contain the code, expiry and safety instructions, with no confirmation link, remote images or tracking. Gmail controls spam classification, so the website cannot guarantee Inbox delivery. For the reported sender/recipient, open the earlier message in Spam, select **Not spam**, and add the sender to contacts. Do not share your verification code or password in chat. For production delivery to many users, use a verified custom sending domain with SPF, DKIM and DMARC through a transactional mail service.

## Checks

- `node scripts/verify-signup-code.js`: database permissions, attempts, rate limits, expiry, replay and session ownership.
- `node scripts/verify-email-auth.js`: direct first-use OTP, password failures and email delivery errors.
- `npm run verify`: existing database/access-control regression checks.
- `node scripts/verify-secret-boundary.js`: verify public source/build assets contain no private credentials.
- `npm run smtp:check`: encrypted SMTP authentication check.
- `npm run smtp:test`: one delivery test to the configured sender.

## Google and Facebook

1. Open [Tutormela Authentication providers](https://supabase.com/dashboard/project/zpjdlkrtscxyucqudbpd/auth/providers).
2. Create a Google web OAuth client in your Google Cloud project. Register this authorized redirect URI:

   `https://zpjdlkrtscxyucqudbpd.supabase.co/auth/v1/callback`

   Add the Google client ID and client secret to the Google provider in Supabase, enable it and save. Use a web application client. Add your localhost and eventual production origins as appropriate. See [Google setup](https://supabase.com/docs/guides/auth/social-login/auth-google).
3. Create/configure your Meta application with Facebook Login and email permissions. Use the same callback URI in Valid OAuth Redirect URIs. Put the Facebook app ID and secret into the Facebook provider in Supabase and enable it. Development-mode Facebook apps permit only app members/testers until the app is made available to the public. See [Facebook setup](https://supabase.com/docs/guides/auth/social-login/auth-facebook).
4. Under Supabase Authentication → URL Configuration, set Site URL and allow `http://127.0.0.1:5173/**`, `http://localhost:5173/**` and your production HTTPS origin. The app returns to `/#/dashboard` and opens the user's profile. New social accounts choose student/guardian or tutor once; client signup cannot create an administrator.

Do not put provider client secrets into `.env.local`, a `VITE_` variable, repository files or this chat. Store them only in the Supabase provider configuration. The website shows logo-only buttons with accessible labels. Until a provider is enabled, its button reports that it is unavailable rather than sending users to a broken provider flow.

