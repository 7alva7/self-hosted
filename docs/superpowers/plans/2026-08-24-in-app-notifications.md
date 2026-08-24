# Notifications that reach the user — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every user a notification channel that works without SMTP, and stop the system recording deliveries it never made.

**Architecture:** The existing `notification` table becomes the feed as well as the mail journal, gaining `user_id`, `read_at` and `mailed_at`. A `Deliverable` predicate replaces ten `Email == ""` guards that never fire for the one account that actually has no address. A navbar bell and a page render the feed. An email field appears only where it can work — self-hosted, with SMTP configured — and is verified before use.

**Tech Stack:** Go, Gin, go-pg, server-rendered templates with Preact islands, PostgreSQL, bash smoke suite.

**Spec:** `docs/superpowers/specs/2026-08-24-in-app-notifications-design.md`

## Global Constraints

- Most work is in `/Users/vintikzzzz/Projects/webtor/web-ui`. Tasks 7 and 9–10 are in `/Users/vintikzzzz/Projects/webtor/self-hosted`. Each task names its repository.
- **Run the web-ui test suite with `make test`, never bare `go test ./...`** — the latter panics on a pre-existing protobuf name conflict present on `main` too; the Makefile passes the ldflag that works around it.
- Migrations are sequential SQL pairs in `web-ui/migrations/`; the last is `69_release_subscription_preferences`. Every `N_name.up.sql` needs its `.down.sql`.
- Email on production is **identity**, not a contact preference: `services/claims/claims.go` keys the tier lookup on it and `models/user.go:33-96` matches Patreon accounts by it. No task may make it editable there.
- A value read from a gin context must default to the safe state when unset. For the unread count that is zero — a caller who forgets to set it renders no badge rather than a wrong one.
- `gin`'s `r.Use()` applies only to routes registered after it.
- Anything added to `services/web.Context` follows the existing `Onboarding`/`Vault` pattern: a middleware sets it, `NewContext` reads it.

---

## File Structure

**web-ui**

| File | Responsibility |
|---|---|
| `services/notification/deliverable.go` (new) | the `Deliverable` predicate and its tests |
| `migrations/70_notification_feed.{up,down}.sql` (new) | `user_id`, `read_at`, `mailed_at`, nullable `to`, indexes |
| `migrations/71_user_pending_email.{up,down}.sql` (new) | pending address and verification token |
| `models/notification.go` | new columns, feed queries |
| `services/notification/store.go` | store interface and pg implementation |
| `services/notification/mailer.go` | `ErrNotConfigured` |
| `services/notification/notification.go` | write-then-mail ordering, `UserID` in `SendOptions` |
| `handlers/event/resource.go`, `vault.go`, `services/release_subscription/{service,poller}.go` | guards switch to `Deliverable` |
| `services/web/context.go`, `serve.go` | `UnreadNotifications` on `Context` |
| `handlers/notifications/handler.go` (new) | the feed page and mark-read |
| `templates/partials/nav.html`, `templates/views/notifications/*` | bell and list |
| `handlers/profile/handler.go`, `templates/partials/profile/email.html` (new) | email entry and verification |
| `services/auth/auth.go` | the dormant nil dereference |

**self-hosted**

| File | Responsibility |
|---|---|
| `s6-overlay/scripts/run-cron-job`, `etc/webtor/cron/crontab` | subscription-poll gating and its comment |
| `tests/scenarios/95-notifications.sh` (new) | end-to-end feed coverage |
| `README.md`, `CLAUDE.md` | SMTP variables, which are undocumented today |

---

## Task 1: The deliverability predicate

**Repository:** `web-ui`

**Files:**
- Create: `services/notification/deliverable.go`, `services/notification/deliverable_test.go`

**Interfaces:**
- Produces: `notification.Deliverable(email string) bool`, used by Task 3 and every guard site.

Ten guards ask `Email == ""`. The column is `NOT NULL UNIQUE`, so no email never looks like an empty string — and the self-hosted admin's address is the sentinel `admin`, which is not empty. Those guards have never fired for the only account that genuinely has nowhere to receive mail.

