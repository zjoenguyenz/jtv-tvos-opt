// =============================================================================
// Hentai Hub plugin v1.0.2 — ONE combined plugin, THREE source adapters.
// Built 2026-11-18 from the measured source hunt (HENTAI-SOURCE-HUNT.md).
// The owner ordered every quality hentai source that verifies folded
// into a single plugin; catalogues stay per-source (labelled rails,
// source-scoped genres, source-prefixed ids) — never one merged list.
//
//   hs:   hstream.moe    — fully verified end-to-end from the VM:
//         list /search?order=recently-released (25/page, page= works),
//         search /search?search=<kw> (verified filtering), tag lists
//         /search?tags[0]=<tag>. Detail /hentai/<slug>-<ep> carries a
//         hidden #e_id and the session CSRF token in the Livewire
//         script tag's data-csrf attribute. Playback: POST
//         /player/api {"episode_id":N,"_token":T} with header
//         X-CSRF-TOKEN: T — measured 200 (the hunt's cookie-derived
//         X-XSRF-TOKEN also works, but a plugin cannot read cookies;
//         the page-embedded token is the in-contract equivalent, and
//         the app's shared cookie jar rides along on the POST anyway).
//         Response JSON -> <stream_domain>/<stream_url>/x264.720p.mp4
//         (range GET verified 206 video/mp4, 115,556,776 bytes on the
//         sampled title; x264.1080p.mp4 measured 404 — higher variant
//         file naming is NOT confirmed, so v1 ships the verified 720p
//         file) + eng.vtt / eng.ass subtitles alongside.
//   haho: haho.moe       — series /anime/<id> (24/page, ?page= works),
//         search /anime?q=<kw> (verified filtering), genres are opaque
//         ids under /genre/<id> (index at /genre). Episodes
//         /anime/<id>/<n> (the ?v= variant is a per-server alias; the
//         canonical no-query URL works — the watch page itself carries
//         the embed iframe). Watch -> iframe /embed?v=<vid> -> the
//         embed's <video> <source> ladder on filegasm: direct token'd
//         MP4s (s*.filegasm.com/<hash>?download_token=) labelled by
//         resolution; prefer the highest-labelled DIRECT file, with
//         the embed page as Referer. filegasm /watch/ page sources
//         are returned as embeds for the app's webview path. The final
//         file's true resolution is device-owed (the VM's fetch of a
//         token'd file was dropped by filegasm — inconclusive).
//   hh:   hentaihaven.co — the .xxx host is Cloudflare-challenged from
//         the VM; .co is the same network's mirror and serves openly.
//         The site is a Next.js app: list cards live in the escaped
//         RSC flight payload (\"className\":\"a_item\",\"href\":...),
//         40 cards/page, /?page=N up to 85. Genres /genre/<slug>/,
//         tags /tag/<slug>/. NO working server search (/?s= and
//         /search/?s= return the identical default listing — measured
//         with a nonsense query), and parseSearchResponse cannot see
//         the keyword, so hh is honestly OMITTED from search v1.
//         Watch /watch/<series>-episode-<n>/ -> iframe
//         nhplayer.com/v/<id>/ -> server <li data-id="/player.php?
//         vid=<b64>&s=<b64>&i=<b64>&type=">. v1.0.0 handed the
//         player.php URL to the app's sniffing WebView player,
//         whose real page runs its own proof-of-work — and serves
//         a ~10 s pre-roll ad first (owner's device report,
//         2026-11-19). v1.0.1 implements the player's proof-of-work
//         IN-PLUGIN (measured end-to-end from the VM): the player
//         page carries _pV{vid,ct,pid,st} plus five challenge
//         parts hidden in a decoy-guarded DOM block (the real
//         block is the one whose ts equals the pid prefix);
//         player-core-v2.php carries the per-request sc/rid
//         tokens; the PoW is SHA-256(challenge + nonceHex) with
//         first byte 0 (expected ~256 tries, pure-JS SHA-256
//         below); GET /get-video-url-v2.php with a clean-browser
//         fingerprint payload returns {"url": signed MP4 on
//         r2.1hanime.com}; the data-id s param base64-decodes to
//         the English SRT. The resolver hop budget (initial fetch
//         + 4 parses) only fits the full PoW chain when the
//         resolve STARTS at the embed page, so parseHhDetail
//         makes the opened episode's play target the embed URL
//         (its iframe is in the detail page); sibling episodes
//         keep watch-page targets and degrade to the v1.0.0
//         WebView hand-off, as does ANY PoW failure — never
//         worse than v1.0.0.
//   hanime.tv is EXCLUDED from v1 by the hunt's verdict: playback is
//   gated (WASM-signed handshake for <=720p, premium login for 1080p).
//
// Search fan-out: the app contract fetches ONE search URL per page
// (MovieService.search -> getUrlSearch(keyword, filters{page})), so
// true parallel fan-out is impossible in-contract. v1 rotates by
// page: odd pages serve hstream results, even pages serve haho
// results — each page block is one source's grouped results, item
// ids are source-prefixed, and one source failing yields an empty
// page without touching the other source's pages.
// =============================================================================

function getManifest() {
    return JSON.stringify({
        "id": "hentaihub",
        "name": "Hentai Hub",
        "version": "1.0.2",
        "baseUrl": "https://hstream.moe",
        "iconUrl": "https://hstream.moe/images/cropped-HS-1-270x270.webp",
        "isEnabled": true,
        "isAdult": true,
        "type": "MOVIE",
        "layoutType": "HORIZONTAL"
    });
}

function getHomeSections() {
    // One labelled rail per source, plus one big-genre rail each.
    // v1.0.1 (owner request): a few extra genre rails WITH posters
    // for browsing, appended after the original five. Only the two
    // poster-ful sources get genre rails — haho's list pages serve
    // no poster data at all (see the haho poster investigation in
    // the build report), so haho genre rails would render as empty
    // placeholders; haho keeps its latest rail only. Each added
    // genre was verified live through this plugin before inclusion
    // (hs ntr/milf: 25 items, 25 posters; hh milf/vanilla: 40
    // items, 40 posters, page 1).
    return JSON.stringify([
        { slug: 'hs:latest', title: 'HStream — Mới nhất', type: 'Horizontal', path: '' },
        { slug: 'haho:latest', title: 'HAHO — Mới cập nhật', type: 'Horizontal', path: '' },
        { slug: 'hs:tag:uncensored', title: 'HStream — Uncensored', type: 'Horizontal', path: '' },
        { slug: 'hh:g:uncensored', title: 'HentaiHaven — Uncensored', type: 'Horizontal', path: '' },
        { slug: 'hh:latest', title: 'HentaiHaven — Mới nhất', type: 'Grid', path: '' },
        { slug: 'hs:tag:ntr', title: 'HStream — NTR', type: 'Horizontal', path: '' },
        { slug: 'hs:tag:milf', title: 'HStream — Milf', type: 'Horizontal', path: '' },
        { slug: 'hh:g:milf', title: 'HentaiHaven — Milf', type: 'Horizontal', path: '' },
        { slug: 'hh:g:vanilla', title: 'HentaiHaven — Vanilla', type: 'Horizontal', path: '' }
    ]);
}

// Source-scoped categories. Slugs carry the adapter prefix; genre
// taxonomies genuinely differ per source, so nothing is merged.
var HS_TAGS = ['ahegao', 'big-boobs', 'bdsm', 'censored', 'creampie', 'elf', 'fantasy', 'maid', 'milf', 'mind-control', 'ntr', 'public-sex', 'rape', 'school-girl', 'succubus', 'tentacle', 'uncensored', 'virgin'];
// haho genre ids are opaque; pairs measured on haho.moe/genre (the
// index paginates alphabetically — these are the A-page entries plus
// the ones a user is most likely to want; the full set is reachable
// via parseCategoriesResponse on the same index).
var HAHO_GENRES = [
    ['fzbv2fbz', '3D CG animation'], ['zdwxopnb', 'action'], ['ukgtxrki', 'adventure'],
    ['5wqtovj0', 'ahegao'], ['t0xpmr7i', 'alien'], ['04mvuqdv', 'alien invasion'],
    ['iy6puzyi', 'all-girls school'], ['tcqzrpn8', 'age difference romance'],
    ['hl5ctn5a', 'absurdist humour'], ['ymlxgyrm', 'Akihabara'], ['f67vdqka', 'alcohol'],
    ['bc1dtix2', 'adults are useless'], ['bpgnzedz', 'amnesia']
];
var HH_GENRES = ['ahegao', 'anal', 'bdsm', 'big-boobs', 'blow-job', 'censored', 'cosplay', 'creampie', 'fantasy', 'futanari', 'gangbang', 'harem', 'incest', 'loli', 'maid', 'milf', 'mind-break', 'mind-control', 'monster', 'ntr', 'nurse', 'orgy', 'plot', 'pov', 'pregnant', 'public-sex', 'rape', 'school-girl', 'tentacle', 'threesome', 'uncensored', 'vanilla', 'virgin', 'yuri'];

