// =============================================================================
// JavGuru — plugin 1.0.0 (mod16)
// Source: https://jav.guru (WordPress SSR catalogue, exact-code search
// via /?s=<CODE>; detail /<id>/<slug>/; actress filmographies at
// /actress/<slug>/).
//
// Playback chain (measured live 2026-11-23, RESEARCH-SOURCES-ROUND2 §1
// + RESEARCH-REPLACEMENT-SOURCES-2 §1):
//   detail page carries base64 "iframe_url" gateway configs, one per
//   server family (gd / xd / ed / hd / od). Each decodes to a first-
//   party gateway URL (jav.guru/searcho/?<type>=<token>&bg=<poster>).
//   The gateway page is a static interstitial: window.cfg names a
//   base, an rtype letter and a list of data-* attribute keys; the
//   real embed URL is base + "?" + rtype + "r=" + REVERSE(concat of
//   the attribute values in cfg key order), and that URL 302-redirects
//   to the family's embed host. xd lands on javclan.com (StreamHG):
//   its page is Dean-Edwards-packed JS whose unpacked payload holds
//   var links = {hls2, hls4, hls3}. The payload's own source order is
//   hls4 || hls3 || hls2, but MEASURED reality is the reverse
//   preference: hls3 served master -> variant -> real TS segments
//   from a residential egress, hls4's variant head carries TikTok-CDN
//   ad segments, and hls2's host did not answer residentially. This
//   plugin therefore prefers hls3, then hls4, then hls2, and hands
//   the unused lines to the app as alternateURLs (SPEC-136 §3.2
//   pre-flight, the missav 1.1.6 convention).
//   StreamHG tokens are bound to the egress that minted them (the
//   embed page fetch), so the whole chain must run in the one client
//   session — which is exactly how the app resolves.
//
// Failure contract (shared across the plugin set): an unresolvable
// page yields url === "" — never a silent partial result.
// =============================================================================

// =============================================================================
// CONFIGURATION & METADATA
// =============================================================================

function getManifest() {
    return JSON.stringify({
        "id": "javguru",
        "name": "JavGuru",
        "version": "1.0.0",
        "baseUrl": "https://jav.guru",
        "referrer": "https://jav.guru/",
        "iconUrl": "https://jav.guru/favicon.ico",
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
        { slug: 'category/jav', title: 'JAV', type: 'Horizontal', path: '' },
        { slug: 'category/4k', title: '4K', type: 'Horizontal', path: '' },
        { slug: 'category/hd', title: 'HD', type: 'Horizontal', path: '' }
    ]);
}

function getPrimaryCategories() {
    return JSON.stringify([
        { name: 'Mới nhất', slug: '' },
        { name: 'JAV', slug: 'category/jav' },
        { name: '4K', slug: 'category/4k' },
        { name: 'HD', slug: 'category/hd' },
        { name: '1080p', slug: 'category/1080p' }
    ]);
}

function getFilterConfig() {
    return JSON.stringify({
        sort: [
            { name: 'Mới nhất', value: 'new' },
            { name: 'Lượt xem', value: 'views' },
            { name: 'Yêu thích', value: 'likes' },
            { name: 'Ngày phát hành', value: 'release' }
        ]
    });
}

// =============================================================================
// URL GENERATION
// =============================================================================

var JAVGURU_BASE = "https://jav.guru";

// WordPress pagination lives in the path (/page/<n>/), sorting in the
// query (?orderby=...&order=DESC — the values the site's own sort
// dropdown posts). Build the final URL for a listing base path.
function javguruListUrl(basePath, page, filters) {
    var url = JAVGURU_BASE + basePath;
    if (page && page > 1) {
        url += "page/" + page + "/";
    }
    var query = [];
    if (filters && filters.sort && filters.sort !== 'new') {
        if (filters.sort === 'views') query.push("orderby=views&order=DESC");
        else if (filters.sort === 'likes') query.push("orderby=likes&order=DESC");
        else if (filters.sort === 'release') query.push("orderby=rdate&order=DESC");
    }
    if (query.length) url += "?" + query.join("&");
    return url;
}

