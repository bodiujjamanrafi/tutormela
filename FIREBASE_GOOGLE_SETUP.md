# Finish Google sign-in

The Firebase Google button is connected to the existing Supabase account system. Firebase's Google provider was verified as enabled. Supabase's Google provider was still disabled at the final configuration check. You chose to configure Supabase yourself; its configuration was not changed by the agent because the existing management token lacked permission.

## Supabase settings

1. Open Tutormela → Authentication → Sign In / Providers → Google and enable Google.
2. Use the **same Google Web OAuth client** used by this Firebase project:

   `277069230265-v7s7eqni1np411rvtb9hs1gbjojdta4e.apps.googleusercontent.com`

3. If the dashboard requests a client secret, obtain this client's secret from the Google Auth Platform / Google Cloud Credentials console for the Tutormela project, and paste it directly into Supabase's Google provider settings. Keep it out of chat, browser code and all `VITE_` variables. Do not use the Firebase API key or app ID as the OAuth secret. The Firebase Web configuration does not contain that secret.
4. If configuring the OAuth redirect in Google Cloud, use Supabase's callback URL: `https://zpjdlkrtscxyucqudbpd.supabase.co/auth/v1/callback`. Keep nonce checks enabled and require an email address.
5. Save. Run `node scripts/check-google-configuration.js` to check provider readiness without exposing credentials.

## Local and production addresses

Use **http://localhost:5173** for local testing. The development launcher now binds to localhost. Firebase already authorizes localhost and imrafi.com. Restart the development server after changing environment variables if it has not refreshed automatically. If you prefer the numeric address, explicitly add `127.0.0.1` in Firebase Authentication → Settings → Authorized domains first.

Production deployments must receive the public `VITE_FIREBASE_*` values from `.env.local` through the deployment environment and be rebuilt. The actual production hostname must also be in Firebase's authorized-domain list. Google OAuth testing mode may restrict login to the test users configured in Google Auth Platform.

## What is implemented

- Firebase SDK `13.0.0`, imported only for authentication. Analytics is not enabled.
- Google account selection and a random nonce hashed into the Google OAuth request. The original nonce and Google's ID token are passed to Supabase `signInWithIdToken` for signature, issuer, audience and nonce validation. A Firebase user token is never substituted for a Google ID token.
- A normal Supabase session and UUID account, preserving existing database permissions and email/password login. Existing accounts retain their roles; new accounts use the student/tutor choice from the sign-in form through the permission-checked onboarding action.
- Firebase authentication uses memory persistence and is cleared after the exchange. Supabase manages the website session. No token is logged or placed in a URL.
- Clear errors for a cancelled/blocked popup, an unauthorized domain and a disabled provider.

## Security and verification

Firebase's web API key and application IDs are public configuration by design, not admin credentials. They are necessary in the browser and cannot be made secret by hiding them in environment variables. Firebase's public API restrictions and authorized domains still apply. OAuth client secrets, service account private keys and Supabase management/service credentials belong only on the server.

`node scripts/verify-google-auth.js` tests nonce binding, token exchange and failure handling. The production build and secret-boundary checks were also run. A successful real Google account sign-in still needs to be confirmed after enabling Supabase Google: open localhost, choose Tutor or Student, click Google, select your account, and confirm the correct dashboard opens. Never share your Google password or tokens with the agent.

Official references: https://firebase.google.com/docs/auth/web/google-signin , https://firebase.google.com/docs/projects/api-keys , https://supabase.com/docs/guides/auth/social-login/auth-google .

## Login handoff

A verified website account now closes the login dialog and navigates immediately: tutors/admins to their dashboard, students/guardians to Find a tutor. Loading private profiles and contact requests happens after navigation; a failure there cannot trap a signed-in user on the login screen. Provider readiness is checked before opening the Google popup, with an error next to the Google button if Supabase Google is still disabled. `node scripts/verify-sign-in-handoff.js` covers these cases.