function titleCaseSlug(slug) {
    return slug.split('-').map(function (w) {
        return w ? w.charAt(0).toUpperCase() + w.slice(1) : w;
    }).join(' ');
}

function getPrimaryCategories() {
    var cats = [{ name: 'Tất cả — HStream', slug: 'hs:latest' }, { name: 'Tất cả — HAHO', slug: 'haho:latest' }, { name: 'Tất cả — HentaiHaven', slug: 'hh:latest' }];
    HS_TAGS.forEach(function (t) { cats.push({ name: 'HS · ' + titleCaseSlug(t), slug: 'hs:tag:' + t }); });
    HAHO_GENRES.forEach(function (g) { cats.push({ name: 'HAHO · ' + g[1], slug: 'haho:g:' + g[0] }); });
    HH_GENRES.forEach(function (t) { cats.push({ name: 'HH · ' + titleCaseSlug(t), slug: 'hh:g:' + t }); });
    return JSON.stringify(cats);
}

function getFilterConfig() {
    var cats = [];
    HS_TAGS.forEach(function (t) { cats.push({ name: 'HS · ' + titleCaseSlug(t), value: 'hs:tag:' + t }); });
    HAHO_GENRES.forEach(function (g) { cats.push({ name: 'HAHO · ' + g[1], value: 'haho:g:' + g[0] }); });
    HH_GENRES.forEach(function (t) { cats.push({ name: 'HH · ' + titleCaseSlug(t), value: 'hh:g:' + t }); });
    return JSON.stringify({
        sort: [{ name: 'Mới nhất', value: 'latest' }],
        category: cats
    });
}

// =============================================================================
// URL GENERATION
// =============================================================================

var HS = "https://hstream.moe";
var HAHO = "https://haho.moe";
var HH = "https://hentaihaven.co";
var DESKTOP_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

function listUrlFor(slug, page) {
    if (!slug || slug === 'hs:latest') return HS + "/search?order=recently-released&page=" + page;
    if (slug.indexOf('hs:tag:') === 0) return HS + "/search?tags%5B0%5D=" + encodeURIComponent(slug.slice(7)) + "&page=" + page;
    if (slug === 'haho:latest') {
        // The series index for every page. (The homepage's episode
        // rail features only a handful of series, and haho's series
        // lists serve no poster images at all — measured; posters
        // come from each series' detail page.)
        return HAHO + "/anime?page=" + page;
    }
    if (slug.indexOf('haho:g:') === 0) return HAHO + "/genre/" + slug.slice(7) + (page > 1 ? "?page=" + page : "");
    if (slug === 'hh:latest') return HH + "/?page=" + page;
    if (slug.indexOf('hh:g:') === 0) return HH + "/genre/" + slug.slice(5) + "/?page=" + page;
    if (slug.indexOf('hh:tag:') === 0) return HH + "/tag/" + slug.slice(7) + "/?page=" + page;
    return HS + "/search?order=recently-released&page=" + page;
}

// Request stash for LIST pagination (round-2 list-pagination
// fix): getUrlList receives the requested page (filters.page),
// parseListResponse does not. The app serializes getUrlList ->
// fetch -> parseListResponse per plugin (the same pairing the
// search stash relies on), so parseListResponse may use this as
// the currentPage FALLBACK — a verified in-markup signal always
// wins over it (see listCurrentPage).
var _listStash = null;

function listSourceOf(slug) {
    if (!slug) return "hs";
    if (slug.indexOf("haho:") === 0) return "haho";
    if (slug.indexOf("hh:") === 0) return "hh";
    return "hs";
}

function getUrlList(slug, filtersJson) {
    var filters = JSON.parse(filtersJson || "{}");
    var page = filters.page || 1;
    var effective = filters.category ? filters.category : slug;
    _listStash = { source: listSourceOf(effective), slug: effective || "", page: parseInt(page) || 1 };
    return listUrlFor(effective, page);
}

// Routing stash for the search pagination translation (see
// getUrlSearch / parseSearchResponse). One entry, overwritten by
// every getUrlSearch call; read once by the matching parse.
var _searchStash = null;

// Per-source set of item ids already served in the current
// search — haho's end-of-results signal is re-serving its last
// page, which only a seen-set can detect (see parseSearchResponse).
var _searchSeen = { hs: {}, haho: {} };

function getUrlSearch(keyword, filtersJson) {
    var filters = JSON.parse(filtersJson || "{}");
    var page = filters.page || 1;
    // Page rotation fan-out (see header): odd pages = hstream,
    // even pages = haho. hh has no working server search (measured)
    // and parseSearchResponse cannot see the keyword, so hh is not
    // part of search v1.
    // Stash the routing for parseSearchResponse's pagination
    // translation (M-1 fix, review round 2): the engine's JSContext
    // persists per plugin instance, and the app fetches+parses one
    // search page at a time, so this pairing is reliable.
    _searchStash = { appPage: page, source: (page % 2 === 1) ? "hs" : "haho" };
    if (page % 2 === 1) {
        return HS + "/search?search=" + encodeURIComponent(keyword) + "&page=" + Math.ceil(page / 2);
    }
    return HAHO + "/anime?q=" + encodeURIComponent(keyword) + "&page=" + (page / 2);
}

function getUrlDetail(id) {
    if (!id) return "";
    if (id.indexOf("http") === 0) return id;
    if (id.indexOf("hs:") === 0) return HS + "/hentai/" + id.slice(3);
    if (id.indexOf("haho:") === 0) return HAHO + "/anime/" + id.slice(5);
    if (id.indexOf("hh:") === 0) return HH + "/watch/" + id.slice(3) + "/";
    return id;
}

function getUrlCategories() { return HAHO + "/genre"; }
function getUrlCountries() { return ""; }
function getUrlYears() { return ""; }

// =============================================================================
// UTILS
// =============================================================================