function getUrlList(slug, filtersJson) {
    var filters = JSON.parse(filtersJson || "{}");
    var page = filters.page || 1;
    var path = slug || "";

    // Cast-route slugs arrive as the site path the detail parser
    // emitted ("/actress/<slug>/") or the bare "actress/<slug>".
    if (path.indexOf("/") === 0) path = path.substring(1);
    if (path && path.charAt(path.length - 1) !== "/") path += "/";

    return javguruListUrl("/" + path, page, filters);
}

function getUrlSearch(keyword, filtersJson) {
    var filters = JSON.parse(filtersJson || "{}");
    var page = filters.page || 1;
    var base = JAVGURU_BASE + "/";
    if (page && page > 1) base += "page/" + page + "/";
    var url = base + "?s=" + encodeURIComponent(keyword);
    if (filters.sort && filters.sort !== 'new') {
        if (filters.sort === 'views') url += "&orderby=views&order=DESC";
        else if (filters.sort === 'likes') url += "&orderby=likes&order=DESC";
        else if (filters.sort === 'release') url += "&orderby=rdate&order=DESC";
    }
    return url;
}

function getUrlDetail(slug) {
    if (!slug) return JAVGURU_BASE + "/";
    if (slug.indexOf("http") === 0) return slug;
    if (slug.indexOf("/") === 0) return JAVGURU_BASE + slug;
    return JAVGURU_BASE + "/" + slug;
}

function getUrlCategories() { return JAVGURU_BASE + "/"; }
function getUrlCountries() { return ""; }
function getUrlYears() { return ""; }

// =============================================================================
// HELPERS
// =============================================================================

var DESKTOP_UA_JAVGURU = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

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

// Base64 decode with the javhd fallback discipline: atob when the
// engine provides it, a manual decoder otherwise (the JSC surface
// the app exposes may not provide atob).
function javguruB64Decode(input) {
    var clean = String(input || "").replace(/[^A-Za-z0-9+/=]/g, "");
    if (typeof atob === "function") {
        try {
            var bin = atob(clean);
            var out = "";
            for (var i = 0; i < bin.length; i++) {
                var ch = bin.charCodeAt(i);
                if (ch < 0x80) { out += bin.charAt(i); continue; }
                // Gateway URLs are plain ASCII; anything beyond is
                // not ours — keep the byte as-is rather than guessing
                // a UTF-8 reconstruction.
                out += bin.charAt(i);
            }
            return out;
        } catch (e) { /* fall through to the manual decoder */ }
    }
    var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    var result = "";
    var buffer = 0, bits = 0;
    for (var j = 0; j < clean.length; j++) {
        var c = clean.charAt(j);
        if (c === "=") break;
        var v = chars.indexOf(c);
        if (v < 0) continue;
        buffer = (buffer << 6) | v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            result += String.fromCharCode((buffer >> bits) & 0xff);
        }
    }
    return result;
}

