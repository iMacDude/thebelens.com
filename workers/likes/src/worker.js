/**
 * likes — a like counter for thebelens.com, running on Cloudflare Workers + KV.
 *
 * WHY A WORKER ROUTE AND NOT *.workers.dev
 * This is bound to thebelens.com/api/likes/* on the zone, so the browser calls
 * the SAME ORIGIN the page came from. That buys three things:
 *   1. No CORS preflight, no third-party hostname in the page.
 *   2. It cannot be blocked by John's own gateway. The gateway nulls tracker
 *      domains to 0.0.0.0 -- `static.cloudflareinsights.com` among them -- so
 *      anything served from a Cloudflare-owned hostname risks being invisible
 *      from inside the house, which is the documented reason Cloudflare Web
 *      Analytics would undercount here. The site's own domain cannot be.
 *   3. No new DNS record to add or verify.
 *
 * THE CACHE TRAP, WHICH IS THE ONE THAT WOULD ACTUALLY BREAK THIS
 * The zone serves `cache-control: max-age=14400`, and Cloudflare has already
 * cached a 404 on this domain for four hours once. A cached like-count is worse
 * than a wrong one: it freezes the same stale number for every visitor and
 * looks like the counter is broken. So EVERY response here -- including the
 * errors -- carries `Cache-Control: no-store`, and the deploy check reads
 * `cf-cache-status` to confirm it rather than trusting it.
 *
 * KV IS NOT ATOMIC, AND THAT IS A DELIBERATE ACCEPTED COST
 * There is no increment operation; this is a read-modify-write, so two likes
 * landing in the same few milliseconds can count as one. Durable Objects are
 * the strictly-consistent fix and require the paid plan. At this site's traffic
 * the collision window is negligible, and the failure mode is a counter that is
 * low by one -- not a broken page or lost data. Stated rather than hidden.
 *
 * KV is also eventually consistent on READ (up to ~60s between colos), which is
 * why POST returns the new count in its own response body: the page shows the
 * authoritative number it just wrote instead of re-reading a stale one.
 */

const SLUG_RE = /^[a-z0-9][a-z0-9-]{0,79}$/;
const ALLOWED_ORIGINS = ["https://thebelens.com", "https://www.thebelens.com"];

/** Never cacheable, by anything, ever. See the cache trap above. */
function json(body, status = 200) {
    return new Response(JSON.stringify(body), {
        status,
        headers: {
            "content-type": "application/json; charset=utf-8",
            "cache-control": "no-store, no-cache, must-revalidate, max-age=0",
            "x-robots-tag": "noindex",
        },
    });
}

export default {
    async fetch(request, env) {
        const url = new URL(request.url);

        // /api/likes/<slug> -- anything else is not ours.
        const m = url.pathname.match(/^\/api\/likes\/([^/]+)\/?$/);
        if (!m) return json({ error: "not found" }, 404);

        const slug = decodeURIComponent(m[1]).toLowerCase();
        // Strict allowlist: KV keys are created on first write, so an unchecked
        // slug lets anyone fill the namespace with junk keys and burn the daily
        // write quota. A generated post manifest would be stricter still -- see
        // the README -- but shape + length is proportionate and has no build step.
        if (!SLUG_RE.test(slug)) return json({ error: "bad slug" }, 400);

        if (request.method === "GET") {
            const raw = await env.LIKES.get(slug);
            return json({ slug, count: Number(raw) || 0 });
        }

        if (request.method === "POST") {
            // Same-origin only. This is not a security control -- there is
            // nothing to protect and no session to forge -- it just stops the
            // button being driven from someone else's page by accident.
            const origin = request.headers.get("Origin");
            if (origin && !ALLOWED_ORIGINS.includes(origin)) {
                return json({ error: "origin not allowed" }, 403);
            }
            const current = Number(await env.LIKES.get(slug)) || 0;
            const count = current + 1;
            await env.LIKES.put(slug, String(count));
            return json({ slug, count, liked: true });
        }

        return json({ error: "method not allowed" }, 405);
    },
};