var PluginUtils = {
    cleanText: function (text) {
        if (!text) return "";
        return text.replace(/<[^>]*>/g, "")
            .replace(/&amp;/g, "&")
            .replace(/&quot;/g, '"')
            .replace(/&#039;/g, "'")
            .replace(/&#39;/g, "'")
            .replace(/&lt;/g, "<")
            .replace(/&gt;/g, ">")
            .replace(/\s+/g, " ")
            .trim();
    },
    decodeEntities: function (text) {
        if (!text) return "";
        return text.replace(/&amp;/g, "&")
            .replace(/&quot;/g, '"')
            .replace(/&#039;/g, "'")
            .replace(/&#39;/g, "'")
            .replace(/&lt;/g, "<")
            .replace(/&gt;/g, ">");
    },
    absolutize: function (url, base) {
        if (!url) return "";
        url = PluginUtils.decodeEntities(url);
        if (url.indexOf("http") === 0) return url;
        if (url.indexOf("//") === 0) return "https:" + url;
        if (url.charAt(0) === "/") return base + url;
        return base + "/" + url;
    },
    // Pagination heuristic shared by all three adapters: honour an
    // explicit "active page" marker when the markup carries one,
    // and take totalPages from the largest ?page= link on the page.
    pagination: function (html, itemCount) {
        var currentPage = 1;
        var active = html.match(/class="[^"]*(?:active|current)[^"]*"[^>]*>\s*(?:<a[^>]*>)?\s*(\d+)/i);
        if (active) currentPage = parseInt(active[1]);
        var totalPages = currentPage;
        var re = /[?&]page=(\d+)/g, m;
        while ((m = re.exec(html)) !== null) {
            var p = parseInt(m[1]);
            if (p > totalPages) totalPages = p;
        }
        if (totalPages === currentPage && itemCount >= 20) totalPages = currentPage + 1;
        return { currentPage: currentPage, totalPages: totalPages, totalItems: itemCount * totalPages, itemsPerPage: itemCount };
    },
    // In-markup current-page signals for LIST pages, per source
    // (round-2 list-pagination fix; both measured live 2026-11-18):
    // hs pages are Livewire — the component snapshot embeds its
    // paginator state as &quot;paginators&quot;:[{&quot;page&quot;:N
    // (N equalled the requested page on latest pages 1, 2, 3, 10,
    // 30 and on a tag page; the raw unescaped shape is matched as
    // a fallback). haho pages carry a Laravel pager whose current
    // page is a <span> inside <li class="page-item active"
    // aria-current="page">, NOT a link (N equalled the requested
    // page on pages 1, 2, 3, 59). The (active|current) marker
    // regex in pagination() above misfires on hs (reports 2 on
    // page 1 — it locks onto the page-2 pager button — then 1 on
    // later pages) and never matches haho's span at all; that is
    // what froze CategoryView's adopted page counter. Returns 0
    // when the source's signal is absent.
    markupCurrentPage: function (source, html) {
        if (!html) return 0;
        var m = null;
        if (source === "hs") {
            m = html.match(/paginators&quot;:\[\{&quot;page&quot;:(\d+)/) ||
                html.match(/"paginators":\[\{"page":(\d+)/);
        } else if (source === "haho") {
            m = html.match(/aria-current="page"[^>]*>\s*<span[^>]*>\s*(\d+)/i);
        }
        return m ? (parseInt(m[1]) || 0) : 0;
    }
};

// LIST currentPage resolution (round-2 fix): the app adopts the
// reported currentPage as its own page counter (CategoryView:
// page = result.pagination.currentPage after every fetch), so it
// must be the page that was actually served — a wrong value makes
// loadMore re-fetch the same page forever and truncates the
// catalogue. Priority: (1) the source's verified in-markup signal
// (PluginUtils.markupCurrentPage); (2) the getUrlList request
// stash, when its source matches the parsed page's source (the
// app serializes fetch->parse per plugin, so the pairing is
// reliable, and a mismatch simply ignores the stash); (3) the old
// marker result from PluginUtils.pagination — the documented
// floor when both signals are absent.
function listCurrentPage(source, html, markerPage) {
    var markup = PluginUtils.markupCurrentPage(source, html);
    if (markup > 0) return markup;
    if (_listStash && _listStash.source === source && _listStash.page > 0) return _listStash.page;
    return markerPage;
}

function sniffSource(html) {
    if (!html) return "";
    if (html.indexOf('"stream_url"') !== -1 || html.indexOf('id="e_id"') !== -1 || html.indexOf('hstream.moe/hentai/') !== -1) return "hs";
    if (html.indexOf('a_item') !== -1 && html.indexOf('/watch/') !== -1) return "hh";
    if (html.indexOf('hentaihaven') !== -1) return "hh";
    if (html.indexOf('nhplayer.com') !== -1) return "hh";
    if (html.indexOf('haho.moe') !== -1 || html.indexOf('filegasm') !== -1) return "haho";
    return "";
}

// =============================================================================
// HSTREAM (hs:) — list/search parser
// Cards: <div class="episode-item"> wrapping <a href="ABSOLUTE/hentai/
// <slug>"> with cover <img src="/images/hentai/<stem>/cover-ep-N.webp"
// alt="<Title> - <ep>">, a quality badge and an <h3> title.
// =============================================================================

function parseHsList(html) {
    var items = [];
    var seen = {};
    var re = /<a[^>]+href="https:\/\/hstream\.moe\/hentai\/([a-z0-9-]+)"[^>]*>([\s\S]*?)<\/a>/gi;
    var card;
    while ((card = re.exec(html)) !== null) {
        var slug = card[1];
        if (seen[slug]) continue;
        var block = card[2];
        var img = block.match(/<img[^>]+src="([^"]+)"/i);
        var poster = img ? PluginUtils.absolutize(img[1], HS) : "";
        var title = "";
        var h3 = block.match(/<h3[^>]*>([\s\S]*?)<\/h3>/i);
        if (h3) title = PluginUtils.cleanText(h3[1]);
        if (!title && img) {
            var alt = block.match(/<img[^>]+alt="([^"]*)"/i);
            if (alt) title = PluginUtils.cleanText(alt[1]);
        }
        if (!title) title = slug;
        var badge = block.match(/>([^<]*?(?:4K|FHD|HD|48fps)[^<]*?)</i);
        var quality = badge ? PluginUtils.cleanText(badge[1]) : "HD";
        var epNum = slug.match(/-(\d+)$/);
        seen[slug] = true;
        items.push({
            id: "hs:" + slug,
            title: title,
            posterUrl: poster,
            backdropUrl: poster,
            description: "",
            episode_current: epNum ? ("Episode " + epNum[1]) : "",
            quality: quality,
            lang: "Engsub"
        });
    }
    // Pagination (round-2 fix): currentPage from the verified
    // signal chain (see listCurrentPage). totalPages is a
    // LOOKAHEAD, mirroring the search design: hstream's markup
    // carries no page-count links at all and the catalogue runs
    // deep (full 25-item pages measured at least to p30; p100 is
    // empty), so a FULL page (25 items — the site's page size)
    // reports currentPage + 1, and the first partial or empty
    // page reports currentPage — exactly where the app stops.
    var base = PluginUtils.pagination(html, items.length);
    var cp = listCurrentPage("hs", html, base.currentPage);
    var totalPages = items.length >= 25 ? cp + 1 : cp;
    return { items: items, pagination: { currentPage: cp, totalPages: totalPages, totalItems: items.length * totalPages, itemsPerPage: items.length } };
}

// =============================================================================
// HAHO (haho:) — list/search parser
// Two card shapes:
//  A) episode rail cards (homepage / rails): <li class="video-N">
//     <a href=".../anime/<seriesId>/<n>?v=<vid>"> with cover <img>,
//     .anime-title (series) and .episode-title. Mapped to the SERIES.
//  B) series cards (/anime, /genre/<id>, search): <a href=".../anime/
//     <id>" title="<Title>" data-content="<desc>"> with .year etc.
//     These pages carry no poster images (measured) — posterUrl is
//     empty; the detail page supplies the real poster via og:image.
// =============================================================================

function parseHahoList(html) {
    var items = [];
    var seen = {};

    // Series cards are the page content — they win whenever present.
    var serRe = /<a[^>]+href="https:\/\/haho\.moe\/anime\/([a-z0-9]+)"([^>]*)>([\s\S]*?)<\/a>/gi;
    var card;
    while ((card = serRe.exec(html)) !== null) {
        var id2 = card[1];
        if (seen[id2]) continue;
        var attrs = card[2];
        var inner = card[3];
        var tMatch = attrs.match(/title="([^"]+)"/i);
        var title2 = tMatch ? PluginUtils.decodeEntities(tMatch[1]) : "";
        if (!title2) {
            var span = inner.match(/class="text-primary"[^>]*>([\s\S]*?)<\/span>/i);
            if (span) title2 = PluginUtils.cleanText(span[1]);
        }
        if (!title2) continue;
        var dMatch = attrs.match(/data-content="([^"]*)"/i);
        var yearMatch = inner.match(/class="year"[^>]*>([\s\S]*?)<\/div>/i);
        var year = yearMatch ? parseInt(PluginUtils.cleanText(yearMatch[1]).replace(/\D/g, "")) || 0 : 0;
        seen[id2] = true;
        items.push({
            id: "haho:" + id2,
            title: title2,
            posterUrl: "",
            backdropUrl: "",
            description: dMatch ? PluginUtils.decodeEntities(dMatch[1]).substring(0, 300) : "",
            year: year,
            quality: "HD",
            lang: "Engsub"
        });
    }

    // Fallback: episode rail cards (the only shape on pages without
    // series cards), mapped to their series.
    if (items.length === 0) {
        var railRe = /<a[^>]+href="https:\/\/haho\.moe\/anime\/([a-z0-9]+)\/\d+\?v=[a-z0-9]+"[^>]*>([\s\S]*?)<\/a>/gi;
        while ((card = railRe.exec(html)) !== null) {
            var sid = card[1];
            if (seen[sid]) continue;
            var block = card[2];
            var img = block.match(/<img[^>]+src="([^"]+)"/i);
            var series = block.match(/class="anime-title"[^>]*>([\s\S]*?)<\/div>/i);
            var ep = block.match(/class="episode-title"[^>]*>([\s\S]*?)<\/div>/i);
            var title = series ? PluginUtils.cleanText(series[1]) : "";
            if (!title) continue;
            seen[sid] = true;
            items.push({
                id: "haho:" + sid,
                title: title,
                posterUrl: img ? img[1] : "",
                backdropUrl: img ? img[1] : "",
                description: "",
                episode_current: ep ? PluginUtils.cleanText(ep[1]) : "",
                quality: "HD",
                lang: "Engsub"
            });
        }
    }

    // Pagination (round-2 fix): currentPage from the verified
    // signal chain (see listCurrentPage) — the old marker never
    // matched haho's span-shaped current page and reported 1 on
    // every page. totalPages stays LINK-DERIVED via the shared
    // helper (the pager links are real: max ?page= is 59 on
    // /anime and p59 serves the final 12 items — 58x24+12 =
    // 1,416 series), floored at the resolved currentPage.
    var base = PluginUtils.pagination(html, items.length);
    var cp = listCurrentPage("haho", html, base.currentPage);
    var totalPages = Math.max(base.totalPages, cp);
    return { items: items, pagination: { currentPage: cp, totalPages: totalPages, totalItems: items.length * totalPages, itemsPerPage: items.length } };
}

// =============================================================================
// HENTAIHAVEN (hh:) — list parser
// Next.js flight payload: cards are escaped JSON — unescape first,
// then each "a_item" chunk carries href /watch/<slug>/, the cover
// "src":"/uploads/...", an "EP N" badge and the video_title text.
// A plain-anchor fallback covers a WebView-rendered DOM variant.
// =============================================================================

function parseHhList(html) {
    var items = [];
    var seen = {};
    var u = html.replace(/\\"/g, '"').replace(/\\\//g, '/');
    var chunks = u.split('"className":"a_item"');
    for (var i = 1; i < chunks.length; i++) {
        var chunk = chunks[i].substring(0, 1600);
        var href = chunk.match(/"href":"(\/watch\/([a-z0-9-]+)\/)"/);
        if (!href) continue;
        var slug = href[2];
        if (seen[slug]) continue;
        var src = chunk.match(/"src":"([^"]+)"/);
        var titleM = chunk.match(/"className":"video_title"[^[]*"children":"([^"]+)"/) ||
            chunk.match(/"alt":"([^"]+)"/);
        var badge = chunk.match(/"className":"card_badge","children":"([^"]+)"/);
        var poster = src ? PluginUtils.absolutize(src[1], HH) : "";
        seen[slug] = true;
        items.push({
            id: "hh:" + slug,
            title: titleM ? PluginUtils.decodeEntities(titleM[1]) : slug,
            posterUrl: poster,
            backdropUrl: poster,
            description: "",
            episode_current: badge ? badge[1] : "",
            quality: "HD",
            lang: "Engsub"
        });
    }

    if (items.length === 0) {
        var re = /<a[^>]+href="(\/watch\/([a-z0-9-]+)\/)"[^>]*>([\s\S]*?)<\/a>/gi;
        var card;
        while ((card = re.exec(html)) !== null) {
            if (seen[card[2]]) continue;
            var img = card[3].match(/<img[^>]+src="([^"]+)"/i);
            var alt = card[3].match(/<img[^>]+alt="([^"]*)"/i);
            seen[card[2]] = true;
            items.push({
                id: "hh:" + card[2],
                title: alt ? PluginUtils.decodeEntities(alt[1]) : card[2],
                posterUrl: img ? PluginUtils.absolutize(img[1], HH) : "",
                backdropUrl: img ? PluginUtils.absolutize(img[1], HH) : "",
                description: "",
                episode_current: "",
                quality: "HD",
                lang: "Engsub"
            });
        }
    }

    // Pagination (round-2 M-1 fix): currentPage stays the shared
    // helper's marker value (verified exact on hh pages, 1..85).
    // totalPages must NOT keep the helper's +1 lookahead for hh:
    // this site's pager enumerates the true page range in real
    // ?page= links (max ?page= = 85 on latest, present on every
    // page), so the link-derived total is authoritative — and the
    // site CLAMPS out-of-range pages to the last page, so the
    // lookahead's cp+1 on the true last page (35 items on latest
    // p85, 32 on genre threesome p4 — both >= the helper's
    // 20-item threshold) re-served the last page verbatim, the
    // plugin re-reported cp=last / tp=last+1, and CategoryView
    // (which adopts the reported currentPage) looped on the
    // final page forever with 0 fresh items per fetch. Recompute
    // the total from the page links exactly as the helper does
    // before its lookahead, floored at cp — the same override
    // shape hs and haho already apply to the helper's total.
    var base = PluginUtils.pagination(html, items.length);
    var cp = base.currentPage;
    var totalPages = cp;
    var pageRe = /[?&]page=(\d+)/g, pm;
    while ((pm = pageRe.exec(html)) !== null) {
        var lp = parseInt(pm[1]);
        if (lp > totalPages) totalPages = lp;
    }
    return { items: items, pagination: { currentPage: cp, totalPages: totalPages, totalItems: items.length * totalPages, itemsPerPage: items.length } };
}