// Dean Edwards packer unpacker (the javclan/StreamHG embed pages).
// Finds every eval(function(p,a,c,k,e,d){...}('payload',radix,count,
// 'kw|kw'.split('|'),0,{})) block, substitutes tokens from the top
// index down (the packer's own order) and returns the concatenated
// unpacked text. Returns "" when no packed block exists.
function javguruUnpack(html) {
    var out = [];
    var re = /eval\(function\(p,a,c,k,e,d\)\{[\s\S]*?\}\('((?:[^'\\]|\\.)*)',(\d+),(\d+),'((?:[^'\\]|\\.)*)'\.split\('\|'\)/g;
    var m;
    while ((m = re.exec(html)) !== null) {
        var payload = m[1].replace(/\\'/g, "'").replace(/\\\\/g, "\\");
        var radix = parseInt(m[2], 10);
        var count = parseInt(m[3], 10);
        var keywords = m[4].split("|");
        var p = payload;
        for (var c = count - 1; c >= 0; c--) {
            var kw = (c < keywords.length) ? keywords[c] : "";
            if (!kw) continue;
            var token = c.toString(radix);
            var tokenRe = new RegExp("\\b" + token + "\\b", "g");
            (function (replacement) {
                p = p.replace(tokenRe, function () { return replacement; });
            })(kw);
        }
        out.push(p);
    }
    return out.join("\n");
}

function javguruOrigin(url) {
    var m = String(url || "").match(/^(https?:\/\/[^\/]+)/i);
    return m ? m[1] : "";
}

// =============================================================================
// LIST PARSERS
// =============================================================================

function parseListResponse(html) {
    var movies = [];
    var seen = {};

    // Cards are <div class="imgg"> blocks: detail link + thumbnail,
    // followed by the title heading and tag row for the same item.
    var parts = html.split('<div class="imgg">');
    for (var i = 1; i < parts.length; i++) {
        var chunk = parts[i];
        var linkMatch = chunk.match(/href="(https:\/\/jav\.guru\/(\d+)\/([^"\/]+)\/)"/i);
        if (!linkMatch) continue;
        var detailUrl = linkMatch[1];
        if (seen[detailUrl]) continue;
        seen[detailUrl] = true;
        var slug = linkMatch[2] + "/" + linkMatch[3];

        var imgMatch = chunk.match(/<img[^>]+src="([^"]+)"/i);
        var poster = imgMatch ? imgMatch[1] : "";
        // Card thumbnails are the -550x374 derivative; the full
        // poster is the same path without the size suffix.
        var fullPoster = poster.replace(/-\d+x\d+(\.[a-zA-Z0-9]+)$/, "$1");

        var badgeMatch = chunk.match(/thumb-badge[^>]*>([^<]+)</i);
        var quality = badgeMatch ? PluginUtils.cleanText(badgeMatch[1]) : "HD";

        var title = "";
        var titleMatch = chunk.match(/<h2>\s*<a[^>]*>([\s\S]*?)<\/a>/i);
        if (titleMatch) title = PluginUtils.cleanText(titleMatch[1]);
        if (!title && imgMatch) {
            var altMatch = chunk.match(/<img[^>]+alt="([^"]+)"/i);
            if (altMatch) title = PluginUtils.cleanText(altMatch[1]);
        }
        if (!title) title = linkMatch[3];

        movies.push({
            id: slug,
            title: title,
            posterUrl: fullPoster,
            backdropUrl: fullPoster,
            description: "",
            year: 0,
            quality: quality || "HD",
            episode_current: "",
            lang: "Censored"
        });
    }

    // Pagination (WordPress /page/<n>/ links).
    var currentPage = 1;
    var totalPages = 1;
    var pageNums = html.match(/\/page\/(\d+)\//g);
    if (pageNums) {
        for (var p = 0; p < pageNums.length; p++) {
            var num = parseInt(pageNums[p].match(/\d+/)[0], 10);
            if (num > totalPages) totalPages = num;
        }
    }
    var activeMatch = html.match(/page-numbers[^>]*current[^>]*>(\d+)</i);
    if (activeMatch) currentPage = parseInt(activeMatch[1], 10);

    return JSON.stringify({
        items: movies,
        pagination: {
            currentPage: currentPage,
            totalPages: Math.max(totalPages, currentPage),
            totalItems: movies.length,
            itemsPerPage: 24
        }
    });
}

function parseSearchResponse(html) {
    return parseListResponse(html);
}

// =============================================================================
// DETAIL PARSER
// =============================================================================

// Gateway families in MEASURED preference order: xd (StreamHG) is
// the proven terminal chain; ed (StreamHihi) is its sister front;
// gd (OppaiNet), hd (Vide0) and od (MaxStream) follow as switchable
// fallback servers. Display names are the measured 302 landings.
var JAVGURU_GATEWAYS = [
    { type: "xd", name: "StreamHG" },
    { type: "ed", name: "StreamHihi" },
    { type: "gd", name: "OppaiNet" },
    { type: "hd", name: "Vide0" },
    { type: "od", name: "MaxStream" }
];

