// =============================================================================
// JavSnap — plugin 1.0.0 (mod17)
// Source: https://javsnap.com (SSR catalogue; detail pages at
// /<code> with a /<code>-mosaic twin form for part of the back
// catalogue; exact-code search at /search/<keyword>; actress
// filmographies at /actor/<slug>).
//
// Playback chain (measured live 2026-11-23, RESEARCH-JAVSNAP-DEPTH):
// the detail page's player carries data-url = the first-party embed
// https://vid-snap-player.com/embed/<VIDEO_ID>. The embed page is a
// static shell naming VIDEO_ID; its own player script mints a signed
// playlist token with GET <embed-origin>/api/playlist-token/<id>
// (JSON {"t": "..."}) and plays <embed-origin>/v/<token>, which
// 302-redirects to o-*.vid-snap-player.com/.../playlist.sb — plain
// HLS with disguised .sb extensions (1080p variant, relative TS
// segments). All hops are plain HTTP; no JS execution is needed.
// The token embeds the minter's IP and a minutes-scale TTL: it is
// EGRESS-BOUND, so it must be minted at play time in the playing
// client's own session and never cached across resolves — which is
// exactly how the app resolves (this parser mints a fresh token on
// every resolve; nothing token-shaped is stored anywhere).
//
// Detail URL forms (measured): try /<code> first, then
// /<code>-mosaic — the mosaic form recovers older titles the bare
// form 404s (SSIS-698, MIDE-974). List/search cards always link the
// form that exists, so item ids carry the right form already; a bare
// code slug resolves to the bare form here. A title absent under
// both forms (e.g. SONE-462) is a normal per-title catalogue miss,
// not an error.
//
// Listings serve ONE page of 28 cards (48 on home): the site's
// ?page= parameter is ignored (measured — page 2 returns page 1),
// so getUrlList does not append it and the parser reports a single
// page rather than inventing pagination.
//
// Failure contract (shared across the plugin set): an unresolvable
// page yields url === "" — never a silent partial result.
// =============================================================================

// =============================================================================
// CONFIGURATION & METADATA
// =============================================================================

function getManifest() {
    return JSON.stringify({
        "id": "javsnap",
        "name": "JavSnap",
        "version": "1.0.0",
        "baseUrl": "https://javsnap.com",
        "referrer": "https://javsnap.com/",
        "iconUrl": "https://javsnap.com/assets/client/icon/favicon.ico",
        "isEnabled": true,
        "isAdult": true,
        "type": "VIDEO",
        "layoutType": "HORIZONTAL",
        "subtitleCat": false
    });
}

function getHomeSections() {
    return JSON.stringify([
        { slug: '', title: 'Mới Nhất', type: 'Horizontal', path: '' },
        { slug: 'censored', title: 'Có Che (Censored)', type: 'Horizontal', path: '' },
        { slug: 'uncensored', title: 'Không Che (Uncensored)', type: 'Horizontal', path: '' },
        { slug: 'subtitles', title: 'Phụ Đề (Subtitles)', type: 'Horizontal', path: '' },
        { slug: 'amateur', title: 'Nghiệp Dư (Amateur)', type: 'Horizontal', path: '' },
        { slug: 'incoming', title: 'Sắp Ra Mắt', type: 'Horizontal', path: '' }
    ]);
}

function getPrimaryCategories() {
    return JSON.stringify([
        { name: 'Mới nhất', slug: '' },
        { name: 'Có che (Censored)', slug: 'censored' },
        { name: 'Không che (Uncensored)', slug: 'uncensored' },
        { name: 'Phụ đề (Subtitles)', slug: 'subtitles' },
        { name: 'Nghiệp dư (Amateur)', slug: 'amateur' },
        { name: 'Thể loại', slug: 'categories' },
        { name: 'Diễn viên', slug: 'actors' }
    ]);
}

function getFilterConfig() {
    // No sort parameter is honoured by the site (measured for
    // pagination; no sort control exists in its listing UI), so the
    // config offers only the default order.
    return JSON.stringify({
        sort: [
            { name: 'Mới nhất', value: 'new' }
        ]
    });
}

// =============================================================================
// URL GENERATION
// =============================================================================

var JAVSNAP_BASE = "https://javsnap.com";

function getUrlList(slug, filtersJson) {
    var path = slug || "";
    if (path.indexOf("/") === 0) path = path.substring(1);
    if (path.charAt(path.length - 1) === "/") path = path.substring(0, path.length - 1);
    // filters.page is deliberately unused: the site ignores ?page=
    // (measured) and serves a single page per listing.
    return path ? JAVSNAP_BASE + "/" + path : JAVSNAP_BASE + "/";
}