function parseListResponse(html) {
    try {
        var src = sniffSource(html);
        var result;
        if (src === "haho") result = parseHahoList(html);
        else if (src === "hh") result = parseHhList(html);
        else result = parseHsList(html);
        return JSON.stringify(result);
    } catch (e) {
        return JSON.stringify({ items: [], pagination: { currentPage: 1, totalPages: 1 } });
    }
}

function parseSearchResponse(html) {
    // One fetched page belongs to exactly one source (rotation in
    // getUrlSearch); the markup sniff routes it. hh never appears
    // here in v1 (no server search — see header).
    var raw = parseListResponse(html);
    // M-1 fix (review round 2, measured): the parsers report
    // pagination in SOURCE page units, but the app pages in
    // ROTATION units (its page 1 = hs 1, page 2 = haho 1, page 3 =
    // hs 2…) and stops at the largest totalPages ever reported —
    // untranslated totals silently capped deep searches at about
    // half the deeper source's depth (~74% of one measured result
    // set unreachable). The sources' own totals are also unreliable
    // in markup (haho search pages expose no page-count links at
    // all; hstream's active-page marker misfires), so the
    // translation does not trust them. Measured end-signals
    // differ per source: hstream ends on an EMPTY page; haho ends
    // by RE-SERVING its last page forever (page 5+ of one measured
    // search repeated page 4's 4 items verbatim). The only signal
    // that covers both: a page contributes only while it brings at
    // least one FRESH item id (tracked per source in _searchSeen,
    // reset on that source's first page of a search). Rule, in app
    // units: fresh items -> report appPage + 2 (this source fills
    // its next rotation slot too); empty or all-duplicate page ->
    // report appPage (this source is done) — EXCEPT on app page 1,
    // where a non-fresh page still reports 2 (M-2 fix): the app
    // fetches while page < the max reported totalPages, so a
    // "done" report of 1 on page 1 would close the search before
    // haho ever gets its first turn on page 2 (measured: a keyword
    // living only in haho returned an EMPTY search). The app's running max
    // then tracks the true combined depth, and paging stops once
    // both sources have answered done on consecutive turns.
    try {
        var obj = JSON.parse(raw);
        if (!obj || !obj.pagination) return raw;
        var src = sniffSource(html);
        var appPage = 0, srcKey = "";
        if (_searchStash && (src === "" || src === _searchStash.source)) {
            appPage = _searchStash.appPage;
            srcKey = _searchStash.source;
        } else if (src === "hs" || src === "haho") {
            // Stale/missing stash (overlapping searches): fall back
            // to the page's own reported position, best effort.
            var cp = obj.pagination.currentPage || 1;
            srcKey = src;
            appPage = (src === "hs") ? (2 * cp - 1) : (2 * cp);
        } else {
            return raw;
        }
        if (appPage <= 2) _searchSeen[srcKey] = {};
        var seen = _searchSeen[srcKey] || (_searchSeen[srcKey] = {});
        var fresh = 0, i, id;
        for (i = 0; i < obj.items.length; i++) {
            id = obj.items[i] && obj.items[i].id;
            if (id && !seen[id]) { seen[id] = 1; fresh++; }
        }
        obj.pagination.currentPage = appPage;
        obj.pagination.totalPages = fresh > 0 ? appPage + 2 : Math.max(appPage, 2);
        // totalItems (m-1 fix): the true count of items THIS
        // source has served so far in the current search — the
        // size of its _searchSeen set, just updated above with
        // this page's ids — not itemsPerPage (source units)
        // multiplied by totalPages (app units).
        obj.pagination.totalItems = Object.keys(seen).length;
        return JSON.stringify(obj);
    } catch (e) {
        return raw;
    }
}

// =============================================================================
// DETAIL (parseMovieDetail) — one adapter per source
// =============================================================================

function hsStem(slug) {
    var m = slug.match(/^(.*?)-\d+$/);
    return m ? m[1] : slug;
}