- [ ] **Step 1: Write the failing test**

```go
package notification

import "testing"

func TestDeliverable(t *testing.T) {
	cases := []struct {
		name  string
		email string
		want  bool
	}{
		{"ordinary address", "user@example.com", true},
		{"subdomain", "user@mail.example.co.uk", true},
		{"plus addressing", "user+tag@example.com", true},
		{"empty", "", false},
		// The one that matters: the self-hosted admin account carries this
		// literal string, and every Email == "" guard in the codebase lets
		// it through today.
		{"admin sentinel", "admin", false},
		{"no at sign", "userexample.com", false},
		{"no domain dot", "user@localhost", false},
		{"nothing before the at", "@example.com", false},
		{"nothing after the at", "user@", false},
		{"whitespace only", "   ", false},
		{"leading and trailing space is trimmed", " user@example.com ", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := Deliverable(tc.email); got != tc.want {
				t.Fatalf("Deliverable(%q) = %v, want %v", tc.email, got, tc.want)
			}
		})
	}
}
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd /Users/vintikzzzz/Projects/webtor/web-ui
go test ./services/notification/ -run TestDeliverable -v
```
Expected: FAIL — `Deliverable` is undefined.

- [ ] **Step 3: Implement it**

```go
package notification

import "strings"

// Deliverable reports whether mail sent to this address could plausibly
// arrive. It is deliberately not "the field is non-empty": public."user"
// declares email NOT NULL UNIQUE, so an absent address never looks like an
// empty string, and the self-hosted admin account carries the literal
// sentinel "admin" (services/adminauth/pg_repo.go). Every guard written as
// Email == "" passes that sentinel straight through and mails it.
//
// This is a syntactic check, not proof of delivery: a well-formed address
// can still bounce. Its job is to catch the placeholders this system
// creates for itself, not to validate the internet.
func Deliverable(email string) bool {
	e := strings.TrimSpace(email)
	at := strings.LastIndex(e, "@")
	if at <= 0 || at == len(e)-1 {
		return false
	}
	domain := e[at+1:]
	dot := strings.Index(domain, ".")
	return dot > 0 && dot < len(domain)-1
}
```

- [ ] **Step 4: Run it and watch it pass**

```bash
go test ./services/notification/ -run TestDeliverable -v
```
Expected: PASS, all subtests.

- [ ] **Step 5: Prove the admin case is load-bearing**

Change the `admin sentinel` expectation from `false` to `true` and re-run. It must fail. That subtest is the whole reason this function exists; if it passes either way, the implementation is not doing its job. Revert.

- [ ] **Step 6: Commit**

```bash
git add services/notification/deliverable.go services/notification/deliverable_test.go
git commit -m "feat(notification): add a deliverability predicate"
```

---

## Task 2: Replace the guards

**Repository:** `web-ui`

**Files:**
- Modify: `handlers/event/resource.go:61`, `vault.go:286`, `services/release_subscription/service.go:325,340`, `services/release_subscription/poller.go:180`, `services/notification/notification.go:131`

**Interfaces:**
- Consumes: `notification.Deliverable`.

- [ ] **Step 1: Find every site**

```bash
cd /Users/vintikzzzz/Projects/webtor/web-ui
grep -rn 'Email == ""' --include="*.go" . | grep -v _test
```
Record the full list in your report — the line numbers above came from an earlier survey and may have drifted.

- [ ] **Step 2: Replace each with the predicate**

Each `u.Email == ""` becomes `!notification.Deliverable(u.Email)`, keeping the surrounding logic identical. Where the guard reads `p.User == nil || p.User.Email == ""`, keep the nil check first.

Watch for import cycles: if a package cannot import `services/notification`, say so in your report rather than duplicating the function.

- [ ] **Step 3: Build and test**

```bash
make test
```
Expected: 0 failures.

- [ ] **Step 4: Prove the change reaches the poller**