function getUrlSearch(keyword, filtersJson) {
    // The site's own search routes to /search/<keyword> (its form
    // posts ?q= and the server redirects to this path form).
    return JAVSNAP_BASE + "/search/" + encodeURIComponent(keyword);
}

function getUrlDetail(slug) {
    if (!slug) return JAVSNAP_BASE + "/";
    if (slug.indexOf("http") === 0) return slug;
    if (slug.indexOf("/") === 0) return JAVSNAP_BASE + slug;
    return JAVSNAP_BASE + "/" + slug;
}

function getUrlCategories() { return JAVSNAP_BASE + "/categories"; }
function getUrlCountries() { return ""; }
function getUrlYears() { return ""; }

// =============================================================================
// HELPERS
// =============================================================================

// Identical to the app's own default UA (Net.desktopUA), so plugin-
// prescribed hop headers never downgrade the app's fetch contract.
var DESKTOP_UA_JAVSNAP = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

var PluginUtils = {
    cleanText: function (text) {
        if (!text) return "";
        return text.replace(/<[^>]*>/g, "")
            .replace(/&amp;/g, "&")
            .replace(/&quot;/g, '"')
            .replace(/&#039;/g, "'")
            .replace(/&apos;/g, "'")
            .replace(/&lt;/g, "<")
            .replace(/&gt;/g, ">")
            .replace(/\s+/g, " ")
            .trim();
    },
    getMeta: function (html, property) {
        var regex1 = new RegExp('(?:property|name)=["\']' + property + '["\'][^>]*content=(["\'])(.*?)\\1', 'i');
        var regex2 = new RegExp('content=(["\'])(.*?)\\1[^>]*(?:property|name)=["\']' + property + '["\']', 'i');
        var match = html.match(regex1) || html.match(regex2);
        return match ? match[2] : "";
    }
};

function javsnapOrigin(url) {
    var m = String(url || "").match(/^(https?:\/\/[^\/]+)/i);
    return m ? m[1] : "";
}

// =============================================================================
// LIST PARSERS
// =============================================================================

function parseListResponse(html) {
    var movies = [];
    var seen = {};

    // Movie cards: <div class="item" data-movie-item="<n>"> blocks
    // carrying the poster <img> and the a.item__play detail link.
    var parts = html.split('<div class="item" data-movie-item="');
    for (var i = 1; i < parts.length; i++) {
        var chunk = parts[i].substring(0, 4000);
        var linkMatch = chunk.match(/href="(https:\/\/javsnap\.com\/([^"\/]+))"[^>]*class="item__play"/i) ||
                        chunk.match(/<a[^>]+class="item__play"[^>]+href="(https:\/\/javsnap\.com\/([^"\/]+))"/i);
        if (!linkMatch) continue;
        var slug = linkMatch[2];
        if (seen[slug]) continue;
        seen[slug] = true;

        var imgMatch = chunk.match(/<img[^>]+src="([^"]+)"/i);
        var poster = imgMatch ? imgMatch[1] : "";
        if (poster && poster.indexOf("//") === 0) poster = "https:" + poster;

        var title = "";
        var ariaMatch = chunk.match(/class="item__play"[^>]*aria-label="([^"]+)"/i) ||
                        chunk.match(/aria-label="([^"]+)"[^>]*class="item__play"/i);
        if (ariaMatch) title = ariaMatch[1];
        if (!title && imgMatch) {
            var altMatch = chunk.match(/<img[^>]+alt="([^"]+)"/i);
            if (altMatch) title = altMatch[1];
        }
        if (!title) title = slug;

        var lang = "Censored";
        if (/item__type--uncensored/i.test(chunk)) lang = "Uncensored";

        movies.push({
            id: slug,
            title: PluginUtils.cleanText(title),
            posterUrl: poster,
            backdropUrl: poster,
            description: "",
            year: 0,
            quality: "HD",
            episode_current: "",
            lang: lang
        });
    }

    // Index pages (/categories, /actors, /studios, /labels) carry no
    // movie cards; their category-card items become CAT / ACTRESS
    // entries (the missav/123av index convention).
    if (movies.length === 0) {
        var catParts = html.split('<div class="item category-card">');
        for (var c = 1; c < catParts.length; c++) {
            var cChunk = catParts[c].substring(0, 2500);
            var cLink = cChunk.match(/href="https:\/\/javsnap\.com\/(genre|actor|studio|label)\/([^"\/]+)"/i);
            if (!cLink) continue;
            var kind = cLink[1].toLowerCase();
            var cSlug = kind + "/" + cLink[2];
            if (seen[cSlug]) continue;
            seen[cSlug] = true;
            var cName = "";
            var nameMatch = cChunk.match(/category-card__name">([^<]+)</i);
            if (nameMatch) cName = PluginUtils.cleanText(nameMatch[1]);
            if (!cName) {
                var cAlt = cChunk.match(/<img[^>]+alt="([^"]+)"/i);
                if (cAlt) cName = PluginUtils.cleanText(cAlt[1]);
            }
            if (!cName) continue;
            var cImg = cChunk.match(/<img[^>]+src="([^"]+)"/i);
            var cPoster = cImg ? cImg[1] : "";
            if (kind === "actor") {
                movies.push({
                    id: cSlug,
                    title: cName,
                    posterUrl: cPoster,
                    backdropUrl: cPoster,
                    description: "Nữ diễn viên",
                    year: 0,
                    quality: "ACTRESS",
                    episode_current: "",
                    lang: ""
                });
            } else {
                movies.push({
                    id: cSlug,
                    title: cName,
                    posterUrl: "",
                    backdropUrl: "",
                    description: kind === "genre" ? "Thể loại" : (kind === "studio" ? "Studio" : "Label"),
                    year: 0,
                    quality: "CAT",
                    episode_current: "",
                    lang: ""
                });
            }
        }
    }

    return JSON.stringify({
        items: movies,
        pagination: {
            currentPage: 1,
            totalPages: 1,
            totalItems: movies.length,
            itemsPerPage: movies.length || 28
        }
    });
}

