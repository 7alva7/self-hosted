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

A new table, not an extension of `notification`. The existing one is a
delivery journal keyed `(key, "to", created_at)` where `to` is an email
address; it exists to suppress duplicate *mails* within 24 hours. A feed is
keyed on the user and carries read state. Overloading one table with both
would tangle two lifetimes — a mail is deduped and forgotten, a feed entry is
read and kept.

```sql
CREATE TABLE public.user_notification (
    user_notification_id uuid DEFAULT uuid_generate_v4() NOT NULL,
    user_id    uuid NOT NULL REFERENCES public."user"(user_id) ON DELETE CASCADE,
    key        text NOT NULL,
    title      text NOT NULL,
    body       text NOT NULL,
    url        text,
    read_at    timestamptz,
    created_at timestamptz DEFAULT now() NOT NULL,
    CONSTRAINT user_notification_pk PRIMARY KEY (user_notification_id)
);

CREATE INDEX user_notification_user_created_idx
    ON public.user_notification (user_id, created_at DESC);
CREATE UNIQUE INDEX user_notification_dedupe_idx
    ON public.user_notification (user_id, key);
```

`ON DELETE CASCADE` matters: account deletion already exists
(`POST /profile/delete`) and must not leave orphans.

The unique index on `(user_id, key)` gives the feed its own deduplication.
The mail journal's 24-hour window is about not pestering an inbox; a feed
entry should exist once per distinct event and be updated rather than
duplicated.

### Write path

The feed is the record; email is a delivery channel for it.

`services/notification.Service.Send` currently renders a template, calls the
mailer, and journals. It gains a step: **write the feed row first, then
attempt mail if the address is deliverable.** One event produces one feed
entry whether or not mail goes anywhere.

This ordering is the point. Writing the feed only on mail failure, or only
when the address is undeliverable, would give users with working email no
feed at all — and they are the ones who most often say "I never got the
mail".

All seven existing notifications feed it: `SendVaulted`, `SendExpiring`,
`SendTransferTimeout`, `SendExpired`, `SendSubscriptionOn`,
`SendSubscriptionOff`, `SendSubscriptionUpdate`.

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