function parseMovieDetail(html, pageUrl) {
    try {
        // ---- Title / code -------------------------------------------------
        var rawTitle = PluginUtils.getMeta(html, "og:title");
        if (!rawTitle) {
            var titleTag = html.match(/<title>([\s\S]*?)<\/title>/i);
            if (titleTag) rawTitle = titleTag[1];
        }
        var title = PluginUtils.cleanText(rawTitle)
            .replace(/\s*⋆\s*Jav Guru[\s\S]*$/i, "")
            .trim();

        // The infometa block carries the structured fields; scope all
        // field reads to it so the popular-posts rail (which links
        // other actresses/makers) cannot leak into this title's data.
        var info = "";
        var infoMatch = html.match(/<div class="infometa">([\s\S]*?)<\/ul>/i);
        if (infoMatch) info = infoMatch[1];

        var code = "";
        var codeMatch = info.match(/Code:\s*<\/span><\/strong>\s*([A-Za-z0-9-]+)/i) ||
            html.match(/\[([A-Za-z]{2,6}-\d{2,6})\]/);
        if (codeMatch) code = codeMatch[1].toUpperCase();
        if (!code) {
            var slugCode = String(pageUrl || "").match(/\/([a-z]{2,6}-\d{2,6})[-\/]/i);
            if (slugCode) code = slugCode[1].toUpperCase();
        }

        var year = 0;
        var relMatch = info.match(/Release Date:\s*<\/span><\/strong>\s*(\d{4})-\d{2}-\d{2}/i);
        if (relMatch) year = parseInt(relMatch[1], 10);
        if (!year) {
            var pubMatch = html.match(/"datePublished":"(\d{4})-/);
            if (pubMatch) year = parseInt(pubMatch[1], 10);
        }

        // ---- Plain fields (director / studio) -----------------------------
        var director = "";
        var dirMatch = info.match(/Director:<\/strong>\s*<a[^>]*>([^<]+)<\/a>/i);
        if (dirMatch) director = PluginUtils.cleanText(dirMatch[1]);

        var studio = "";
        var studioMatch = info.match(/Studio:<\/strong>\s*<a[^>]*>([^<]+)<\/a>/i);
        if (studioMatch) studio = PluginUtils.cleanText(studioMatch[1]);
        var label = "";
        var labelMatch = info.match(/Label:<\/strong>\s*<a[^>]*>([^<]+)<\/a>/i);
        if (labelMatch) label = PluginUtils.cleanText(labelMatch[1]);

        // ---- Genres = the Tags row (plain text, the L-20 convention) ------
        var genres = [];
        var tagsMatch = info.match(/Tags:\s*<\/strong>([\s\S]*?)<\/li>/i);
        if (tagsMatch) {
            var tagRe = /<a[^>]*>([^<]+)<\/a>/gi;
            var tm;
            while ((tm = tagRe.exec(tagsMatch[1])) !== null) {
                var g = PluginUtils.cleanText(tm[1]);
                if (g && genres.indexOf(g) === -1) genres.push(g);
            }
        }

        // ---- Quality / lang from the Category row --------------------------
        var quality = "HD";
        var lang = "Censored";
        var catMatch = info.match(/Category:<\/strong>([\s\S]*?)<\/li>/i);
        if (catMatch) {
            if (/\/category\/4k\//i.test(catMatch[1])) quality = "4K";
            if (/\/category\/uncensored\//i.test(catMatch[1])) lang = "Uncensored";
        }

        // ---- Casts: the Actress row only, shared markdown convention -------
        var actors = [];
        var seenActors = {};
        var actressMatch = info.match(/Actress:<\/strong>([\s\S]*?)<\/li>/i);
        if (actressMatch) {
            var actRe = /<a[^>]+href="https?:\/\/jav\.guru(\/actress\/([^"\/]+)\/)"[^>]*>([^<]+)<\/a>/gi;
            var am;
            while ((am = actRe.exec(actressMatch[1])) !== null) {
                var aName = PluginUtils.cleanText(am[3]);
                if (aName && !seenActors[am[2]]) {
                    seenActors[am[2]] = true;
                    actors.push("[" + aName + "](" + am[1] + ")");
                }
            }
        }

        // ---- Gateway configs -> servers ------------------------------------
        // "iframe_url":"<base64>" values decode to
        // https://jav.guru/searcho/?<type>=<token>&bg=<poster URL>.
        var gateways = {};
        var poster = "";
        var cfgRe = /"iframe_url":"([A-Za-z0-9+/=]+)"/g;
        var cm;
        while ((cm = cfgRe.exec(html)) !== null) {
            var decoded = javguruB64Decode(cm[1]);
            var typeMatch = decoded.match(/searcho\/\?([a-z]{2})=/i);
            if (!typeMatch) continue;
            var type = typeMatch[1].toLowerCase();
            if (!gateways[type]) gateways[type] = decoded;
            if (!poster) {
                var bgMatch = decoded.match(/[?&]bg=([^&]+)/);
                if (bgMatch) {
                    try { poster = decodeURIComponent(bgMatch[1]); } catch (e) { poster = bgMatch[1]; }
                }
            }
        }
        if (!poster) {
            poster = PluginUtils.getMeta(html, "og:image");
        }

        var servers = [];
        for (var s = 0; s < JAVGURU_GATEWAYS.length; s++) {
            var gw = JAVGURU_GATEWAYS[s];
            if (!gateways[gw.type]) continue;
            servers.push({
                name: gw.name,
                episodes: [{
                    id: gateways[gw.type],
                    name: "Full",
                    slug: gw.type
                }]
            });
        }

        var statusLine = "";
        if (studio) statusLine += "Studio: " + studio;
        if (label) statusLine += (statusLine ? " | " : "") + "Label: " + label;

        var slugId = "";
        var canonMatch = html.match(/<link\s+rel="canonical"\s+href="https:\/\/jav\.guru\/([^"]+)"/i);
        if (canonMatch) slugId = canonMatch[1].replace(/\/$/, "");

        return JSON.stringify({
            id: code || slugId,
            title: title,
            posterUrl: poster,
            backdropUrl: poster,
            description: "",
            year: year,
            rating: 0,
            quality: quality,
            servers: servers,
            episode_current: servers.length > 0 ? "Full" : "No Source",
            lang: lang,
            category: genres.join(", "),
            country: "Japan",
            director: director,
            casts: actors.join(", "),
            status: statusLine,
            duration: "",
            previewUrl: ""
        });
    } catch (e) {
        return "null";
    }
}