function parseSearchResponse(html) {
    return parseListResponse(html);
}

// =============================================================================
// DETAIL PARSER
// =============================================================================

function parseMovieDetail(htmlContent, pageUrl) {
    try {
        var html = htmlContent || "";

        // ---- Code / slug ---------------------------------------------------
        var slug = "";
        var canonMatch = html.match(/<link\s+rel="canonical"\s+href="https:\/\/javsnap\.com\/([^"\/]+)"/i);
        if (canonMatch) slug = canonMatch[1];
        if (!slug && pageUrl) {
            var urlMatch = String(pageUrl).match(/javsnap\.com\/([^\/\?#]+)/i);
            if (urlMatch) slug = urlMatch[1];
        }
        var code = slug.toUpperCase().replace(/-MOSAIC$/, "");

        // ---- JSON-LD Movie block (clean title + plot, when present) --------
        var ldName = "", ldDesc = "", ldCode = "";
        var ldMatch = html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/i);
        if (ldMatch) {
            var ldNameM = ldMatch[1].match(/"@type":"Movie"[\s\S]*?"name":"([^"]+)"/);
            if (ldNameM) ldName = ldNameM[1];
            var ldIdM = ldMatch[1].match(/"identifier":"([^"]+)"/);
            if (ldIdM) ldCode = ldIdM[1].toUpperCase();
            var ldDescM = ldMatch[1].match(/"description":"([^"]+)"/);
            if (ldDescM) ldDesc = ldDescM[1];
        }
        if (ldCode) code = ldCode;

        // ---- Title ----------------------------------------------------------
        var title = PluginUtils.cleanText(ldName);
        if (!title) {
            var ogTitle = PluginUtils.cleanText(PluginUtils.getMeta(html, "og:title"));
            title = ogTitle.replace(/\s*\|\s*JAVSnap\s*$/i, "")
                           .replace(/^[A-Za-z]{2,6}-\d{2,6}(?:-MOSAIC)?\s+/i, "")
                           .trim();
            if (!title) title = ogTitle;
        }

        // ---- Poster ----------------------------------------------------------
        var poster = "";
        var posterMatch = html.match(/movie-info__poster[\s\S]{0,800}?<img[^>]+src="([^"]+)"/i);
        if (posterMatch) poster = posterMatch[1];
        if (!poster) poster = PluginUtils.getMeta(html, "og:image");
        if (poster && poster.indexOf("//") === 0) poster = "https:" + poster;

        // ---- Info table (scoped reads: the related rail below links other
        // titles' actors/genres and must not leak into this title) -----------
        var info = "";
        var infoMatch = html.match(/<table class="info-table">([\s\S]*?)<\/table>/i);
        if (infoMatch) info = infoMatch[1];

        function infoRow(label) {
            var m = info.match(new RegExp("<td>" + label + "<\\/td>\\s*<td[^>]*>([\\s\\S]*?)<\\/td>", "i"));
            return m ? m[1] : "";
        }

        // Casts: the shared markdown convention [Name](/actor/<slug>)
        // (same form JavGuru emits), so a cast tap routes to the
        // actress's filmography.
        var actors = [];
        var seenActors = {};
        var castRow = infoRow("Cast");
        var actRe = /<a[^>]+href="https?:\/\/javsnap\.com\/actor\/([^"\/]+)"[^>]*>([^<]+)<\/a>/gi;
        var am;
        while ((am = actRe.exec(castRow)) !== null) {
            var aName = PluginUtils.cleanText(am[2]);
            if (aName && !seenActors[am[1]]) {
                seenActors[am[1]] = true;
                actors.push("[" + aName + "](/actor/" + am[1] + ")");
            }
        }

        // Director / studio / label: plain text (the L-20 convention).
        var director = PluginUtils.cleanText(infoRow("Director"));
        var studio = PluginUtils.cleanText(infoRow("Studio"));
        var label = PluginUtils.cleanText(infoRow("Label"));

        // Genres: plain text (L-20).
        var genres = [];
        var genreRow = infoRow("Categories");
        var genRe = /<a[^>]+href="https?:\/\/javsnap\.com\/genre\/[^"]+"[^>]*>([^<]+)<\/a>/gi;
        var gm;
        while ((gm = genRe.exec(genreRow)) !== null) {
            var gName = PluginUtils.cleanText(gm[1]);
            if (gName && genres.indexOf(gName) === -1) genres.push(gName);
        }

        var releaseText = PluginUtils.cleanText(infoRow("Release"));
        var year = 0;
        var yearMatch = releaseText.match(/(\d{4})/);
        if (yearMatch) year = parseInt(yearMatch[1], 10);
        var duration = PluginUtils.cleanText(infoRow("Duration"));

        var description = PluginUtils.cleanText(ldDesc);

        // ---- Server: the first-party vid-snap-player embed only. The page
        // also offers third-party mirrors (playmogo / streamtape tabs);
        // those chains are unmeasured and one of them was rejected in
        // the source hunts, so they are deliberately not emitted. -------
        var servers = [];
        var embedMatch = html.match(/data-url="(https:\/\/vid-snap-player\.com\/embed\/[^"]+)"/i);
        if (embedMatch) {
            servers.push({
                name: "VidSnap",
                episodes: [{
                    id: embedMatch[1],
                    name: "Full",
                    slug: "vidsnap"
                }]
            });
        }

        var statusLine = "";
        if (studio) statusLine += "Studio: " + studio;
        if (label) statusLine += (statusLine ? " | " : "") + "Label: " + label;
        if (releaseText) statusLine += (statusLine ? " | " : "") + "Release: " + releaseText;

        return JSON.stringify({
            id: code || slug,
            title: title,
            posterUrl: poster,
            backdropUrl: poster,
            description: description,
            year: year,
            rating: 0,
            quality: "HD",
            servers: servers,
            episode_current: servers.length > 0 ? "Full" : "No Source",
            lang: "Censored",
            category: genres.join(", "),
            country: "Japan",
            director: director,
            casts: actors.join(", "),
            status: statusLine,
            duration: duration,
            previewUrl: ""
        });
    } catch (e) {
        return "null";
    }
}