`services/release_subscription/poller.go`'s guard skips the entire poll, not just the mail. Write a test that a subscription whose user's email is `admin` is skipped:

```go
func TestPollOneSkipsUndeliverableAddress(t *testing.T) {
	// Follow the table-driven style already used in poller_test.go; assert
	// that pollOne returns without performing a source search when the
	// subscription's user carries the admin sentinel.
}
```

Fill it in against the existing test helpers in that package. Then remove the `Deliverable` call from the guard and confirm the test fails. Report both directions.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "fix: recognise undeliverable addresses instead of empty ones"
```

---

## Task 3: The feed's columns

**Repository:** `web-ui`

**Files:**
- Create: `migrations/70_notification_feed.up.sql`, `migrations/70_notification_feed.down.sql`
- Modify: `models/notification.go`

**Interfaces:**
- Produces: `models.Notification` with `UserID *uuid.UUID`, `ReadAt *time.Time`, `MailedAt *time.Time`, `To` nullable.

- [ ] **Step 1: Write the migration**

`migrations/70_notification_feed.up.sql`:

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

`migrations/70_notification_feed.down.sql`:

```sql
DROP INDEX IF EXISTS notification_key_user_created_idx;
DROP INDEX IF EXISTS notification_user_created_idx;

DELETE FROM public.notification WHERE "to" IS NULL;

ALTER TABLE public.notification
    ALTER COLUMN "to" SET NOT NULL,
    DROP COLUMN mailed_at,
    DROP COLUMN read_at,
    DROP COLUMN user_id;
```

The `DELETE` in the down migration is deliberate and must stay: rows written for a user with no address have `to IS NULL`, and restoring `NOT NULL` would fail with them present. Losing them on a rollback is correct — they are feed entries, and the schema being rolled back has no feed.

- [ ] **Step 2: Update the model**

In `models/notification.go`, the struct gains three fields and `To` loses `notnull`:

```go
	To        *string    `pg:"to"`
	UserID    *uuid.UUID `pg:"user_id,type:uuid"`
	ReadAt    *time.Time `pg:"read_at"`
	MailedAt  *time.Time `pg:"mailed_at"`
```

Pointers throughout: each of these has a meaningful absent state — no address, unread, never mailed — and a zero `time.Time` would read as "January year 1" rather than "never".

Update `CreateNotification`'s callers for the `To` type change; `go build ./...` will find them.

- [ ] **Step 3: Apply and verify against a real database**

```bash
docker compose -f /Users/vintikzzzz/Projects/webtor/self-hosted/tests/docker-compose.yml -p mig-check up -d webtor
sleep 40
docker compose -f /Users/vintikzzzz/Projects/webtor/self-hosted/tests/docker-compose.yml -p mig-check exec -T webtor \
  su -s /bin/sh -c "psql -U postgres -d app -c '\\d public.notification'" postgres