// =============================================================================
// RESOLVE — gateway interstitial -> embed host -> StreamHG line pick
// =============================================================================

function javguruFailure() {
    return JSON.stringify({
        url: "",
        isEmbed: false,
        headers: {
            "User-Agent": DESKTOP_UA_JAVGURU,
            "Referer": "https://jav.guru/"
        },
        subtitles: [],
        alternateURLs: []
    });
}

function parseJavGuruResolve(htmlContent, pageUrl) {
    var html = htmlContent || "";
    var url = pageUrl || "";

    // Hop 1 — the first-party gateway interstitial: window.cfg names
    // the token fragments; the real embed URL is the reversed join.
    if (/window\.cfg\s*=\s*\{/.test(html)) {
        var cfgMatch = html.match(/window\.cfg\s*=\s*\{([\s\S]*?)\};/);
        if (cfgMatch) {
            var cfg = cfgMatch[1];
            var baseMatch = cfg.match(/base:\s*'([^']+)'/);
            var rtypeMatch = cfg.match(/rtype:\s*'([^']+)'/);
            var keys = [];
            var keyRe = /'(data-[a-z0-9-]+)'/gi;
            var km;
            while ((km = keyRe.exec(cfg)) !== null) keys.push(km[1]);
            if (baseMatch && rtypeMatch && keys.length) {
                var token = "";
                for (var k = 0; k < keys.length; k++) {
                    var attrMatch = html.match(new RegExp(keys[k] + '="([^"]+)"'));
                    if (!attrMatch) { token = ""; break; }
                    token += attrMatch[1];
                }
                if (token) {
                    var reversed = token.split("").reverse().join("");
                    return JSON.stringify({
                        url: baseMatch[1] + "?" + rtypeMatch[1] + "r=" + reversed,
                        isEmbed: true,
                        headers: {
                            "User-Agent": DESKTOP_UA_JAVGURU,
                            "Referer": "https://jav.guru/"
                        },
                        subtitles: []
                    });
                }
            }
        }
        return javguruFailure();
    }

    // Hop 2 — StreamHG embed page: unpack the packed payload and
    // read var links. Preference is MEASURED: hls3 first (clean
    // residential path), then hls4 (ad-injected head), then hls2
    // (host unreliable) — the reverse of the payload's own order.
    var searchText = html;
    var unpacked = javguruUnpack(html);
    if (unpacked) searchText = html + "\n" + unpacked;

    var lines = {};
    var lineNames = ["hls3", "hls4", "hls2"];
    for (var li = 0; li < lineNames.length; li++) {
        var lm = searchText.match(new RegExp('"' + lineNames[li] + '":"([^"]+)"'));
        if (lm) lines[lineNames[li]] = lm[1];
    }
    var ordered = [];
    for (var oi = 0; oi < lineNames.length; oi++) {
        if (!lines[lineNames[oi]]) continue;
        var u = lines[lineNames[oi]];
        if (u.indexOf("/") === 0) u = javguruOrigin(url) + u;
        if (u.indexOf("http") === 0 && ordered.indexOf(u) === -1) ordered.push(u);
    }
    if (ordered.length) {
        return JSON.stringify({
            url: ordered[0],
            isEmbed: false,
            headers: {
                "User-Agent": DESKTOP_UA_JAVGURU,
                "Referer": url
            },
            subtitles: [],
            alternateURLs: ordered.slice(1)
        });
    }

    // Generic drift fallback (other embed families): a quoted .m3u8
    // anywhere in the page is a terminal candidate.
    var m3 = searchText.match(/["'](https?:\/\/[^"']+\.m3u8[^"']*)["']/i);
    if (m3) {
        return JSON.stringify({
            url: m3[1],
            isEmbed: false,
            headers: {
                "User-Agent": DESKTOP_UA_JAVGURU,
                "Referer": url
            },
            subtitles: [],
            alternateURLs: []
        });
    }

    // Unrecognised embed page: hand the page itself back as an embed
    // (the 123av A5 precedent) so the app's EmbedSniffer can load it
    // and intercept the stream. Gateway/jav.guru pages never land
    // here — they are hop 1 or a failure above.
    if (url && url.indexOf("jav.guru") === -1) {
        return JSON.stringify({
            url: url,
            isEmbed: true,
            headers: {
                "User-Agent": DESKTOP_UA_JAVGURU,
                "Referer": "https://jav.guru/"
            },
            subtitles: []
        });
    }

    return javguruFailure();
}

function parseEmbedResponse(htmlContent, pageUrl) {
    var resolved = parseJavGuruResolve(htmlContent, pageUrl);
    if (resolved) return resolved;
    return javguruFailure();
}

function parseDetailResponse(htmlContent, pageUrl) {
    // In the resolver chain this parser runs on the same payloads as
    // parseEmbedResponse (gateway page, then embed page), so it
    // shares the resolve logic above (the 123av convention).
    return parseEmbedResponse(htmlContent, pageUrl);
}

function parseCategoriesResponse(html) {
    var categories = [];
    var found = {};
    var genreRegex = /<a[^>]+href="https?:\/\/jav\.guru\/category\/([^"\/]+)\/"[^>]*>([\s\S]*?)<\/a>/gi;
    var match;
    while ((match = genreRegex.exec(html)) !== null) {
        var slug = "category/" + match[1];
        var name = PluginUtils.cleanText(match[2]);
        if (!name || name.length < 2) continue;
        if (!found[slug]) {
            found[slug] = true;
            categories.push({ name: name, slug: slug });
        }
    }
    return JSON.stringify(categories);
}

function parseCountriesResponse(html) { return "[]"; }
function parseYearsResponse(html) { return "[]"; }
