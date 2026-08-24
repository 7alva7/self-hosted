# Notifications that reach the user — design

**Status:** approved for planning
**Date:** 2026-08-24

## Goal

Make sure a user is actually told when something happens to their content, and
stop the system from recording deliveries it never made.

Today email is the only channel, and in a self-hosted instance there is
usually no email at all: the admin account's address is the literal string
`admin`, there is no way to enter a real one, and most operators never
configure SMTP. Notifications for those users vanish silently.

## What the data says, because it moved the scope

The original premise was that production carries users with a Patreon ID and
no email. It does not. Queried against the live `web_ui` database on
2026-08-24:

| Measure | Count |
|---|---|
| Users | 57 749 |
| `email IS NULL` | 0 |
| `email = ''` | 0 |
| `email` without `@` | 0 |
| With a Patreon ID | 4 654 |

The domain distribution is entirely real consumer providers — gmail 46 374,
qq 1 179, Apple private relay 771, icloud, hotmail, yahoo, outlook, proton,
163, mail.ru — with no synthetic cluster. So every production user has a real,
deliverable address, and the Patreon path cannot produce one without an email
(`services/auth/auth.go:263-289` rejects the sign-in outright).

**The undeliverable-address problem is therefore self-hosted only.** The
in-app feed is still worth building for everyone — email gets missed, filtered
and bounced — but its necessity is for self-hosters, who are the population
that has no working channel at all.

## The mistake at the centre of this

`public."user"` declares `email text NOT NULL UNIQUE`. Nothing can be null;
`UNIQUE` means at most one row could ever hold the empty string, and no code
path writes one. So "no email" never looks like an empty string.

Meanwhile roughly ten guards across the codebase are written as
`Email == ""` — in `handlers/event/resource.go:61`, `vault.go:286`,
`services/release_subscription/service.go:325,340`,
`services/release_subscription/poller.go:180`,
`services/notification/notification.go:131`, and others.

The self-hosted admin's address is the sentinel `admin`
(`services/auth/auth.go:530-544`, `services/adminauth/pg_repo.go:16`). It is
not empty, so **not one of those guards has ever fired for the only user in
the system who genuinely has nowhere to receive mail.** The defensive code is
correct in isolation and inert in practice.

The fix is to stop asking whether the field is empty and start asking whether
the address is deliverable.

### A deliverable address

One predicate, used everywhere those guards are today:

```go
// Deliverable reports whether mail sent to this address could actually
// arrive. It is deliberately not "is the string non-empty": the self-hosted
// admin account carries the sentinel "admin", and any future placeholder
// will be equally non-empty and equally undeliverable.
func Deliverable(email string) bool
```

It rejects the empty string, the `admin` sentinel, and anything without an
`@` and a dot-bearing domain. It is a syntactic check, not a proof of
delivery — an address can be well-formed and still bounce. That is fine: its
job is to catch the placeholders the system creates for itself, not to
validate the internet.

Every `Email == ""` site becomes `!Deliverable(u.Email)`. This alone stops the
system from mailing the string `admin`.

## The in-app feed

The channel that works without SMTP, without an address, and without the
operator configuring anything.

### Storage

The existing `notification` table grows the feed's columns. It is not a
second table, and the first draft of this spec was wrong to propose one.

That table already stores `key`, `title`, `template`, `body`, `"to"` and
`created_at`. The rendered title and body are exactly what a feed entry
shows, so a separate table would duplicate them and let the two copies
drift.

More importantly, its deduplication is already the semantics a feed needs,
and better than the one the first draft invented. Keys are built per event
(`services/notification/notification.go:210-263`): `vaulted-<resourceID>`,
`transfer-timeout-<resourceID>` and `expired-<resourceID>` are scoped to a
resource, but **`expiring-<days>` is not** — it is `expiring-7`,
`expiring-3`, `expiring-1`, a digest covering everything due in that many
days. A unique index on `(user_id, key)`, which the first draft proposed,
would therefore allow one seven-day warning per user *ever*: next month's
would collide with last month's and be silently dropped. The existing
`(key, "to", created_at DESC)` index with a 24-hour window has no such
flaw.

The migration:

```sql
ALTER TABLE public.notification
    ADD COLUMN user_id   uuid REFERENCES public."user"(user_id) ON DELETE CASCADE,
    ADD COLUMN read_at   timestamptz,
    ADD COLUMN mailed_at timestamptz,
    ALTER COLUMN "to" DROP NOT NULL;

CREATE INDEX notification_user_created_idx
    ON public.notification (user_id, created_at DESC);
CREATE INDEX notification_key_user_created_idx
    ON public.notification (key, user_id, created_at DESC);
```

Four changes, each doing one thing:

- **`user_id`** is what a feed is keyed on. Existing rows keep it NULL and so
  appear in nobody's feed, which is the intended outcome — the journal is a
  dedupe log, not a history worth showing.
- **`read_at`** is the feed's own state and belongs nowhere else.
- **`mailed_at`** is the fix for the journal lying. Today a row means "a
  letter left"; with a feed it must also cover "shown but never mailed", and
  those are different facts. `mailed_at IS NULL` says plainly that nothing
  reached an SMTP server.
- **`"to"` becomes nullable** so an entry with no destination stores NULL
  rather than a placeholder. Writing the sentinel here would recreate the
  exact confusion this design exists to remove.

Deduplication moves from `(key, "to")` to `(key, user_id)`, keeping the
24-hour window. That works for entries with no address, which the old key
could not express, and it is the same guarantee for everyone who does have
one.