// =============================================================================
// RESOLVE — embed page -> playlist-token mint -> /v/<token> -> playlist
// =============================================================================
// Three parses, inside the app's default 4-parse chain budget:
//   1. embed page (VIDEO_ID)        -> GET /api/playlist-token/<id>
//   2. token JSON ({"t": ...})      -> GET /v/<token>
//   3. playlist body (#EXTM3U, the /v/ fetch after its 302)
//                                   -> terminal: the /v/ URL itself.
// The terminal URL is the /v/<token> URL the app already fetched:
// the player re-follows the same 302 to the o-* playlist. The token
// is minted fresh inside this resolve and used immediately — it is
// never returned anywhere else, stored, or reused across resolves.

function javsnapFailure() {
    return JSON.stringify({
        url: "",
        isEmbed: false,
        headers: {
            "User-Agent": DESKTOP_UA_JAVSNAP,
            "Referer": "https://javsnap.com/"
        },
        subtitles: [],
        alternateURLs: []
    });
}

function parseJavSnapResolve(htmlContent, pageUrl) {
    var text = htmlContent || "";
    var url = pageUrl || "";

    // Hop 3 — the playlist body itself: terminal. Headers stay EMPTY
    // on purpose: the app then keeps the chain's current headers
    // (hop 2's Referer = the embed page), which is what the o-*
    // CDN was measured to accept for playlist and segments alike.
    if (/^\s*#EXTM3U/.test(text)) {
        return JSON.stringify({
            url: url,
            isEmbed: false,
            headers: {},
            subtitles: []
        });
    }

    // Hop 2 — the token endpoint's JSON: build the /v/<token> hop.
    // The embed URL is reconstructed from the token URL (same id)
    // so the /v/ fetch carries the embed page as its Referer,
    // exactly as the site's own player does.
    if (url.indexOf("/api/playlist-token/") !== -1) {
        var token = null;
        try {
            var data = JSON.parse(text);
            if (data && typeof data.t === "string" && data.t) token = data.t;
        } catch (e) { }
        if (token) {
            var origin2 = javsnapOrigin(url) || "https://vid-snap-player.com";
            var idMatch = url.match(/playlist-token\/([0-9a-fA-F-]{36})/);
            return JSON.stringify({
                url: origin2 + "/v/" + token,
                isEmbed: true,
                headers: {
                    "User-Agent": DESKTOP_UA_JAVSNAP,
                    "Referer": idMatch ? origin2 + "/embed/" + idMatch[1] : "https://javsnap.com/"
                },
                subtitles: []
            });
        }
        return javsnapFailure();
    }

    // Hop 1 — the embed page: mint the token. VIDEO_ID is read from
    // the page body (the embed shell's own variable), falling back
    // to the id in the embed URL itself.
    var videoId = null;
    var vidMatch = text.match(/VIDEO_ID\s*=\s*"([0-9a-fA-F-]{36})"/) ||
                   text.match(/VIDEO_ID\s*=\s*'([0-9a-fA-F-]{36})'/);
    if (vidMatch) videoId = vidMatch[1];
    if (!videoId) {
        var urlIdMatch = url.match(/\/embed\/([0-9a-fA-F-]{36})/);
        if (urlIdMatch) videoId = urlIdMatch[1];
    }
    if (videoId) {
        var origin1 = javsnapOrigin(url) || "https://vid-snap-player.com";
        return JSON.stringify({
            url: origin1 + "/api/playlist-token/" + videoId,
            isEmbed: true,
            headers: {
                "User-Agent": DESKTOP_UA_JAVSNAP,
                "Referer": url
            },
            subtitles: []
        });
    }

    // Drift fallback: an embed page whose shell changed shape —
    // hand the page itself back as an embed (the 123av precedent)
    // so the app's sniffing webview can run the site's own player.
    if (url && url.indexOf("vid-snap-player.com/embed/") !== -1) {
        return JSON.stringify({
            url: url,
            isEmbed: true,
            headers: {
                "User-Agent": DESKTOP_UA_JAVSNAP,
                "Referer": "https://javsnap.com/"
            },
            subtitles: []
        });
    }

    return javsnapFailure();
}