```

You will need an image built from your branch to see migration 70 applied — build it with the `web-ui` stage repointed at a locally built `web-ui:cron` from your working tree, per the build caveat below. Expected: `user_id`, `read_at`, `mailed_at` present, `to` nullable.

Tear the project down when finished.

- [ ] **Step 4: Commit**

```bash
git add migrations/70_notification_feed.up.sql migrations/70_notification_feed.down.sql models/notification.go
git commit -m "feat(notification): give the journal a user, read state and a mailed stamp"
```

---

## Task 4: Write the entry first, mail second

**Repository:** `web-ui`

**Files:**
- Modify: `services/notification/mailer.go`, `services/notification/store.go`, `services/notification/notification.go`, `models/notification.go`

**Interfaces:**
- Consumes: the columns from Task 3.
- Produces: `SendOptions.UserID uuid.UUID`; `notification.ErrNotConfigured`; store methods `GetLastMailedByKeyAndUser`, `Create`, `MarkMailed`.

This is the task that stops the journal lying. Today `smtpMailer.Send` returns `nil` when `SMTP_HOST` is empty, so `Service.Send` cannot tell "delivered" from "there is no mail server", and writes a row saying the message was sent. Because that table is the 24-hour dedupe, configuring SMTP within the window then *suppresses* the real send — the journal believes the user was already told.

- [ ] **Step 1: Give the mailer a distinct outcome**

In `services/notification/mailer.go`:

```go
// ErrNotConfigured means no SMTP server is configured, so nothing was even
// attempted. It is not a delivery failure and callers must not treat it as
// one -- in particular, a notification recorded as mailed on the strength of
// this would suppress the real send once SMTP arrives.
var ErrNotConfigured = errors.New("smtp is not configured")
```

and `smtpMailer.Send` returns it instead of `nil` when `m.host == ""`.

- [ ] **Step 2: Extend the store**

In `services/notification/store.go`:

```go
type notificationStore interface {
	GetLastMailedByKeyAndUser(ctx context.Context, key string, userID uuid.UUID) (*models.Notification, error)
	Create(ctx context.Context, n *models.Notification) error
	MarkMailed(ctx context.Context, id uuid.UUID) error
}
```

`GetLastMailedByKeyAndUser` returns the newest row for that key and user **with `mailed_at IS NOT NULL`**. That qualifier is what preserves the property the existing ordering comment protects: a send that failed leaves `mailed_at` NULL, so the retry is not mistaken for a duplicate.

Implement the three against `pgNotificationStore`, adding the corresponding functions to `models/notification.go`.

- [ ] **Step 3: Rewrite `Service.Send`**

```go
func (s *Service) Send(opts SendOptions) error {
	ctx := context.Background()

	// Dedupe on what was actually mailed. A row with mailed_at NULL is a
	// feed entry whose letter never left -- either there is no SMTP server
	// or the send failed -- and must not suppress a later attempt.
	last, err := s.store.GetLastMailedByKeyAndUser(ctx, opts.Key, opts.UserID)
	if err != nil {
		return errors.Wrap(err, "failed to check for duplicate notification")
	}
	mailedRecently := last != nil && time.Since(*last.MailedAt) < 24*time.Hour

	body, err := s.render(opts.Template, opts.Lang, opts.Data)
	if err != nil {
		return errors.Wrap(err, "failed to render notification template")
	}

	// The entry is written before anything is sent, because the entry IS the
	// notification -- the letter is one way of carrying it, and a user with
	// no deliverable address must still be told. This inverts the previous
	// ordering, which existed so that a journal row implied a letter had
	// left. That property is preserved by mailed_at instead: it is stamped
	// only after an SMTP server accepts the message, so a failed send still
	// leaves nothing that looks like a delivery.
	n := &models.Notification{
		Key:      opts.Key,
		Title:    opts.Title,
		Template: opts.Template,
		Body:     body,
		UserID:   &opts.UserID,
	}
	if Deliverable(opts.To) {
		to := opts.To
		n.To = &to
	}
	if err := s.store.Create(ctx, n); err != nil {
		return errors.Wrap(err, "failed to save notification to db")
	}

	if n.To == nil || mailedRecently {
		return nil
	}

	if err := s.mail.Send(*n.To, opts.Title, body); err != nil {
		if errors.Is(err, ErrNotConfigured) {
			// Expected on an instance with no mail server. The feed entry
			// above is the delivery; say so once at debug volume rather than
			// reporting a failure that is not one.
			return nil
		}
		return errors.Wrap(err, "failed to send email")
	}
	return s.store.MarkMailed(ctx, n.NotificationID)
}
```

`SendOptions` gains `UserID uuid.UUID`. Every caller in `notification.go` and `subscription.go` must pass it; the compiler will find them, and each already has the user in hand.

- [ ] **Step 4: Test the two properties that matter**

In `services/notification/notification_test.go`, using the existing fakes:

```go
func TestSendRecordsEntryWithoutMailWhenSMTPMissing(t *testing.T) {
	// mailer returns ErrNotConfigured; assert Send returns nil, exactly one
	// row was created, and its MailedAt is nil.
}