function parseHsDetail(html, url) {
    var slugM = (url || "").match(/\/hentai\/([a-z0-9-]+)/i);
    var slug = slugM ? slugM[1] : "";
    var title = "";
    var ogTitle = html.match(/property="og:title" content="([^"]+)"/i);
    if (ogTitle) {
        title = PluginUtils.decodeEntities(ogTitle[1])
            .replace(/\s*\|\s*hstream\.moe\s*$/i, "")
            .replace(/\s*-\s*English Subbed.*$/i, "")
            .trim();
    }
    if (!title) {
        var h1 = html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/i);
        if (h1) title = PluginUtils.cleanText(h1[1]);
    }
    var poster = "";
    var ogImg = html.match(/property="og:image" content="([^"]+)"/i);
    if (ogImg) poster = PluginUtils.absolutize(ogImg[1], HS);
    var desc = "";
    var descM = html.match(/name="description" content="([^"]*)"/i);
    if (descM) desc = PluginUtils.decodeEntities(descM[1]).substring(0, 700);

    // Tags: the page's own /search?tags[0]=<tag> links.
    var tags = [];
    var tagRe = /tags%5B0%5D=([a-z0-9-]+)/gi, tm;
    while ((tm = tagRe.exec(html)) !== null) {
        var t = tm[1];
        if (tags.indexOf(t) === -1 && !/^(4k|48fps|4k-48fps)$/.test(t)) tags.push(t);
    }

    // Episodes: sibling /hentai/<stem>-<n> links + this episode.
    var stem = hsStem(slug);
    var epMap = {};
    var epRe = new RegExp('href="https://hstream\\.moe/hentai/(' + stem.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '-(\\d+))"', 'gi');
    var em;
    while ((em = epRe.exec(html)) !== null) epMap[em[1]] = parseInt(em[2]);
    if (slug) {
        var selfNum = slug.match(/-(\d+)$/);
        epMap[slug] = selfNum ? parseInt(selfNum[1]) : 1;
    }
    var episodes = Object.keys(epMap).map(function (s) {
        return { id: HS + "/hentai/" + s, name: "Episode " + epMap[s], slug: s, num: epMap[s] };
    }).sort(function (a, b) { return a.num - b.num; });
    episodes.forEach(function (e) { delete e.num; });
    if (episodes.length === 0 && slug) {
        episodes = [{ id: HS + "/hentai/" + slug, name: "Episode 1", slug: slug }];
    }

    return {
        id: "hs:" + slug,
        title: title || slug,
        posterUrl: poster,
        backdropUrl: poster,
        description: desc,
        servers: [{ name: "HStream", episodes: episodes }],
        category: tags.map(titleCaseSlug).join(", "),
        quality: "HD",
        lang: "Engsub",
        status: ""
    };
}

function parseHahoDetail(html, url) {
    var idM = (url || "").match(/\/anime\/([a-z0-9]+)\/?(?:[?#]|$)/i) || (url || "").match(/\/anime\/([a-z0-9]+)/i);
    var sid = idM ? idM[1] : "";
    var title = "";
    var ogTitle = html.match(/property="og:title" content="([^"]+)"/i);
    if (ogTitle) title = PluginUtils.decodeEntities(ogTitle[1]).replace(/\s*—\s*Hentai AHO Streaming\s*$/i, "").trim();
    if (!title) {
        var h1 = html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/i);
        if (h1) title = PluginUtils.cleanText(h1[1]);
    }
    var poster = "";
    var ogImg = html.match(/property="og:image" content="([^"]+)"/i);
    if (ogImg) poster = ogImg[1];
    var desc = "";
    var descM = html.match(/property="og:description" content="([^"]*)"/i) || html.match(/name="description" content="([^"]*)"/i);
    if (descM) desc = PluginUtils.decodeEntities(descM[1]).substring(0, 700);

    // Genres: this page's /genre/<id> anchors carry title attributes.
    var genres = [];
    var gRe = /href="https:\/\/haho\.moe\/genre\/[a-z0-9]+"[^>]*title="([^"]+)"/gi, gm;
    while ((gm = gRe.exec(html)) !== null) {
        var gname = PluginUtils.decodeEntities(gm[1]);
        if (genres.indexOf(gname) === -1) genres.push(gname);
    }

    // Episodes: /anime/<id>/<n> links (with or without ?v=).
    var epMap = {};
    if (sid) {
        var epRe = new RegExp('href="https://haho\\.moe/anime/' + sid + '/(\\d+)', 'gi');
        var em;
        while ((em = epRe.exec(html)) !== null) epMap[em[1]] = parseInt(em[1]);
    }
    var episodes = Object.keys(epMap).map(function (n) {
        return { id: HAHO + "/anime/" + sid + "/" + n, name: "Episode " + n, slug: "ep-" + n, num: parseInt(n) };
    }).sort(function (a, b) { return a.num - b.num; });
    episodes.forEach(function (e) { delete e.num; });

    return {
        id: "haho:" + sid,
        title: title || sid,
        posterUrl: poster,
        backdropUrl: poster,
        description: desc,
        servers: [{ name: "HAHO", episodes: episodes }],
        category: genres.join(", "),
        quality: "HD",
        lang: "Engsub",
        status: ""
    };
}

function parseHhDetail(html, url) {
    var slugM = (url || "").match(/\/watch\/([a-z0-9-]+)\/?/i);
    var slug = slugM ? slugM[1] : "";
    var title = "";
    var ogTitle = html.match(/property="og:title" content="([^"]+)"/i);
    if (ogTitle) title = PluginUtils.decodeEntities(ogTitle[1]).replace(/\s*\|\s*Hentai Haven\s*$/i, "").trim();
    var poster = "";
    var ogImg = html.match(/property="og:image" content="([^"]+)"/i);
    if (ogImg) poster = PluginUtils.absolutize(ogImg[1], HH);
    var desc = "";
    var descM = html.match(/property="og:description" content="([^"]*)"/i);
    if (descM) {
        desc = PluginUtils.decodeEntities(descM[1]);
        if (/^Watch .* on Hentai Haven\./.test(desc)) desc = "";
        desc = desc.substring(0, 700);
    }

    // Episodes: same-stem /watch/<stem>-episode-<n>/ links. The page
    // is a Next.js payload, so unescape before scanning hrefs.
    var u = html.replace(/\\"/g, '"').replace(/\\\//g, '/');
    var stemM = slug.match(/^(.*?)-episode-\d+$/i);
    var stem = stemM ? stemM[1] : slug;
    var epMap = {};
    var epRe = new RegExp('href="(/watch/(' + stem.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '-episode-(\\d+))/?)"', 'gi');
    var em;
    while ((em = epRe.exec(u)) !== null) epMap[em[2]] = parseInt(em[3]);
    if (slug) {
        var selfNum = slug.match(/-episode-(\d+)$/i);
        epMap[slug] = selfNum ? parseInt(selfNum[1]) : 1;
    }
    var episodes = Object.keys(epMap).map(function (s) {
        return { id: HH + "/watch/" + s + "/", name: "Episode " + epMap[s], slug: s, num: epMap[s] };
    }).sort(function (a, b) { return a.num - b.num; });
    episodes.forEach(function (e) { delete e.num; });
    if (episodes.length === 0 && slug) {
        episodes = [{ id: HH + "/watch/" + slug + "/", name: "Episode 1", slug: slug }];
    }

    // The episode this page belongs to: its own nhplayer iframe is
    // in this page, so its play target can start one hop later —
    // at the embed page. The app's resolver budget (initial fetch
    // + 4 parses) fits the full proof-of-work chain only from
    // there; sibling episodes keep their watch-page targets and
    // degrade to the WebView hand-off (see hhResolveStep).
    var iframeUrl = hhIframeUrl(html);
    if (iframeUrl) {
        for (var ei = 0; ei < episodes.length; ei++) {
            if (episodes[ei].slug === slug) { episodes[ei].id = iframeUrl; break; }
        }
    }

    return {
        id: "hh:" + slug,
        title: title || slug,
        posterUrl: poster,
        backdropUrl: poster,
        description: desc,
        servers: [{ name: "HentaiHaven", episodes: episodes }],
        category: "",
        quality: "HD",
        lang: "Engsub",
        status: ""
    };
}

function parseMovieDetail(html, url) {
    try {
        var src = sniffSource(html);
        var detail;
        if (src === "haho" || (url || "").indexOf("haho.moe") !== -1) detail = parseHahoDetail(html, url);
        else if (src === "hh" || (url || "").indexOf("hentaihaven") !== -1) detail = parseHhDetail(html, url);
        else detail = parseHsDetail(html, url);
        return JSON.stringify(detail);
    } catch (e) {
        return "null";
    }
}

// =============================================================================
// STREAM RESOLUTION
// Resolver order in the app: parseEmbedResponse is tried FIRST on
// every hop, parseDetailResponse second. Both dispatch by content.
// =============================================================================

// hstream player/api JSON -> direct MP4 + subtitles (verified chain).
function hsStreamFromApi(text) {
    try {
        var data = JSON.parse(text);
        if (!data || !data.stream_url) return null;
        var domains = (data.stream_domains && data.stream_domains.length ? data.stream_domains : data.asia_stream_domains) || [];
        if (!domains.length) return null;
        var base = domains[0] + "/" + data.stream_url;
        return {
            url: base + "/x264.720p.mp4",
            isEmbed: false,
            headers: { "Referer": HS + "/", "User-Agent": DESKTOP_UA },
            subtitles: [
                { lang: "en", url: base + "/eng.vtt", label: "English" },
                { lang: "en", url: base + "/eng.ass", label: "English (ASS)" }
            ]
        };
    } catch (e) { return null; }
}