### Ordering, which is not a detail

`Service.Send` carries a comment (`services/notification/notification.go:100-114`)
explaining why it mails first and journals second: a row exists only for a
letter that actually left, so a dedupe hit genuinely means "already sent".
Journalling first would let a failed SMTP attempt leave a row behind, and the
retry — same key, inside the window — would be swallowed as a duplicate of a
letter nobody received.

That reasoning is sound and must not be discarded when the feed arrives. It
is also specifically about the *mail*. The feed has the opposite requirement:
its entry must exist whether or not mail succeeds, because the entry is the
notification and the letter is only one way of carrying it.

So the row is written first with `mailed_at` NULL — the feed entry exists
immediately — and `mailed_at` is stamped afterwards, only when an SMTP server
actually accepted the message. Dedupe for mail then reads "a row with this
key for this user, mailed within 24 hours", which preserves exactly the
property the original comment protects: a retry after a failed send is not
mistaken for a duplicate, because the failed attempt left `mailed_at` NULL.

Update that comment to say this. A comment describing an ordering that no
longer holds is worse than none, and this project has already paid for that
twice.

### Surface

A bell in the navbar carrying an unread count, and a page listing entries.

The navbar already does exactly this shape for the onboarding checklist
(`templates/partials/nav.html:134`, `{{ if .Onboarding }}`), which reads a
field off `services/web.Context`. The unread count follows the same route: a
middleware sets it, `NewContext` reads it, the partial renders it. That
pattern was re-verified recently when the Vault link was gated the same way,
and its zero value must mean "nothing to show" so a caller who forgets to set
it renders nothing rather than a wrong badge.

Opening the page marks the listed entries read. Entries are kept per user
with a cap — the newest 100 — pruned by the existing `notification send` cron
job rather than a new one.

## Entering an email

Only where it can do something, which is narrower than it first appears.

**On production, there is no email field at all.** Email there is not a
contact preference, it is identity: `services/claims/claims.go` builds the
tier lookup key from it, `jobs/payment.go:117` gates the post-donation poll on
it, and `models/user.go:33-96` matches Patreon accounts by it. Letting a user
edit that would silently detach their tier and their Patreon link. Every
production user already has a working address, so the field would be all risk
and no benefit.

**In self-hosted, the field appears only when SMTP is configured.** web-ui
already knows this — `services/common/common.go:53` carries the `SMTP_HOST`
flag. Without SMTP there is nothing an address could achieve, so offering the
input would be the same false promise this design exists to remove. The feed
covers that case instead.

That gating also dissolves what looked like a contradiction: an address must
be verified before we mail it, and verification requires sending mail. The two
never meet, because the field only exists when mail works.

### Verification

Standard, and it protects third parties rather than the account holder: an
unverified address means someone could type a stranger's mailbox and have this
instance mail them.

Entering an address stores it as pending and sends a single-use token valid
for 24 hours. Nothing is sent to a pending address except that one message.
Confirming promotes it to the account's notification address. The identity
email — where one exists — is never touched.

## The three bugs found while investigating

Each is independent of the feature and each is a silent failure.

1. **The mail journal records sends that never left the box.**
   `services/notification/mailer.go:29-33` returns `nil` when `SMTP_HOST` is
   empty, logging a warning. `Service.Send` cannot distinguish that from
   delivery and writes a `notification` row saying the message was sent. Worse
   than cosmetic: that table is the 24-hour dedupe, so if SMTP is configured
   within the window, the real send is suppressed because the journal believes
   the user was already told. The mailer must report "not configured" as a
   distinct outcome, and the journal must record only what was actually
   handed to an SMTP server.

2. **`subscription-poll` runs regardless of SMTP.** The guard in
   `s6-overlay/scripts/run-cron-job` is keyed on the job name
   `notification-send`, so the hourly poller runs unconditionally — doing real
   source searches for an account that cannot be mailed, and attempting sends
   that go nowhere. With the feed in place the poller becomes useful again for
   SMTP-less instances, so the fix is not to gate it too: it is to make its
   output land in the feed, and to stop it burning searches for accounts with
   neither a deliverable address nor a feed reader. State the rule explicitly
   in the crontab comment, which currently implies both jobs are gated.

3. **A dormant nil dereference.** `services/auth/auth.go` `createUser` falls
   through to a bare `return` when a third-party sign-in yields an empty
   email, putting a typed-nil `*models.User` into the request context;
   `makeUserFromContext` type-asserts it successfully and dereferences it.
   Unreachable today — Google always returns an address and Patreon rejects
   the sign-in — but it is the one path in the auth stack with no defence.

## Testing

The self-hosted smoke suite is where this becomes observable end to end. It
already has a container with no SMTP and an admin account whose address is the
sentinel, which is precisely the configuration under discussion.

- A notification-producing event yields a feed entry for the admin account,
  and the navbar reports it unread.
- Reading the page clears the count.
- With no SMTP configured, no row is written to the `notification` mail
  journal — the assertion that would have caught bug 1.
- The profile offers no email field when SMTP is unset, and offers one when it
  is set.
- A pending address receives exactly one message and nothing else until
  confirmed.

Each guard added here needs a negative control: remove it and watch the test
go red. The predicate in particular — a `Deliverable` that returns true for
everything would pass every happy-path test in this list.

## Out of scope

- Web push, and any channel other than the feed and email.
- Changing the identity email on production.
- Retrofitting notifications onto events that do not currently produce one.
- Migrating existing `notification` journal rows into the feed. The journal is
  a dedupe log, not a history worth showing; the feed starts empty.