func TestSendDoesNotSuppressRetryAfterFailedSend(t *testing.T) {
	// store returns nil from GetLastMailedByKeyAndUser (nothing mailed);
	// assert Send attempts the mail even though an unmailed row for the same
	// key exists.
}
```

Fill both in against the fakes already in that file.

- [ ] **Step 5: Prove each can fail**

Make `smtpMailer.Send` return `nil` again instead of `ErrNotConfigured` and confirm the first test fails. Make `GetLastMailedByKeyAndUser` ignore the `mailed_at IS NOT NULL` qualifier and confirm the second fails. Revert both, paste both directions.

- [ ] **Step 6: Commit**

```bash
make test
git add -A
git commit -m "fix(notification): record the entry before sending, and only claim delivery that happened"
```

---

## Task 5: The unread count on the request context

**Repository:** `web-ui`

**Files:**
- Modify: `services/web/context.go`, `services/web/context_test.go`, `serve.go`
- Modify: `services/notification/store.go`, `models/notification.go`

**Interfaces:**
- Produces: `Context.UnreadNotifications int`; store methods `CountUnread`, `ListByUser`, `MarkAllRead`.

- [ ] **Step 1: Add the store methods**

```go
	CountUnread(ctx context.Context, userID uuid.UUID) (int, error)
	ListByUser(ctx context.Context, userID uuid.UUID, limit int) ([]models.Notification, error)
	MarkAllRead(ctx context.Context, userID uuid.UUID) error
```

`ListByUser` orders by `created_at DESC` and takes a limit; the page passes 100.

- [ ] **Step 2: Write the failing context test**

Follow `TestNewContextCarriesOpenInstance` in `services/web/context_test.go` exactly — it drives `NewContext` through a real `gin.Context`, which is the only shape that catches a dropped wiring line.

```go
func TestNewContextCarriesUnreadNotifications(t *testing.T) {
	for _, tc := range []struct {
		name string
		set  bool
		val  int
		want int
	}{
		{"set to three", true, 3, 3},
		{"set to zero", true, 0, 0},
		// Unset must mean zero: a caller who forgets renders no badge
		// rather than a wrong one.
		{"never set", false, 0, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c, _ := gin.CreateTestContext(httptest.NewRecorder())
			c.Request = httptest.NewRequest("GET", "/", nil)
			if tc.set {
				SetUnreadNotifications(c, tc.val)
			}
			if got := NewContext(c).UnreadNotifications; got != tc.want {
				t.Fatalf("UnreadNotifications = %d, want %d", got, tc.want)
			}
		})
	}
}
```

- [ ] **Step 3: Run it and watch it fail**

```bash
go test ./services/web/ -run TestNewContextCarriesUnreadNotifications -v
```
Expected: FAIL — `SetUnreadNotifications` undefined.

- [ ] **Step 4: Implement the plumbing**

In `services/web/context.go`, beside `vaultEnabledContextKey`, add `unreadNotificationsContextKey`, a `SetUnreadNotifications(c, n)` setter, an `unreadNotifications(c) int` reader defaulting to 0, an `UnreadNotifications int` field on `Context`, and `UnreadNotifications: unreadNotifications(c)` in the returned literal.

- [ ] **Step 5: Register the middleware**

In `serve.go`, beside the vault middleware and **before the first route is registered** — `r.Use` applies only to routes added after it:

```go
	// Counted per request so the badge is never stale. Anonymous users and
	// store errors both fall through to zero rather than blocking the page:
	// a missing badge is a smaller failure than a page that will not render.
	r.Use(func(c *gin.Context) {
		if u := auth.GetUserFromContext(c); u != nil && u.HasAuth() {
			if n, err := notificationStore.CountUnread(c.Request.Context(), u.ID); err == nil {
				web.SetUnreadNotifications(c, n)
			}
		}
		c.Next()
	})
