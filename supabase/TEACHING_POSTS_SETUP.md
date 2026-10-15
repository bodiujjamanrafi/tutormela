# Activate full teaching posts and PDFs

The website UI and database update are prepared. The Supabase execution was cancelled, and a read-only check confirmed that the full-post function and PDF metadata table are not yet installed.

For this existing Tutormela project, run **`supabase/teaching-posts-and-documents.sql`** in the Supabase SQL Editor, then refresh Tutormela. Existing posts are retained. The previously applied independent identity storage is required and is already present in the live project. A fresh installation can run the complete `schema.sql`, which now includes these features.

The update provides:

- Full teaching posts with independent details; later posts do not replace earlier posts.
- Private drafts in Posts; publishing a draft retains its ID. Drafts do not consume publishing slots. The two-post free allowance is enforced in the database, including legacy publishing endpoints. If the optional billing schema is installed, its active paid allowance is used.
- My profile totals and each post's reactions, taken from stored events.
- A private `tm-tutor-documents` Storage bucket, PDF-only uploads up to 5 MB, and document metadata in `tm_tutor_documents`. Tutors may keep up to 10 documents. A document is public only after its owner chooses Share, and only while their tutor profile is publicly visible. Viewing uses short-lived signed URLs; downloading checks storage permissions. Previously issued signed URLs can remain valid for up to two minutes after a document is made private.
- A safe public identity projection that omits email, phone and login data.
- Private student saved-tutor records, including tutors sharing posts while awaiting approval. Contact requests still require administrator approval.

Verify the update without reading any user data:

```sql
select
  to_regprocedure('public.tm_save_teaching_post(uuid,jsonb,boolean,boolean)') is not null as full_posts_ready,
  to_regprocedure('public.tm_workspace_posts()') is not null as workspace_ready,
  to_regclass('public.tm_tutor_documents') is not null as documents_ready;
```

Local verification: `node scripts/verify-teaching-posts-documents.js` covers independent posts, drafts, limits, edits, reactions, document access and student saves. `node scripts/verify-workspace-ui.js` checks the full-form creation page, identity summary and subscription background markup. The website never stores uploads, posts or saves only in browser memory as a substitute for the database.
