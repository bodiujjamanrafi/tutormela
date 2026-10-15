# Unified tutor cards and posting plans

## Database activation

The live database update was cancelled. Run **browse-and-plans.sql** once in the existing Tutormela project's SQL Editor. This is the combined update, including the previously pending social permissions. It preserves existing post content, creates identities for already public tutor profiles, and adds the filtered card feed, plan catalogue, private interest records, subscription state and posting-limit trigger.

The website keeps displaying existing Supabase profiles/posts while the new SQL is pending. Publishing new posts fails closed when the quota service is unavailable; a browser-only allowance never grants posting permission. The three plan designs remain reviewable in the tutor workspace.

For fresh installations, schema.sql includes the same feature. Do not re-run the entire base schema on an existing project just to add these features.

## Product behaviour

- Find a tutor is the main filtered post feed. Old #/feed links resolve to the same page. The header has Find a tutor and Saved tutors; the top-right tutor profile control remains.
- Teaching identities and status updates use the same readable tutor-card design, with likes inside each post. Tutors see their own post views, profile views and likes below their posts; private view counts are not exposed on other tutors' cards.
- Free allowance: two posts in total, including the shared teaching profile. Identity edits and status edits do not use extra slots. Administrator removal never refunds a used slot. Already existing posts are retained even if an account already exceeds the new free allowance.
- Monthly plans: Starter **৳300 / 6 posts**, Growth **৳500 / 15 posts**, Professional **৳800 / 30 posts**. All retain editable profiles, private engagement tracking and already published posts after expiry. Unused slots do not roll over. Existing daily spam limits still apply.
- Subscription allowance is calculated from a verified active billing period in the database. Only a future trusted payment backend may write subscription activation records. Browser clients cannot choose an active plan, alter prices or fabricate payment status.
- Payments are deliberately disconnected, as requested. Register interest records the verified tutor's preferred plan, without charging or activating anything. A payment provider/webhook must be connected before purchases can launch.

## Validation

- verify-posting-plans.js: 32 checks covering pricing, free and paid quotas, expiry, edits, moderation, filtered cards, pagination, engagement privacy and subscription forgery.
- verify-feed.js: 48 feed, privacy and moderation checks.
- verify-supabase.js: 65 existing database and permission checks.
- verify-navigation.js plus server render checks confirm the header links and top-right profile control.
- Production build, lint and secret-boundary checks pass (two existing React effect warnings and the existing bundle-size advisory remain).

## Dedicated page and status workspace

The subscription UI now lives at `#/subscriptions`, linked by the header crown and the icon-only tutor workspace shortcut. It uses the user-supplied Pinterest background stored locally in `src/assets/subscription`, with readable tinted glass cards. No modal is used for plans.

My profile contains teaching identity details. Posts contains only status updates (`kind=update`), with a New status composer, editing and private per-post insights. Successful publishing stays in Posts and reloads the stored status list. Identity records are preserved in the database and the public card feed; they are simply omitted from the owner's status list.

A live read-only check still reports that the earlier posting-quota and plan-interest SQL is not active. Apply browse-and-plans.sql to enable those operations. Payment collection remains disconnected as requested.