```

Use the import alias `serve.go` already has for `services/web`, and place it after the auth middleware so the user is populated.

- [ ] **Step 6: Cap the feed so it does not grow forever**

Add one more store method and wire it into the cron subcommand that already
runs daily:

```go
	// PruneKeepingNewest deletes all but the newest `keep` entries for every
	// user. Rows are kept per user rather than globally: a global cap would
	// let one busy account evict a quiet one's only notification.
	PruneKeepingNewest(ctx context.Context, keep int) error
```

Call it from the existing `notification send` cron path with `keep = 100`,
after the sending work rather than before — pruning first would delete
entries this run is about to reference.

Assert in a test that a user with 105 entries keeps exactly the newest 100
and that a second user's entries are untouched. The second half is the part
worth writing: a naive `DELETE ... ORDER BY created_at OFFSET 100` without a
per-user partition passes the first assertion and silently destroys the
second user's history.

- [ ] **Step 7: Run the suite**

```bash
make test
```
Expected: 0 failures.

- [ ] **Step 8: Prove the wiring is tested**

Delete `UnreadNotifications: unreadNotifications(c),` from `NewContext` and confirm the new test fails. Restore. Paste both directions.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat(web): carry the unread notification count, and cap the feed"
```

---

## Task 6: The bell and the page

**Repository:** `web-ui`

**Files:**
- Create: `handlers/notifications/handler.go`, `templates/views/notifications/get.html`
- Modify: `templates/partials/nav.html`, `serve.go`

**Interfaces:**
- Consumes: `Context.UnreadNotifications`, `ListByUser`, `MarkAllRead`.

- [ ] **Step 1: Read the pattern**

`templates/partials/nav.html:134` renders the onboarding counter with `{{ if .Onboarding }}`. The bell follows that shape, in both the desktop bar and the mobile burger — there are two sites, as the Vault link had.

- [ ] **Step 2: Register the routes**

`GET /notifications` renders the list. `POST /notifications/read` marks all read and redirects back. Both behind `auth.HasAuth`. Register in `serve.go` beside the other page handlers.

- [ ] **Step 3: Render the list**

`templates/views/notifications/get.html` lists title, body and relative time, newest first, with unread entries visually distinct. Follow the markup conventions of an existing view — `templates/views/profile/` is the closest.

- [ ] **Step 4: Add the bell**

In both nav sites, inside the existing `{{ if .User | hasAuth }}`:

```
{{ if gt $.UnreadNotifications 0 }}
... bell icon with the count ...
{{ else }}
... bell icon without a count ...
{{ end }}
```

- [ ] **Step 5: Verify both states render**

Start the app against a local database, with and without unread rows, and count occurrences of the badge markup in the rendered HTML. Expect non-zero with unread entries, zero without. If both come back zero, the guard is hiding the bell unconditionally — which passes any naive test while removing the feature.

- [ ] **Step 6: Commit**

```bash
make test
git add -A
git commit -m "feat(web): show notifications in the navbar and on a page"
```

---

## Task 7: Entering an email, where it can work

**Repository:** `web-ui`

**Files:**
- Create: `migrations/71_user_pending_email.{up,down}.sql`, `templates/partials/profile/email.html`
- Modify: `models/user.go`, `handlers/profile/handler.go`, `serve.go`

**Interfaces:**
- Produces: `POST /profile/email` and `GET /profile/email/verify/:token`.

The field appears only when **both** hold: the instance has no SuperTokens (so email is not identity), and `SMTP_HOST` is configured (so a verification message can actually be sent). Those two conditions are what make verification possible at all — without SMTP there is nothing to verify with, and nothing an address could achieve.

- [ ] **Step 1: The migration**

```sql
ALTER TABLE public."user"
    ADD COLUMN pending_email            text,
    ADD COLUMN pending_email_token      text,
    ADD COLUMN pending_email_expires_at timestamptz;

CREATE UNIQUE INDEX user_pending_email_token_idx
    ON public."user" (pending_email_token)
    WHERE pending_email_token IS NOT NULL;
```