// hstream detail page -> POST config for /player/api. The session
// CSRF token is embedded in the page (Livewire data-csrf; a meta
// csrf-token is the fallback shape). Measured: the token works BOTH
// as the X-CSRF-TOKEN header and as _token in the JSON body (200);
// as X-XSRF-TOKEN it 419s — that header is reserved for the cookie
// value, which a plugin cannot read. The app's POST rides the shared
// cookie jar, so the session cookie is present either way.
function hsPostConfig(html, url) {
    var eid = html.match(/id="e_id"[^>]*value="(\d+)"/i) || html.match(/value="(\d+)"[^>]*id="e_id"/i);
    if (!eid) return null;
    var tok = html.match(/data-csrf="([^"]+)"/i) ||
        html.match(/<meta[^>]+name="csrf-token"[^>]+content="([^"]+)"/i) ||
        html.match(/<meta[^>]+content="([^"]+)"[^>]+name="csrf-token"/i);
    var token = tok ? tok[1] : "";
    var body = JSON.stringify({ episode_id: parseInt(eid[1]), _token: token });
    var headers = { "Content-Type": "application/json", "Referer": url || HS + "/" };
    if (token) headers["X-CSRF-TOKEN"] = token;
    return { url: HS + "/player/api", isEmbed: true, postBody: body, headers: headers };
}

// haho watch page -> the /embed?v=<vid> iframe hop.
function hahoEmbedHop(html) {
    var m = html.match(/<iframe[^>]+src="([^"]*\/embed\?v=[a-z0-9]+[^"]*)"/i) ||
        html.match(/(https:\/\/haho\.moe\/embed\?v=[a-z0-9]+)/i) ||
        html.match(/(\/embed\?v=[a-z0-9]+)/i);
    if (!m) return null;
    return { url: PluginUtils.absolutize(m[1], HAHO), isEmbed: true, headers: { "Referer": HAHO + "/" } };
}

// haho embed page -> the filegasm <source> ladder. Prefer the
// highest-labelled DIRECT token'd file; /watch/ host pages go back
// as embeds for the app's webview/sniffer path.
function hahoStreamFromEmbed(html, embedUrl) {
    var tags = html.match(/<source[^>]*>/gi) || [];
    var best = null, bestScore = -1, bestWatch = null, bestWatchScore = -1;
    for (var i = 0; i < tags.length; i++) {
        var tag = tags[i];
        var srcM = tag.match(/src="([^"]+)"/i);
        if (!srcM) continue;
        var src = PluginUtils.decodeEntities(srcM[1]);
        var labelM = tag.match(/title="(\d+)p?"/i);
        var score = labelM ? parseInt(labelM[1]) : 0;
        var isDirect = /filegasm\.com\/[a-z0-9]+\?download_token=/i.test(src) || /^https:\/\/s\d+\.filegasm\.com\//i.test(src);
        if (isDirect) {
            if (score > bestScore) { bestScore = score; best = src; }
        } else if (src.indexOf("filegasm.com/watch/") !== -1) {
            if (score > bestWatchScore) { bestWatchScore = score; bestWatch = src; }
        }
    }
    if (best) {
        return { url: best, isEmbed: false, headers: { "Referer": embedUrl || (HAHO + "/"), "User-Agent": DESKTOP_UA } };
    }
    if (bestWatch) {
        return { url: bestWatch, isEmbed: true, headers: { "Referer": embedUrl || (HAHO + "/") } };
    }
    return null;
}

// hh: watch page -> nhplayer embed; embed page -> player.php.
// This raw hop is now only the FALLBACK path: v1.0.1 resolves the
// direct MP4 via the in-plugin proof-of-work (hhResolveStep
// below); when any PoW step fails, or a resolve starts at a watch
// page (hop budget), the chain degrades to this hand-off and the
// app's sniffing WebView player runs the page's own challenge.
function hhEmbedHop(html, url) {
    var m = html.match(/(https:\/\/nhplayer\.com\/v\/[a-z0-9]+\/?)/i);
    if (m) return { url: m[1], isEmbed: true, headers: { "Referer": HH + "/" } };
    var p = html.match(/data-id="(\/player\.php\?[^"]+)"/i) || html.match(/(\/player\.php\?vid=[^"'\s]+)/i);
    if (p) return { url: "https://nhplayer.com" + PluginUtils.decodeEntities(p[1]), isEmbed: true, headers: { "Referer": url || "https://nhplayer.com/" } };
    if ((url || "").indexOf("nhplayer.com") !== -1) {
        // Embed page without a server entry: hand the page itself to
        // the webview player (self-embed in the resolver).
        return { url: url, isEmbed: true, headers: { "Referer": HH + "/" } };
    }
    return null;
}

// =============================================================================
// hh proof-of-work (v1.0.1) — resolve the direct MP4 in-plugin
// instead of handing player.php to the WebView (which serves a
// pre-roll ad). Measured live 2026-11-19; see the header note.
// Chain (resolve starting at the embed page):
//   embed page  -> data-id: player.php URL + base64 SRT (stashed)
//   player page -> _pV{vid,ct,pid,st} + five challenge parts
//                  (pid-anchored extraction below) + core URL
//   core script -> sc/rid tokens; PoW solved here; the
//                  /get-video-url-v2.php URL is the next hop
//   gv response -> {"url": signed MP4} => direct stream + SRT
// Any failure at any step falls back to the v1.0.0 hand-off.
// =============================================================================

function hhIframeUrl(html) {
    var m = html.match(/(https:\/\/nhplayer\.com\/v\/[a-z0-9]+\/?)/i);
    return m ? m[1] : "";
}

// Compact pure-JS base64 (JavaScriptCore has no atob/btoa).
var B64C = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
function b64Decode(s) {
    if (!s) return "";
    s = s.replace(/[^A-Za-z0-9+/=]/g, "");
    var out = "", i = 0;
    while (i < s.length) {
        var e1 = B64C.indexOf(s.charAt(i++));
        var e2 = B64C.indexOf(s.charAt(i++));
        var e3 = B64C.indexOf(s.charAt(i++));
        var e4 = B64C.indexOf(s.charAt(i++));
        if (e1 < 0 || e2 < 0) break;
        out += String.fromCharCode((e1 << 2) | (e2 >> 4));
        if (e3 >= 0 && s.charAt(i - 2) !== "=") out += String.fromCharCode(((e2 & 15) << 4) | (e3 >> 2));
        if (e4 >= 0 && s.charAt(i - 1) !== "=") out += String.fromCharCode(((e3 & 3) << 6) | e4);
    }
    return out;
}
function b64Encode(s) {
    var out = "", i = 0;
    while (i < s.length) {
        var c1 = s.charCodeAt(i++) & 0xff;
        var c2 = i < s.length ? s.charCodeAt(i++) & 0xff : -1;
        var c3 = i < s.length ? s.charCodeAt(i++) & 0xff : -1;
        out += B64C.charAt(c1 >> 2);
        out += B64C.charAt(((c1 & 3) << 4) | (c2 < 0 ? 0 : c2 >> 4));
        out += c2 < 0 ? "=" : B64C.charAt(((c2 & 15) << 2) | (c3 < 0 ? 0 : c3 >> 6));
        out += c3 < 0 ? "=" : B64C.charAt(c3 & 63);
    }
    return out;
}

