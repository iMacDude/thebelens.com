# likes — one like counter for BOTH sites

A Cloudflare Worker plus a KV namespace, serving:

| Site | Calls | Origin |
|---|---|---|
| `thebelens.com` | `/api/likes/tb/<slug>` | same origin |
| `footprintsoffrank.com` | `https://thebelens.com/api/likes/fof/<slug>` | cross origin |

**Frank borrows this Worker because his domain cannot host one.**
footprintsoffrank.com runs on GoDaddy nameservers pointing straight at GitHub
Pages — there is no Cloudflare zone, so no Worker route can bind to it at all.
The alternatives were migrating that zone's DNS, which would move the Zoho MX
records and put Frank's email in the blast radius of a like button, or giving
Frank a `*.workers.dev` hostname, which is a Cloudflare-owned domain in the page
and exactly what the same-origin design exists to avoid. Borrowing is the
smallest of the three.

**The site code is in the PATH, not inferred from the `Origin` header.** Two
independent Jekyll sites can have the same slug; without the prefix, two
unrelated posts would silently share one counter and the mixing could not be
undone. KV keys are `tb:<slug>` and `fof:<slug>`. `Origin` is used only for
access control, never for routing — it can be absent or spoofed, but a path
cannot be ambiguous.
No third-party service, no ads, no tracker, and **no personal data at all**.

| | |
|---|---|
| **Worker** | `src/worker.js` |
| **Front end** | `../../_includes/likes.html`, styles in `assets/css/main.css` (`.post-likes`) |
| **Switch** | `likes_enabled` in `_config.yml` — **off** until the Worker is deployed |
| **Local test** | `npm test` (real runtime, no account needed) |
| **Deploy** | `./deploy.sh` |

## Why it is on thebelens.com and not *.workers.dev

The route binds to the site's **own origin**, which buys three things:

1. No CORS preflight and no third-party hostname in the page.
2. **It cannot be blocked by the house gateway.** That gateway nulls tracker
   domains to `0.0.0.0`, `static.cloudflareinsights.com` among them — the
   documented reason Cloudflare Web Analytics would undercount here. Anything
   served from a Cloudflare-owned hostname risks being invisible from inside
   the house. The site's own domain cannot be.
3. No new DNS record to add or verify.

## The traps this is built against

**The zone caches aggressively, and has poisoned itself once.** thebelens.com
serves `cache-control: max-age=14400` and Cloudflare once cached a 404 here for
four hours. A cached like-count is worse than a wrong one — it freezes the same
stale number for every visitor and reads as a broken counter. So every response,
including the errors, carries `Cache-Control: no-store`, and `deploy.sh` checks
`cf-cache-status` on the live URL rather than trusting it.

**KV has no atomic increment.** This is a read-modify-write, so two likes in the
same few milliseconds can count as one. Durable Objects are the strictly
consistent fix and need the paid plan. At this site's traffic the window is
negligible and the failure mode is a count low by one — not a broken page.
Accepted deliberately, not overlooked.

**KV reads are eventually consistent** (up to ~60s between colos), which is why
POST returns the new count in its own body: the page shows the number it just
wrote instead of re-reading a stale one.

**Jekyll's `exclude:` is not `.gitignore`.** `.gitignore` keeps `node_modules`
out of git; it does nothing about the **build**. Before `- workers` was added to
`exclude:` in `_config.yml`, Jekyll copied 1,644 files into `_site` (a 160 MB
build) and would have served `deploy.sh` and the Worker source at
`thebelens.com/workers/likes/`. Two separate exclusion systems.

**Free-tier KV allows 1,000 writes/day** per namespace. Normal traffic is
nowhere near it, but someone hammering POST could exhaust it, after which likes
silently stop recording for the rest of the day. The proportionate control is a
Cloudflare **Rate Limiting** rule on `/api/likes/*` (one dashboard rule, free
tier) — worth adding if the counter ever gets attention.