with the matching `down` dropping the index and the three columns.

- [ ] **Step 2: The handler**

`POST /profile/email` accepts an address, rejects it with the existing form-error mechanism unless `notification.Deliverable` passes, stores it as pending with a random token and a 24-hour expiry, and sends exactly one message containing the verification link. Nothing else is ever sent to a pending address.

`GET /profile/email/verify/:token` promotes a pending address whose token matches and has not expired, clears the three pending columns, and reports success or an expired-link message.

- [ ] **Step 3: Gate the section**

The profile renders the email section only when SuperTokens is absent and `SMTP_HOST` is non-empty. Both facts are already available — the former is what `services/auth` keys self-hosted behaviour off, the latter is `services/common/common.go:53`. Read how each is reached rather than introducing a new flag.

- [ ] **Step 4: Test the three rules**

Write tests asserting: an undeliverable address is rejected and stores nothing; a verification link that has expired does not promote; and a token belonging to one user cannot verify another's pending address. The third is the security-relevant one — a token that is not scoped to its owner would let anyone confirm anyone's address.

- [ ] **Step 5: Prove they fail**

For each of the three, remove the corresponding check and confirm the test goes red. Paste all three.

- [ ] **Step 6: Commit**

```bash
make test
git add -A
git commit -m "feat(profile): let a self-hosted operator set and verify a notification address"
```

---

## Task 8: The dormant nil dereference

**Repository:** `web-ui`

**Files:**
- Modify: `services/auth/auth.go`

`createUser` falls through to a bare `return` when a third-party sign-in yields an empty email, putting a typed-nil `*models.User` into the request context. `makeUserFromContext` type-asserts it successfully — a typed nil satisfies the assertion — and dereferences it. Unreachable today because Google always returns an address and Patreon rejects the sign-in, but it is the only undefended path in the auth stack.

- [ ] **Step 1: Write a test that panics**

Construct the fallthrough directly and assert `makeUserFromContext` does not panic on a context holding a typed-nil `*models.User`.

- [ ] **Step 2: Run it and watch it panic**

Expected: the test fails with a nil-pointer dereference.

- [ ] **Step 3: Fix it**

Return an explicit error from `createUser` instead of falling through, and make `makeUserFromContext` treat a nil pointer as an absent user.

- [ ] **Step 4: Run it and watch it pass, then commit**

```bash
make test
git add -A
git commit -m "fix(auth): do not put a typed-nil user into the request context"
```

---

## Task 9: The subscription poller's gate

**Repository:** `self-hosted`

**Files:**
- Modify: `s6-overlay/scripts/run-cron-job`, `etc/webtor/cron/crontab`

The `SMTP_HOST` guard is keyed on the job name `notification-send`, so `subscription-poll` runs hourly regardless — doing real source searches for an account that cannot be mailed. With the feed in place the poller becomes useful without SMTP, so the fix is **not** to gate it as well: it is to correct the crontab comment, which currently implies both jobs are gated, and to make the guard's own comment say which job it covers and why the other is deliberately ungated.

- [ ] **Step 1: Read the current guard and comment**

```bash
cd /Users/vintikzzzz/Projects/webtor/self-hosted
sed -n '40,50p' s6-overlay/scripts/run-cron-job
sed -n '1,12p' etc/webtor/cron/crontab
```

- [ ] **Step 2: Correct both comments**

State plainly: `notification-send` is skipped without SMTP because its only output was mail; `subscription-poll` runs regardless because its findings now land in the in-app feed, which needs no mail server.

- [ ] **Step 3: Verify both jobs behave as documented**

Run each by hand in a container with no `SMTP_HOST` and report the exit status and output of both.

- [ ] **Step 4: Commit**

```bash
git add s6-overlay/scripts/run-cron-job etc/webtor/cron/crontab
git commit -m "docs: say which cron job the SMTP guard covers, and why the other is not gated"
```

---

## Task 10: Smoke scenario

**Repository:** `self-hosted`