// Compact standard SHA-256 over an ASCII string -> byte array.
// (Verified against Node's crypto on empty/short/multi-block
// inputs during the v1.0.1 work.)
function sha256Bytes(ascii) {
    function rr(v, a) { return (v >>> a) | (v << (32 - a)); }
    var K = [0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2];
    var H = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19];
    var bytes = [];
    for (var i = 0; i < ascii.length; i++) bytes.push(ascii.charCodeAt(i) & 0xff);
    var bitLen = bytes.length * 8;
    bytes.push(0x80);
    while (bytes.length % 64 !== 56) bytes.push(0);
    bytes.push(0, 0, 0, 0, (bitLen >>> 24) & 0xff, (bitLen >>> 16) & 0xff, (bitLen >>> 8) & 0xff, bitLen & 0xff);
    var w = new Array(64);
    for (var b = 0; b < bytes.length; b += 64) {
        for (var t = 0; t < 16; t++) w[t] = (bytes[b + t * 4] << 24) | (bytes[b + t * 4 + 1] << 16) | (bytes[b + t * 4 + 2] << 8) | bytes[b + t * 4 + 3];
        for (var t = 16; t < 64; t++) {
            var s0 = rr(w[t - 15], 7) ^ rr(w[t - 15], 18) ^ (w[t - 15] >>> 3);
            var s1 = rr(w[t - 2], 17) ^ rr(w[t - 2], 19) ^ (w[t - 2] >>> 10);
            w[t] = (w[t - 16] + s0 + w[t - 7] + s1) | 0;
        }
        var a = H[0], bb = H[1], c = H[2], d = H[3], e = H[4], f = H[5], g = H[6], h = H[7];
        for (var t = 0; t < 64; t++) {
            var S1 = rr(e, 6) ^ rr(e, 11) ^ rr(e, 25);
            var ch = (e & f) ^ (~e & g);
            var temp1 = (h + S1 + ch + K[t] + w[t]) | 0;
            var S0 = rr(a, 2) ^ rr(a, 13) ^ rr(a, 22);
            var maj = (a & bb) ^ (a & c) ^ (bb & c);
            var temp2 = (S0 + maj) | 0;
            h = g; g = f; f = e; e = (d + temp1) | 0; d = c; c = bb; bb = a; a = (temp1 + temp2) | 0;
        }
        H[0] = (H[0] + a) | 0; H[1] = (H[1] + bb) | 0; H[2] = (H[2] + c) | 0; H[3] = (H[3] + d) | 0;
        H[4] = (H[4] + e) | 0; H[5] = (H[5] + f) | 0; H[6] = (H[6] + g) | 0; H[7] = (H[7] + h) | 0;
    }
    var out = [];
    for (var j = 0; j < 8; j++) { out.push((H[j] >>> 24) & 0xff, (H[j] >>> 16) & 0xff, (H[j] >>> 8) & 0xff, H[j] & 0xff); }
    return out;
}

// The player's PoW: first nonce (hex counter from 0) whose
// SHA-256(challenge + nonce) starts with a zero byte. Expected
// ~256 tries (measured mean 217, worst 953 over 30 random
// challenges); the cap is a formality — P(exceeding it) ~ 0.
function hhSolvePow(challenge) {
    for (var n = 0; n < 300000; n++) {
        var nonce = n.toString(16);
        if (sha256Bytes(challenge + nonce)[0] === 0) return nonce;
    }
    return null;
}

// The five challenge parts sit in TWO hidden DOM blocks: a decoy
// (semantic ids) and the real one (randomized ids). The real
// block's ts element is the one whose data-* value equals the
// _pV pid prefix; the parts are the closest matching values
// before it in document order (span data-*, input value, div
// data-*, template <p>). Verified byte-exact against the core
// script's own selector map on two live page loads.
function hhExtractParts(html, ts) {
    var tsEsc = (ts || "").replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    var am = html.match(new RegExp("data-[a-z0-9]+=\"" + tsEsc + "\"", "i"));
    if (!am) return null;
    var win = html.slice(Math.max(0, am.index - 1200), am.index);
    function all(re) { var out = [], m; re.lastIndex = 0; while ((m = re.exec(win)) !== null) out.push(m[1]); return out; }
    var datas = all(/data-[a-z0-9]+="([0-9a-f]{8})"/gi);
    var inputs = all(/<input[^>]*?value="([0-9a-f]{8})"/gi);
    var tpls = all(/<template[^>]*>\s*<p>([0-9a-f]{8})<\/p>/gi);
    if (datas.length < 2 || inputs.length < 1 || tpls.length < 1) return null;
    return { p1: datas[datas.length - 2], p2: inputs[inputs.length - 1], p3: datas[datas.length - 1], p4: tpls[tpls.length - 1], ts: ts };
}

// Clean-browser fingerprint payload for /get-video-url-v2.php —
// the exact shape the real core script sends (empty behaviour
// arrays; the server requires the field and validates its
// structure — measured: omitted fp => 403 "Invalid fingerprint",
// this payload => 200).
var HH_FP_JSON = "{\"t\":1500,\"mm\":[],\"tm\":[],\"cl\":[],\"kp\":[],\"sc\":[],\"i\":0,\"mc\":0,\"tc\":0,\"cc\":0,\"kc\":0,\"b\":{\"sw\":1920,\"sh\":1080,\"aw\":1920,\"ah\":1040,\"cd\":24,\"pd\":24,\"tz\":300,\"hc\":8,\"dm\":8,\"pl\":\"Win32\",\"lang\":\"en-US\",\"langs\":\"en-US,en\",\"dpr\":1,\"ww\":1280,\"wh\":720,\"touch\":false,\"pdf\":true,\"fonts\":0}}";

// Per-resolve PoW chain state (the app keeps one JSContext per
// plugin; its calls are serialized, and every step below also
// re-validates the page it is parsing, so a stale stash can only
// ever cost the fallback, never a wrong stream).
var _hhPow = null;

function hhPlayerFallback() {
    return { url: _hhPow.playerUrl, isEmbed: true, headers: { "Referer": HH + "/" } };
}

// Empty-body twin of the core step's failure exits: when the
// core script fetch returns no body at all, the parse entry
// points' !html early return would break the chain and strand
// the resolver's last-resort WebView on the core script URL (a
// JavaScript file). Route it through the same marked fallback
// instead. The host/path test and the stash gates mirror the
// core step's exact-match checks, so only a core hop of the
// live resolve can take this detour.
function hhCoreEmptyStep(url) {
    var u = url || "";
    if (u.indexOf("nhplayer.com") === -1 || u.indexOf("player-core-v2.php") === -1) return null;
    if (!_hhPow || _hhPow.coreUrl !== u || !_hhPow.playerUrl) return null;
    _hhPow.failedFor = _hhPow.playerUrl;
    return hhPlayerFallback();
}

function hhGvUrl(sc, rid, nonce) {
    var p = _hhPow.parts;
    return "https://nhplayer.com/get-video-url-v2.php?" +
        "vid=" + encodeURIComponent(_hhPow.vid) +
        "&c=" + encodeURIComponent(_hhPow.ct) +
        "&p1=" + p.p1 + "&p2=" + p.p2 + "&p3=" + p.p3 + "&p4=" + p.p4 +
        "&t=" + p.ts +
        "&sc=" + sc + "&rid=" + rid +
        "&fp=" + encodeURIComponent(b64Encode(HH_FP_JSON)) +
        "&df=" + "&pow=" + nonce +
        "&pid=" + encodeURIComponent(_hhPow.pid) +
        "&st=" + encodeURIComponent(_hhPow.st);
}