## Privacy

Dedup is `localStorage` only: no cookie, no IP, no hash, no fingerprint. Nothing
is stored about who clicked, so there is no consent banner to add and no reader
data to leak. The honest cost: clearing storage lets someone like again. For a
family blog that is the right trade — the counter is warmth, not an election.

## Deploying

The repo deliberately holds **no credentials** and no account id; it is public.

1. **Credentials.** Preferred — a scoped API token in
   `~/.config/homelab/cloudflare.env`, `chmod 600`, the same pattern the homelab
   uses for Kuma push tokens and the pool webhook id:

   ```
   CLOUDFLARE_ACCOUNT_ID=...
   CLOUDFLARE_API_TOKEN=...
   LIKES_KV_ID=...
   ```

   Token permissions: Account › Workers Scripts **Edit**, Account › Workers KV
   Storage **Edit**, Zone › Workers Routes **Edit**, Zone › Zone **Read**
   (thebelens.com). Alternative: `npx wrangler login`, simpler but grants
   everything the account can do.

   Write the token at a `read -rs` prompt, never on a command line — `&` in a
   pasted value forks jobs and the value lands in shell history. (That exact
   mistake wrote a 0-byte Kuma URL file on the Pi5.)

2. **Create the KV namespace, once:**

   ```sh
   npx wrangler kv namespace create LIKES
   ```

   Put the printed id in the env file as `LIKES_KV_ID`. Creating it twice makes
   a second namespace and the counts split silently between them, which is why
   `deploy.sh` refuses to guess.

3. **Deploy and verify:**

   ```sh
   ./deploy.sh
   ```

   It deploys, then proves the live endpoint returns 200, is `no-store`, is not
   a `cf-cache-status: HIT`, and that a POST increments by exactly one. It exits
   non-zero if any of that fails — a deploy that "succeeded" into a broken state
   is the thing worth catching.

4. **Turn the front end on** — set `likes_enabled: true` in `_config.yml`,
   commit, push. Order matters: the Worker first, so no 404s are fired at a path
   that does not exist yet.

## Testing locally

**`wrangler dev` rewrites the routed hostname in outgoing headers, and it is a
blind string substitution.** With `thebelens.com/api/likes/*` configured as the
route, a response echoing `https://thebelens.com` arrives as
`https://127.0.0.1:<port>` — and `https://www.thebelens.com` arrives as the
nonsense `https://www.127.0.0.1:<port>`, which is the proof that it is textual
rather than URL-aware. It applies on the `/fof/` path too, so it is keyed on the
route's `zone_name` and has nothing to do with the Worker, whose `tb` and `fof`
paths are the same code. This produced one confident false failure of the CORS
test. The test is now rewrite-aware; **Frank's CORS can only be truly verified
against the deployed Worker**, which is why `deploy.sh` checks it.

```sh
npm test
```

Boots `wrangler dev --local` (real workerd, real KV emulation, no Cloudflare
account, no network) on a **free port** and runs 21 assertions, failure branches
included — bad slugs, wrong methods, foreign origins, and `no-store` on every
response.

Two things the harness learned the hard way, both worth keeping:

- **It picks a free port instead of the 8787 default.** An unrelated local
  service was already on 8787, its 404s stood in for the Worker, and three tests
  **passed against the wrong server** — worse than the fourteen that failed.
- **The readiness probe asserts identity, not liveness**: it waits for
  `"slug":"warmup"` in the body, not merely for something to answer. A liveness
  check cannot tell whether the thing replying is the thing you meant — the same
  shape as a NUT port check reading green through a 43-hour outage.

## Rolling it back

Set `likes_enabled: false`, commit, push — the control disappears. The Worker
and the counts stay put, so turning it back on loses nothing. To remove the
backend as well: `npx wrangler delete` and delete the KV namespace in the
dashboard (that one **is** destructive — the counts are gone).