**Files:**
- Create: `tests/scenarios/95-notifications.sh`

The suite's shared container is exactly the configuration under discussion: no SMTP, and an admin account whose address is the `admin` sentinel.

- [ ] **Step 1: Read the siblings**

`tests/scenarios/90-api.sh` and `91-s3-webui.sh` for house style; `tests/lib.sh` for `api_key`, `apiv1` and `webtor_exec`.

- [ ] **Step 2: Write the scenario**

Assert, against the shared container:

1. Triggering a notification produces a feed row for the admin account — query `notification` through `webtor_exec` and psql, checking `user_id IS NOT NULL`.
2. That row has `mailed_at IS NULL`, because no SMTP is configured. **This is the assertion that would have caught the journal lying**, and it is the reason this scenario exists.
3. `GET /notifications` returns 200 and its body contains the entry's title.
4. The navbar on any page shows the unread badge, and stops showing it after `POST /notifications/read`.
5. The profile offers no email input, because SMTP is unset.

Use the pledge flow from `80-vault.sh` to trigger a real notification rather than inserting a row directly — a scenario that writes its own fixture proves the query works, not the feature.

- [ ] **Step 3: Run the suite**

```bash
WEBTOR_HOST_PORT=18080 tests/run.sh <tag>
```
Expected: `SUITE PASSED` with `PASS: notifications` among them.

- [ ] **Step 4: Negative control**

Break assertion 2 by making the mailer return success again when SMTP is absent, rebuild, and confirm the scenario goes red on that assertion specifically while the others stay green. Restore and confirm green. Paste both directions.

- [ ] **Step 5: Commit**

```bash
git add tests/scenarios/95-notifications.sh
git commit -m "test: cover the notification feed end to end"
```

---

## Task 11: Documentation

**Repository:** `self-hosted`

**Files:**
- Modify: `README.md`, `CLAUDE.md`

- [ ] **Step 1: Document SMTP, which is undocumented today**

`grep -i smtp README.md` returns nothing, and `etc/webtor/common.template.env` does not carry the variables either — the only mention anywhere in the repo is a comment inside `run-cron-job`. Add `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`, `SMTP_FROM` to the README with their effect, and state plainly that without them notifications appear in the interface but no mail is sent.

- [ ] **Step 2: Document the feed**

In `README.md`: where notifications appear, that they work with no configuration, and that setting an address is optional and requires SMTP.

In `CLAUDE.md`, in Russian matching the file's voice: that the `notification` table is both the mail journal and the feed, what `mailed_at` distinguishes and why, and that the guards ask about deliverability rather than emptiness because the self-hosted admin's address is a non-empty sentinel.

- [ ] **Step 3: Verify every claim against the code, then commit**

Re-read each statement against the file it describes. Report anything removed for lack of confirmation.

```bash
git add README.md CLAUDE.md
git commit -m "docs: describe the notification feed and the SMTP variables"
```

---

## Build caveat (applies to every task that builds an image)

The `web-ui` stage in the self-hosted `Dockerfile` pins a published image predating this work. To test in-container, build `web-ui:cron` from your web-ui working tree, temporarily repoint that one `FROM` at it, and restore before committing — confirm `git diff -- Dockerfile` is empty.

## Verification standard (applies to every task)

An assertion must be a consequence of a check, not text printed beside one. Every guard added here gets a negative control: remove it, confirm the check goes red, restore it. Name explicitly anything left unverified — silence reads as "checked".

## Order and dependencies

Tasks 1–2 are the predicate and its use. Task 3 must precede Task 4, which must precede Tasks 5–6. Task 7 is independent of the feed but depends on Task 1's predicate. Tasks 8 and 9 are independent of everything. Task 10 needs Tasks 3–6 in the image, so it lands after them. Task 11 last.

## Out of scope

- Web push, and any channel other than the feed and email.
- Changing the identity email on production.
- Retrofitting notifications onto events that do not produce one today.
- Migrating existing journal rows into the feed — they have no `user_id` and will not appear, which is intended.