function parseEmbedResponse(htmlContent, pageUrl) {
    var resolved = parseJavSnapResolve(htmlContent, pageUrl);
    if (resolved) return resolved;
    return javsnapFailure();
}

function parseDetailResponse(htmlContent, pageUrl) {
    // In the resolver chain this parser runs on the same payloads
    // as parseEmbedResponse (embed page, token JSON, playlist), so
    // it shares the resolve logic above (the 123av convention).
    return parseEmbedResponse(htmlContent, pageUrl);
}

function parseCategoriesResponse(html) {
    var categories = [];
    var found = {};
    var parts = String(html || "").split('<div class="item category-card">');
    for (var i = 1; i < parts.length; i++) {
        var chunk = parts[i].substring(0, 2500);
        var linkMatch = chunk.match(/href="https:\/\/javsnap\.com\/genre\/([^"\/]+)"/i);
        if (!linkMatch) continue;
        var slug = "genre/" + linkMatch[1];
        if (found[slug]) continue;
        var nameMatch = chunk.match(/category-card__name">([^<]+)</i);
        var name = nameMatch ? PluginUtils.cleanText(nameMatch[1]) : "";
        if (!name || name.length < 2) continue;
        found[slug] = true;
        categories.push({ name: name, slug: slug });
    }
    return JSON.stringify(categories);
}

function parseCountriesResponse(html) { return "[]"; }
function parseYearsResponse(html) { return "[]"; }