// One PoW-chain step, or null when this page is not a PoW hop
// (the caller then falls through to the v1.0.0 hhEmbedHop path).
function hhResolveStep(html, url) {
    try {
        var u = url || "";
        // Authorization endpoint's answer: the direct stream.
        if (u.indexOf("get-video-url-v2.php") !== -1) {
            if (!_hhPow || _hhPow.gvUrl !== u) {
                if (_hhPow && _hhPow.playerUrl) return hhPlayerFallback();
                return null;
            }
            var gv = null;
            try { gv = JSON.parse(html); } catch (e) { gv = null; }
            if (!gv) {
                // The same WebView diversion (see the player
                // step) wraps a JSON body in a <pre> document
                // with its text entity-escaped; unwrap + decode
                // and retry so the serialized body parses like
                // the raw one. No-op on raw JSON (the first
                // parse above already succeeded).
                var preM = html.match(/<pre[^>]*>([\s\S]*?)<\/pre>/i);
                if (preM) {
                    try { gv = JSON.parse(PluginUtils.decodeEntities(preM[1]).trim()); } catch (e2) { gv = null; }
                }
            }
            if (gv && typeof gv.url === "string" && gv.url.indexOf("http") === 0) {
                var subs = [];
                if (_hhPow && _hhPow.srt) subs.push({ lang: "en", url: _hhPow.srt, label: "English" });
                return { url: gv.url, isEmbed: false, headers: { "Referer": "https://nhplayer.com/", "User-Agent": DESKTOP_UA }, subtitles: subs };
            }
            if (_hhPow && _hhPow.playerUrl) return hhPlayerFallback();
            return null;
        }
        // Core script: solve the PoW, name the authorization URL.
        // Every failure exit below marks the resolve failed
        // (_hhPow.failedFor = its player page) before taking the
        // fallback: if the resolver follows the fallback and
        // re-parses that player page, the player step self-embeds
        // it (see there) instead of issuing a fresh core hop the
        // parse budget cannot complete.
        if (u.indexOf("player-core-v2.php") !== -1) {
            if (!_hhPow || _hhPow.coreUrl !== u) {
                if (_hhPow && _hhPow.playerUrl) { _hhPow.failedFor = _hhPow.playerUrl; return hhPlayerFallback(); }
                return null;
            }
            if (_hhPow.parts && (_hhPow.stage === "core" || _hhPow.stage === "gv")) {
                if (_hhPow.sawWatch) { _hhPow.failedFor = _hhPow.playerUrl; return hhPlayerFallback(); }
                var scM = html.match(/[0-9a-f]{8}\.[0-9a-f]{16}/);
                var ridM = html.match(/id:'([0-9a-f]{16})'/);
                if (scM && ridM) {
                    var nonce = hhSolvePow(_hhPow.parts.p1 + _hhPow.parts.p2 + _hhPow.parts.p3 + _hhPow.parts.p4 + _hhPow.parts.ts);
                    if (nonce !== null) {
                        var gvUrl = hhGvUrl(scM[0], ridM[1], nonce);
                        _hhPow.gvUrl = gvUrl;
                        _hhPow.stage = "gv";
                        return { url: gvUrl, isEmbed: true, headers: { "Referer": _hhPow.playerUrl, "X-Requested-With": "XMLHttpRequest" } };
                    }
                }
            }
            if (_hhPow.playerUrl) { _hhPow.failedFor = _hhPow.playerUrl; return hhPlayerFallback(); }
            return null;
        }
        // Player page: harvest _pV + challenge parts, name the
        // core script as the next hop.
        if (html.indexOf("_pV={vid:") !== -1) {
            // This resolve's core step already failed once and
            // the chain followed the fallback back to this page:
            // hand the page itself to the WebView (self-embed)
            // rather than re-driving the PoW chain past the
            // parse budget. The marker is bound to this page's
            // URL and is cleared when a fresh resolve passes
            // the embed step, so it cannot poison a later one.
            if (_hhPow && _hhPow.failedFor && _hhPow.failedFor === u) {
                return { url: u, isEmbed: true, headers: { "Referer": HH + "/" } };
            }
            var pv = html.match(/_pV=\{vid:"([^"]+)",ct:"([^"]+)",pid:"([^"]+)",st:"([^"]+)"\}/);
            // The separator may arrive entity-escaped (&amp;)
            // when this hop was served through the app's WebView
            // fetcher (its Cloudflare detour returns DOM-
            // serialized HTML, where & in an attribute value is
            // written &amp;). Accept both forms and normalize
            // the extracted hop URL back to the raw one; on a
            // raw page the pattern matches exactly as before.
            var coreM = html.match(/(player-core-v2\.php\?t=[^"&]+&(?:amp;)?_=\d+)/);
            if (pv && coreM) {
                var parts = hhExtractParts(html, pv[3].split("_")[0]);
                if (parts) {
                    var coreUrl = "https://nhplayer.com/" + coreM[1].replace("&amp;", "&");
                    var saw = false, keepSrt = "", matchedEmbedUrl = "";
                    if (_hhPow) {
                        if (_hhPow.stage === "player" || _hhPow.playerUrl === u) saw = !!_hhPow.sawWatch;
                        if (_hhPow.embedUrl && _hhPow.playerUrl === u) {
                            keepSrt = _hhPow.srt || "";
                            matchedEmbedUrl = _hhPow.embedUrl;
                        }
                    }
                    _hhPow = { stage: "core", sawWatch: saw, embedUrl: matchedEmbedUrl, coreUrl: coreUrl, playerUrl: u, srt: keepSrt, vid: pv[1], ct: pv[2], pid: pv[3], st: pv[4], parts: parts };
                    return { url: coreUrl, isEmbed: true, headers: { "Referer": u } };
                }
            }
            return null;
        }
        // Embed page: stash the subtitle + chain state, then the
        // usual player.php hop (same output as hhEmbedHop).
        if (u.indexOf("nhplayer.com/v/") !== -1) {
            var dm = html.match(/data-id="(\/player\.php\?[^"]+)"/);
            if (dm) {
                var qs = PluginUtils.decodeEntities(dm[1]);
                var sm = qs.match(/[?&]s=([^&]+)/);
                var srt = "";
                if (sm) { var dec = b64Decode(sm[1]); if (dec && dec.indexOf("http") === 0) srt = dec; }
                var pUrl = "https://nhplayer.com" + qs;
                if (!(_hhPow && _hhPow.embedUrl === u && _hhPow.stage !== "embed")) {
                    if (_hhPow && _hhPow.stage === "embed" && _hhPow.embedUrl === u) { _hhPow.stage = "player"; }
                    else { _hhPow = { stage: "player", sawWatch: false }; }
                }
                _hhPow.embedUrl = u;
                _hhPow.playerUrl = pUrl;
                // A fresh chain attempt starts at this hop:
                // any failure marker a previous resolve left on
                // the kept stash is spent.
                _hhPow.failedFor = "";
                if (srt) _hhPow.srt = srt;
                return { url: pUrl, isEmbed: true, headers: { "Referer": u } };
            }
            return null;
        }
        return null;
    } catch (e) { return null; }
}

// hhEmbedHop plus the chain-state note for a resolve that starts
// at a watch page (one hop longer — its PoW chain cannot fit the
// resolver budget, so its core step will take the fallback).
function hhHopTracked(html, url) {
    var cfg = hhEmbedHop(html, url);
    if (cfg && cfg.url && cfg.url.indexOf("nhplayer.com/v/") !== -1 && (url || "").indexOf("nhplayer.com") === -1) {
        _hhPow = { stage: "embed", sawWatch: true, embedUrl: cfg.url, srt: "", playerUrl: "" };
    }
    return cfg;
}

function parseDetailResponse(html, url) {
    try {
        if (!html) {
            var hhEmptyD = hhCoreEmptyStep(url);
            if (hhEmptyD) return JSON.stringify(hhEmptyD);
            return JSON.stringify({ url: "", isEmbed: false, headers: {} });
        }
        var hhStepD = hhResolveStep(html, url);
        if (hhStepD) return JSON.stringify(hhStepD);
        if (html.indexOf('"stream_url"') !== -1) {
            var s = hsStreamFromApi(html);
            if (s) return JSON.stringify(s);
        }
        if (html.indexOf('id="e_id"') !== -1) {
            var cfg = hsPostConfig(html, url);
            if (cfg) return JSON.stringify(cfg);
        }
        var src = sniffSource(html);
        if (src === "haho" || (url || "").indexOf("haho.moe") !== -1) {
            var hop = hahoEmbedHop(html);
            if (hop) return JSON.stringify(hop);
            var st = hahoStreamFromEmbed(html, url);
            if (st) return JSON.stringify(st);
        }
        if (src === "hh" || (url || "").indexOf("hentaihaven") !== -1 || (url || "").indexOf("nhplayer") !== -1) {
            var hh = hhHopTracked(html, url);
            if (hh) return JSON.stringify(hh);
        }
        return JSON.stringify({ url: "", isEmbed: false, headers: {} });
    } catch (e) {
        return JSON.stringify({ url: "", isEmbed: false, headers: {} });
    }
}

function parseEmbedResponse(html, url) {
    try {
        if (!html) {
            var hhEmptyE = hhCoreEmptyStep(url);
            if (hhEmptyE) return JSON.stringify(hhEmptyE);
            return JSON.stringify({ url: "", isEmbed: false, headers: {} });
        }
        var hhStepE = hhResolveStep(html, url);
        if (hhStepE) return JSON.stringify(hhStepE);
        if (html.indexOf('"stream_url"') !== -1) {
            var s = hsStreamFromApi(html);
            if (s) return JSON.stringify(s);
        }
        if (html.indexOf("filegasm") !== -1) {
            var st = hahoStreamFromEmbed(html, url);
            if (st) return JSON.stringify(st);
        }
        if (html.indexOf("nhplayer.com") !== -1 || html.indexOf("player.php?vid=") !== -1 || (url || "").indexOf("nhplayer") !== -1) {
            var hh = hhHopTracked(html, url);
            if (hh) return JSON.stringify(hh);
        }
        if ((url || "").indexOf("haho.moe") !== -1 || html.indexOf("haho.moe") !== -1) {
            var hop = hahoEmbedHop(html);
            if (hop) return JSON.stringify(hop);
        }
        return JSON.stringify({ url: "", isEmbed: false, headers: {} });
    } catch (e) {
        return JSON.stringify({ url: "", isEmbed: false, headers: {} });
    }
}

function parseCategoriesResponse(html) {
    try {
        var cats = [];
        var seen = {};
        if (html.indexOf("haho.moe/genre/") !== -1) {
            var re = /href="https:\/\/haho\.moe\/genre\/([a-z0-9]+)"[^>]*title="([^"]+)"/gi, m;
            while ((m = re.exec(html)) !== null) {
                if (!seen[m[1]]) { seen[m[1]] = true; cats.push({ name: "HAHO · " + PluginUtils.decodeEntities(m[2]), slug: "haho:g:" + m[1] }); }
            }
        }
        return JSON.stringify(cats);
    } catch (e) { return "[]"; }
}

function parseCountriesResponse(html) { return "[]"; }
function parseYearsResponse(html) { return "[]"; }
