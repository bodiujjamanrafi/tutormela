# Contact email and lasting saved tutors

The profile-link fix is implemented. It carries the exact tutor ID and selected post ID, checks both on the server, and never displays another profile while a request is loading. The student can contact the owner of that selected tutor record. Post snapshots can have different names/details from the tutor's later posts, so the selected snapshot is retained in the link.

The new `contact-request-email` Edge Function is deployed. Existing SMTP authentication was verified without sending unsolicited test messages. The Supabase database update was cancelled after an initial expired approval request; a read-only check confirmed that the exact-page function and outbox table were not yet installed at that point. **Run `profile-contact-and-saves.sql` in the Supabase SQL Editor to activate the backend.** The existing teaching-post/identity update is already installed in the live project.

The SQL can be rerun. It does not delete existing requests, emails or saved entries. Pending older requests are added to the outbox without sending email automatically; students can use Retry email. Public pending tutor profiles can receive requests. Rejected, private, removed or unavailable profiles cannot receive new requests.

Email behaviour:

- The student and tutor addresses are resolved from Supabase Auth using the authenticated student ID and the selected tutor's database ownership. Browser-supplied sender or recipient addresses are ignored.
- From is the configured, authenticated Tutormela SMTP sender. Reply-To is the student's registered email. Gmail credentials cannot send authenticated mail as arbitrary student addresses.
- Request text, verified reply address, recipient, SMTP sender, subject/body, attempts, delivery state, SMTP message ID and timestamps are stored in a private outbox. Only server-side code can read that outbox; students and tutors see only their own request and its delivery state.
- An SMTP acceptance is recorded as `sent`; it does not prove inbox placement. Failures retain the request. Safe failures may be retried up to three times with a cooldown. Ambiguous submissions are marked `unknown` and are not automatically resent, preventing duplicate messages.
- The existing server-only SMTP secrets are reused. No password, key or token is sent to the browser. The Edge Function validates the user token and verified session itself; gateway JWT validation is disabled for compatibility with the configured publishable client.

Saved tutors:

- A private snapshot is attached to the saved entry, including the selected post context. Repeated saves do not create duplicates.
- There is no expiry. Status changes and tutor/profile deletion do not remove the student's saved entry. An unavailable tutor remains shown as unavailable and can be removed by the student.
- The student-account foreign key remains; deleting the student's own account can delete their private data. Other users cannot read or remove that student's shortlist.

Verify activation:

```sql
select
 to_regprocedure('public.tm_tutor_page(uuid,uuid)') is not null as exact_pages_ready,
 to_regprocedure('public.tm_my_saved_tutors()') is not null as saved_tutors_ready,
 to_regclass('tm_private.tm_contact_email_outbox') is not null as email_outbox_ready;
```

Local regression checks: `node scripts/verify-profile-contact.js` and `node scripts/verify-workspace-ui.js`.
