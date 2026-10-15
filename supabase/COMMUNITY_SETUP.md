# Tutor profiles, likes and feed persistence

The website opens on Find a tutor. Direct profile links, recovery links and explicitly selected news-feed links still work. After sign-in, students/guardians return to search; tutors open their own teaching workspace. Student accounts keep private authentication, saves and contact requests, without a public profile or profile editor.

All website profiles, posts, likes and engagement counters use Supabase. Browser-only demo sign-in and demo posts have been removed from the running website. Old browser-only demo data is not deleted, but it is not a shared database record and cannot appear on other devices. A real verified account is required to publish it again.

## Database step pending

The live execution of the new policy update was cancelled. Run **community-social.sql** in the existing project's SQL Editor. This additive file is tested and changes no stored post bodies or account records. Existing tables already store likes and unique profile/post visits. The new file permits any verified account to like a post (including a tutor's own post), prevents owner withdrawal of shared posts/profiles, and adds administrator moderation. No server key or email password is included in it.

Apply only this feature file on the existing installation. The complete schema.sql also includes it for fresh installations.

## Behaviour

- Every visitor can read the shared tutor feed. A verified student, guardian, tutor or admin can like/unlike a post; the database keeps at most one like per account/post.
- Tutors see total unique profile visitors and total post likes in My profile. The Posts tab shows each post's view and like totals. Counts refresh on window focus, every 30 seconds while visible, and manually from Posts.
- Signed-in visits are deduplicated by account; anonymous visits use a random browser token. Owner visits are excluded. Raw visitor and reactor identifiers remain private.
- Published posts have no expiry. Cross-account visibility does not depend on the viewer's email. Older posts remain reachable with Load more.
- The admin Posts tab removes/restores posts without deleting their stored content. Profile rejection can still remove that tutor from public view. An owner cannot undo admin removal by editing their profile.
- Private, unpublished teaching drafts remain private.

Checks: verify-navigation.js, verify-feed.js (48 checks), verify-supabase.js (65 checks), and the existing email/OTP tests. Build and private-secret boundary checks also pass.
