/**
 * likes — one like counter serving BOTH of John's sites.
 *
 *   thebelens.com         -> /api/likes/tb/<slug>    (same origin)
 *   footprintsoffrank.com -> /api/likes/fof/<slug>   (cross origin)
 *
 * WHY ONE WORKER AND NOT TWO
 * footprintsoffrank.com has NO Cloudflare zone -- GoDaddy nameservers pointing
 * straight at GitHub Pages -- so a Worker route cannot be bound to it at all.
 * The alternatives were migrating Frank's DNS (which would move the Zoho MX
 * records, putting email in the blast radius of a like button) or giving Frank
 * a *.workers.dev hostname (a Cloudflare-owned domain in the page, the exact
 * thing the same-origin design exists to avoid, since the house gateway nulls
 * such domains to 0.0.0.0). So Frank borrows this one cross-origin.
 *
 * THE SITE CODE IS IN THE PATH, NOT INFERRED FROM THE ORIGIN HEADER.
 * Two independent Jekyll sites can absolutely have the same slug, and a
 * collision would silently merge two unrelated posts into one counter -- a bug
 * that looks like "the number is wrong" and is unrecoverable once mixed. The
 * path carries the site explicitly so the key is unambiguous and testable, and
 * Origin is used only for access control, never for routing. Origin can be
 * absent or spoofed; the path cannot be ambiguous.
 *
 * WHY THIS IS ON thebelens.com/api/... AND NOT *.workers.dev
 * Same origin for the main site: no CORS there, no third-party hostname, and
 * crucially it cannot be blocked by the house gateway, which nulls tracker
 * domains to 0.0.0.0 -- `static.cloudflareinsights.com` among them. That is the
 * documented reason Cloudflare Web Analytics undercounts here.
 *
 * THE CACHE TRAP, WHICH IS THE ONE THAT WOULD ACTUALLY BREAK THIS
 * The zone serves `cache-control: max-age=14400` and has cached a 404 on this
 * domain for four hours once. A cached like-count is worse than a wrong one: it
 * freezes the same stale number for every visitor and reads as a broken
 * counter. EVERY response here, errors included, is `no-store`, and deploy.sh
 * reads `cf-cache-status` off the live URL rather than trusting it.
 *
 * KV IS NOT ATOMIC -- A DELIBERATE, ACCEPTED COST
 * No increment operation exists, so this is a read-modify-write and two likes
 * within a few milliseconds can count as one. Durable Objects are the strictly
 * consistent fix and need the paid plan. The failure mode is a count low by
 * one, not a broken page. KV reads are also eventually consistent (~60s), which
 * is why POST returns the new count in its own body: the page shows the number
 * it just wrote rather than re-reading a stale one.
 */

const SLUG_RE = /^[a-z0-9][a-z0-9-]{0,79}$/;

/** Site code -> the origins allowed to write for it. */
const SITES = {
    tb:  ["https://thebelens.com", "https://www.thebelens.com"],
    fof: ["https://footprintsoffrank.com", "https://www.footprintsoffrank.com"],
};
const ALL_ORIGINS = Object.values(SITES).flat();

function corsHeaders(origin) {
    // Echo the specific origin rather than "*": the set is small, known, and
    // entirely John's. Vary:Origin so no cache can ever mix two origins'
    // responses -- belt and braces next to no-store.
    if (!origin || !ALL_ORIGINS.includes(origin)) return { vary: "Origin" };
    return {
        "access-control-allow-origin": origin,
        "access-control-allow-methods": "GET, POST, OPTIONS",
        "access-control-max-age": "86400",
        vary: "Origin",
    };
}

function json(body, status, origin) {
    return new Response(status === 204 ? null : JSON.stringify(body), {
        status,
        headers: {
            ...(status === 204 ? {} : { "content-type": "application/json; charset=utf-8" }),
            "cache-control": "no-store, no-cache, must-revalidate, max-age=0",
            "x-robots-tag": "noindex",
            ...corsHeaders(origin),
        },
    });
}

export default {
    async fetch(request, env) {
        const url = new URL(request.url);
        const origin = request.headers.get("Origin");

        // /api/likes/<site>/<slug> -- exactly two segments, nothing else.
        const m = url.pathname.match(/^\/api\/likes\/([a-z]{2,8})\/([^/]+)\/?$/);
        if (!m) return json({ error: "not found" }, 404, origin);

        const site = m[1];
        const slug = decodeURIComponent(m[2]).toLowerCase();
        if (!Object.prototype.hasOwnProperty.call(SITES, site)) {
            return json({ error: "unknown site" }, 404, origin);
        }
        // Strict allowlist: KV keys are created on first write, so an unchecked
        // slug lets anyone fill the namespace with junk and burn the daily
        // write quota.
        if (!SLUG_RE.test(slug)) return json({ error: "bad slug" }, 400, origin);

        const key = `${site}:${slug}`;

        // Browsers will not preflight these (GET/POST carrying only Accept,
        // which is CORS-safelisted), but answer OPTIONS correctly anyway so a
        // future header addition does not quietly break Frank's site.
        if (request.method === "OPTIONS") return json(null, 204, origin);

        if (request.method === "GET") {
            const raw = await env.LIKES.get(key);
            return json({ site, slug, count: Number(raw) || 0 }, 200, origin);
        }

        if (request.method === "POST") {
            // Writes require a known origin. Not a security control in any
            // serious sense -- there is no session to forge and nothing to
            // protect -- it just stops the button being driven from someone
            // else's page. A direct curl (no Origin) is still allowed, because
            // refusing it would break the deploy self-test for no benefit.
            if (origin && !ALL_ORIGINS.includes(origin)) {
                return json({ error: "origin not allowed" }, 403, origin);
            }
            const current = Number(await env.LIKES.get(key)) || 0;
            const count = current + 1;
            await env.LIKES.put(key, String(count));
            return json({ site, slug, count, liked: true }, 200, origin);
        }

        return json({ error: "method not allowed" }, 405, origin);
    },
};
